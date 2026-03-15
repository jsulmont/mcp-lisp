;;;; src/transport/mcp-sse.lisp
;;;;
;;;; MCP Streamable HTTP transport (replaces old SSE transport).
;;;; Per MCP 2025-03-26+: single endpoint, POST for messages, optional SSE streaming.
;;;; Supports mid-execution notifications and server→client requests via SSE.

(defpackage #:mcp-lisp/src/transport/mcp-sse
  (:use #:cl #:log4cl)
  (:import-from #:hunchentoot)
  (:import-from #:flexi-streams)
  (:import-from #:mcp-lisp/src/json
                #:encode-json
                #:decode-json
                #:make-ht)
  (:import-from #:mcp-lisp/src/conditions
                #:protocol-error
                #:protocol-error-code
                #:protocol-error-data
                #:mcp-error-message)
  (:export #:start-sse-server
           #:stop-sse-server
           #:*sse-server*
           ;; Mid-execution messaging for tool handlers
           #:*stream-notify-fn*
           #:*stream-call-fn*
           ;; Structured access log
           #:*access-log-stream*
           ;; For testing
           #:generate-session-id
           #:send-to-session
           #:*sse-clients*
           #:*sse-clients-lock*))

(in-package #:mcp-lisp/src/transport/mcp-sse)

(defvar *sse-server* nil "Current Hunchentoot acceptor.")
(defvar *handlers* nil "Hash-table of method handlers.")
(defvar *mcp-session-id* nil "Active session ID for Streamable HTTP.")
(defvar *sse-clients* nil "Hash-table of session-id -> SSE client stream (for GET listeners).")
(defvar *sse-clients-lock* (bt:make-lock "sse-clients"))
(defvar *session-id-lock* (bt:make-lock "session-id"))
(defvar *next-session-id* 0)
(defvar *mcp-path* "/mcp" "MCP endpoint path.")

;;; Mid-execution messaging: bound during SSE-streamed tool execution.
;;; Tool handlers can use these to send notifications or make requests to the client.
(defvar *stream-notify-fn* nil
  "When bound, a function (method params) that sends a JSON-RPC notification to the client
via the active SSE stream. Available during tool execution in SSE mode.")

(defvar *stream-call-fn* nil
  "When bound, a function (method params &key timeout) → result that sends a JSON-RPC
request to the client via SSE and waits for the response. Available during tool execution.")

;;; Pending responses: for server→client requests that need responses.
;;; Key: request-id, Value: (lock . (condition-var . result-cell))
(defvar *pending-responses* (make-hash-table :test #'equal)
  "Table of pending server→client request IDs awaiting responses.")
(defvar *pending-responses-lock* (bt:make-lock "pending-responses"))
(defvar *next-request-id* 0)
(defvar *request-id-lock* (bt:make-lock "request-id"))

;;; Structured access logging.
;;; When *access-log-stream* is set, every JSON-RPC request/notification gets a
;;; JSON-lines entry with session, method, duration, and outcome.
(defvar *access-log-stream* nil
  "Stream for structured JSON-lines access logging. Set to a file stream or
*error-output* to enable. nil disables access logging.")

(defun extract-target (method params)
  "Extract the target name from params based on method.
For tools/call -> tool name, prompts/get -> prompt name, resources/read -> URI."
  (when (hash-table-p params)
    (cond
      ((or (equal method "tools/call")
           (equal method "prompts/get"))
       (gethash "name" params))
      ((or (equal method "resources/read")
           (equal method "resources/subscribe")
           (equal method "resources/unsubscribe"))
       (gethash "uri" params))
      ((equal method "logging/setLevel")
       (gethash "level" params)))))

(defun emit-access-log (method id session-id duration-ms status &key error-msg target)
  "Write a structured log entry to *access-log-stream*."
  (when *access-log-stream*
    (let ((entry (make-ht "ts" (format-iso8601)
                          "session" (or session-id "-")
                          "method" (or method "-")
                          "id" id
                          "duration_us" duration-ms
                          "status" status)))
      (when target
        (setf (gethash "target" entry) target))
      (when error-msg
        (setf (gethash "error" entry) error-msg))
      (handler-case
          (progn
            (write-string (encode-json entry) *access-log-stream*)
            (terpri *access-log-stream*)
            (force-output *access-log-stream*))
        (error () nil)))))

(defun format-iso8601 ()
  "Return current time as ISO 8601 string."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            year month day hour min sec)))

(defun call-with-access-log (method id params thunk)
  "Call THUNK, logging the call with timing to the access log.
PARAMS is the JSON-RPC params for target extraction.
Returns whatever THUNK returns."
  (if (null *access-log-stream*)
      (funcall thunk)
      (let ((start (get-internal-real-time))
            (target (extract-target method params)))
        (multiple-value-bind (result condition)
            (block done
              (handler-bind
                  ((error (lambda (e)
                            (let ((us (round (* 1000000 (/ (- (get-internal-real-time) start)
                                                          internal-time-units-per-second)))))
                              (emit-access-log method id *mcp-session-id* us "error"
                                              :error-msg (princ-to-string e) :target target))
                            (return-from done (values nil e)))))
                (values (funcall thunk) nil)))
          (if condition
              (error condition)
              (let ((us (round (* 1000000 (/ (- (get-internal-real-time) start)
                                             internal-time-units-per-second)))))
                (emit-access-log method id *mcp-session-id* us "ok" :target target)
                result))))))

(defun next-request-id ()
  (bt:with-lock-held (*request-id-lock*)
    (format nil "srv-~a" (incf *next-request-id*))))

;;; --- JSON-RPC helpers ---

(defun make-json-rpc-response (id result)
  (make-ht "jsonrpc" "2.0" "id" id "result" result))

(defun make-json-rpc-error (id code message &optional data)
  (let ((err (make-ht "code" code "message" message)))
    (when data
      (setf (gethash "data" err) data))
    (make-ht "jsonrpc" "2.0" "id" id "error" err)))

(defun make-json-rpc-request (id method params)
  (let ((req (make-ht "jsonrpc" "2.0" "id" id "method" method)))
    (when params
      (setf (gethash "params" req) params))
    req))

(defun make-json-rpc-notification (method params)
  (let ((n (make-ht "jsonrpc" "2.0" "method" method)))
    (when params
      (setf (gethash "params" n) params))
    n))

;;; --- SSE helpers ---

(defun write-utf8 (string stream)
  (write-sequence (flexi-streams:string-to-octets string :external-format :utf-8) stream))

(defun generate-session-id ()
  (bt:with-lock-held (*session-id-lock*)
    (format nil "~a-~a" (get-universal-time) (incf *next-session-id*))))

(defun send-sse-event (stream data &optional event-type)
  (when event-type
    (write-utf8 (format nil "event: ~a~%" event-type) stream))
  (write-utf8 (format nil "data: ~a~%~%" data) stream)
  (force-output stream))

(defun send-to-session (session-id data &optional event-type)
  "Send SSE event to a specific session's GET stream."
  (bt:with-lock-held (*sse-clients-lock*)
    (let ((stream (gethash session-id *sse-clients*)))
      (when (and stream (open-stream-p stream))
        (handler-case
            (progn (send-sse-event stream data event-type) t)
          (error (e)
            (log:warn "SSE send error for session ~a: ~a" session-id e)
            (remhash session-id *sse-clients*)
            nil))))))

;;; --- Response routing for server→client requests ---

(defun is-json-rpc-response-p (parsed)
  "Return T if PARSED is a JSON-RPC response (has id + result/error, no method)."
  (and (hash-table-p parsed)
       (gethash "id" parsed)
       (null (gethash "method" parsed))
       (or (nth-value 1 (gethash "result" parsed))
           (nth-value 1 (gethash "error" parsed)))))

(defun deliver-pending-response (parsed)
  "Deliver a JSON-RPC response to a waiting server→client request. Returns T if delivered."
  (let* ((id (gethash "id" parsed))
         (entry nil))
    (bt:with-lock-held (*pending-responses-lock*)
      (setf entry (gethash id *pending-responses*)))
    (when entry
      (destructuring-bind (lock cv . result-cell) entry
        (bt:with-lock-held (lock)
          (setf (car result-cell) parsed)
          (bt:condition-notify cv)))
      t)))

;;; --- Core request handler (sync path, used for non-streaming responses) ---

(defun dispatch-request (request-json)
  "Process a JSON-RPC request synchronously.
Returns (values response-json is-notification-p is-response-p)."
  (handler-case
      (let ((parsed (decode-json request-json)))
        ;; Check if this is a response to a pending server→client request
        (when (is-json-rpc-response-p parsed)
          (deliver-pending-response parsed)
          (return-from dispatch-request (values nil nil t)))
        (let* ((id (gethash "id" parsed))
               (method (gethash "method" parsed))
               (params (gethash "params" parsed))
               (handler (gethash method *handlers*)))
          (cond
            ((null id)
             (when handler
               (handler-case
                   (call-with-access-log method nil params (lambda () (funcall handler params)))
                 (error (e) (log:error "Notification handler error (~a): ~a" method e))))
             (values nil t nil))
            (handler
             (handler-case
                 (let ((result (call-with-access-log method id params (lambda () (funcall handler params)))))
                   (values (encode-json (make-json-rpc-response id result)) nil nil))
               (protocol-error (e)
                 (values (encode-json (make-json-rpc-error
                                       id (protocol-error-code e)
                                       (mcp-error-message e) (protocol-error-data e)))
                         nil nil))
               (error (e)
                 (values (encode-json (make-json-rpc-error id -32603 (princ-to-string e)))
                         nil nil))))
            (t
             (emit-access-log method id *mcp-session-id* 0 "not_found"
                             :target (extract-target method params))
             (values (encode-json (make-json-rpc-error
                                    id -32601 (format nil "Method not found: ~a" method)))
                     nil nil)))))
    (error (e)
      (log:error "Parse error: ~a" e)
      (values (encode-json (make-json-rpc-error nil -32700 "Parse error")) nil nil))))

;;; --- SSE streaming request handler ---

(defun handle-request-streaming (request-json sse-stream)
  "Process a JSON-RPC request with SSE streaming.
Sends the response (and any mid-execution notifications/requests) as SSE events."
  (handler-case
      (let ((parsed (decode-json request-json)))
        ;; Response to pending request — deliver and return 202
        (when (is-json-rpc-response-p parsed)
          (deliver-pending-response parsed)
          (return-from handle-request-streaming :accepted))
        (let* ((id (gethash "id" parsed))
               (method (gethash "method" parsed))
               (params (gethash "params" parsed))
               (handler (gethash method *handlers*)))
          (cond
            ;; Notification
            ((null id)
             (when handler
               (handler-case
                   (call-with-access-log method nil params (lambda () (funcall handler params)))
                 (error (e) (log:error "Notification handler error (~a): ~a" method e))))
             :accepted)
            ;; Request with handler — execute with streaming context
            (handler
             (let ((response-json
                     (handler-case
                         (let* ((*stream-notify-fn*
                                  (lambda (m p)
                                    (let ((notif (make-json-rpc-notification m p)))
                                      (send-sse-event sse-stream (encode-json notif) "message"))))
                                (*stream-call-fn*
                                  (lambda (m p &key (timeout 30))
                                    (stream-call sse-stream m p timeout)))
                                (result (call-with-access-log method id params
                                          (lambda () (funcall handler params)))))
                           (encode-json (make-json-rpc-response id result)))
                       (protocol-error (e)
                         (encode-json (make-json-rpc-error
                                       id (protocol-error-code e)
                                       (mcp-error-message e) (protocol-error-data e))))
                       (error (e)
                         (encode-json (make-json-rpc-error id -32603 (princ-to-string e)))))))
               ;; Send final response as SSE event
               (send-sse-event sse-stream response-json "message")
               :streamed))
            ;; Unknown method
            (t
             (let ((err (encode-json (make-json-rpc-error
                                       id -32601 (format nil "Method not found: ~a" method)))))
               (send-sse-event sse-stream err "message")
               :streamed)))))
    (error (e)
      (log:error "Parse error: ~a" e)
      (let ((err (encode-json (make-json-rpc-error nil -32700 "Parse error"))))
        (send-sse-event sse-stream err "message")
        :streamed))))

(defun stream-call (sse-stream method params timeout)
  "Send a JSON-RPC request to the client via SSE and wait for the response.
The client will POST the response back, which gets routed via deliver-pending-response."
  (let* ((id (next-request-id))
         (lock (bt:make-lock "stream-call"))
         (cv (bt:make-condition-variable :name "stream-call-cv"))
         (result-cell (list nil)))
    ;; Register pending response
    (bt:with-lock-held (*pending-responses-lock*)
      (setf (gethash id *pending-responses*) (cons lock (cons cv result-cell))))
    (unwind-protect
         (progn
           ;; Send request as SSE event
           (let ((req (make-json-rpc-request id method params)))
             (send-sse-event sse-stream (encode-json req) "message"))
           ;; Wait for response
           (bt:with-lock-held (lock)
             (let ((deadline (+ (get-internal-real-time)
                                (* timeout internal-time-units-per-second))))
               (loop until (car result-cell)
                     do (let ((remaining (/ (- deadline (get-internal-real-time))
                                            internal-time-units-per-second)))
                          (when (<= remaining 0)
                            (error "Timeout waiting for response to ~a" method))
                          (bt:condition-wait cv lock :timeout remaining)))))
           ;; Extract result
           (let ((response (car result-cell)))
             (or (gethash "result" response)
                 (let ((err (gethash "error" response)))
                   (error "Server→client request ~a failed: ~a"
                          method (and err (gethash "message" err)))))))
      ;; Cleanup
      (bt:with-lock-held (*pending-responses-lock*)
        (remhash id *pending-responses*)))))

;;; --- HTTP handlers ---

(defun post-handler ()
  "Handle POST to MCP endpoint.
Uses SSE streaming for JSON-RPC requests (to support mid-execution messaging).
Returns 202 for notifications and responses."
  (let* ((body (hunchentoot:raw-post-data :force-text t))
         (parsed (handler-case (decode-json body)
                   (error () nil))))
    (unless parsed
      (setf (hunchentoot:return-code*) 400)
      (return-from post-handler "Bad Request: invalid JSON"))
    (cond
      ;; Response to a pending server->client request
      ((is-json-rpc-response-p parsed)
       (deliver-pending-response parsed)
       (setf (hunchentoot:return-code*) 202)
       "")
      ;; Notification (no id)
      ((null (gethash "id" parsed))
       (let ((method (gethash "method" parsed))
             (params (gethash "params" parsed)))
         (let ((handler (and method (gethash method *handlers*))))
           (when handler
             (handler-case
                 (call-with-access-log method nil params (lambda () (funcall handler params)))
               (error (e) (log:error "Notification handler error (~a): ~a" method e))))))
       (setf (hunchentoot:return-code*) 202)
       "")
      ;; JSON-RPC request — use SSE streaming
      (t
       (setf (hunchentoot:content-type*) "text/event-stream")
       (setf (hunchentoot:header-out "Cache-Control") "no-cache")
       ;; Assign session ID on initialize
       (when (equal "initialize" (gethash "method" parsed))
         (let ((session-id (generate-session-id)))
           (setf *mcp-session-id* session-id)
           (setf (hunchentoot:header-out "MCP-Session-Id") session-id)
           (log:debug "Session created: ~a" session-id)))
       (let ((stream (hunchentoot:send-headers)))
         (handle-request-streaming body stream))))))

(defun get-handler ()
  "Handle GET to MCP endpoint — SSE stream for server-initiated messages."
  (let ((session-id (hunchentoot:header-in* "MCP-Session-Id")))
    (unless (and *mcp-session-id* (equal session-id *mcp-session-id*))
      (setf (hunchentoot:return-code*) 400)
      (return-from get-handler "Bad Request: invalid session"))
    (setf (hunchentoot:content-type*) "text/event-stream")
    (setf (hunchentoot:header-out "Cache-Control") "no-cache")
    (setf (hunchentoot:header-out "Connection") "keep-alive")
    (let ((stream (hunchentoot:send-headers)))
      (bt:with-lock-held (*sse-clients-lock*)
        (setf (gethash session-id *sse-clients*) stream))
      (unwind-protect
           (loop
             (unless (open-stream-p stream)
               (log:info "SSE client disconnected: session=~a" session-id)
               (return))
             (sleep 30)
             (handler-case
                 (progn
                   (write-utf8 (format nil ": keepalive~%~%") stream)
                   (force-output stream))
               (error (e)
                 (log:debug "Keepalive error: ~a" e)
                 (return))))
        (bt:with-lock-held (*sse-clients-lock*)
          (remhash session-id *sse-clients*))))))

(defun delete-handler ()
  "Handle DELETE to MCP endpoint — session termination."
  (let ((session-id (hunchentoot:header-in* "MCP-Session-Id")))
    (when (and *mcp-session-id* (equal session-id *mcp-session-id*))
      (setf *mcp-session-id* nil)
      (bt:with-lock-held (*sse-clients-lock*)
        (when *sse-clients*
          (let ((stream (gethash session-id *sse-clients*)))
            (when stream (remhash session-id *sse-clients*)))))
      (log:debug "Session terminated: ~a" session-id)))
  (setf (hunchentoot:return-code*) 202)
  "")

(defun options-handler ()
  (setf (hunchentoot:header-out "Access-Control-Allow-Origin") "*")
  (setf (hunchentoot:header-out "Access-Control-Allow-Methods") "GET, POST, DELETE, OPTIONS")
  (setf (hunchentoot:header-out "Access-Control-Allow-Headers")
        "Content-Type, Accept, MCP-Session-Id, MCP-Protocol-Version")
  "")

;;; --- DNS rebinding protection ---

(defun localhost-p (host)
  (when host
    (let ((h (string-downcase host)))
      (let ((colon (position #\: h :from-end t)))
        (when (and colon (> colon 0))
          (unless (and (char= (char h 0) #\[)
                       (null (position #\] h :start colon)))
            (setf h (subseq h 0 colon)))))
      (or (string= h "localhost")
          (string= h "127.0.0.1")
          (string= h "[::1]")
          (string= h "::1")))))

(defun valid-origin-p (request)
  (declare (ignore request))
  (let ((origin (hunchentoot:header-in* :origin)))
    (if origin
        (let* ((scheme-end (search "://" origin))
               (host-part (if scheme-end (subseq origin (+ 3 scheme-end)) origin)))
          (localhost-p host-part))
        t)))

;;; --- Acceptor ---

(defclass mcp-acceptor (hunchentoot:acceptor)
  ()
  (:documentation "Custom acceptor for MCP Streamable HTTP server."))

(defmethod hunchentoot:acceptor-log-message ((acceptor mcp-acceptor) log-level format-string &rest args)
  "Suppress noisy connection errors from client disconnects."
  (if (and (eq log-level :error)
           (let ((msg (apply #'format nil format-string args)))
             (or (search "CONNECTION-ABORTED" msg)
                 (search "Connection reset by peer" msg)
                 (search "connection-reset" msg))))
      (log:debug "Client disconnected")
      (call-next-method)))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor mcp-acceptor) request)
  (let ((path (hunchentoot:script-name request))
        (method (hunchentoot:request-method request)))
    (log:debug "HTTP ~a ~a" method path)
    (unless (or (eq method :options) (valid-origin-p request))
      (setf (hunchentoot:return-code*) 403)
      (return-from hunchentoot:acceptor-dispatch-request "Forbidden: invalid origin"))
    (setf (hunchentoot:header-out "Access-Control-Allow-Origin") "*")
    (cond
      ((eq method :options) (options-handler))
      ((and (eq method :post) (string= path *mcp-path*)) (post-handler))
      ((and (eq method :get) (string= path *mcp-path*)) (get-handler))
      ((and (eq method :delete) (string= path *mcp-path*)) (delete-handler))
      (t (setf (hunchentoot:return-code*) 404) "Not Found"))))

;;; --- Public API ---

(defun start-sse-server (handlers &key (port 8080) (path "/mcp"))
  "Start MCP Streamable HTTP server on PORT with HANDLERS hash-table."
  (when *sse-server* (stop-sse-server))
  (setf *handlers* handlers
        *mcp-path* path
        *mcp-session-id* nil
        *sse-clients* (make-hash-table :test #'equal)
        *pending-responses* (make-hash-table :test #'equal)
        *sse-server* (make-instance 'mcp-acceptor :port port
                                    :access-log-destination nil))
  (hunchentoot:start *sse-server*)
  (log:info "MCP Streamable HTTP server started on port ~a" port)
  (format t "~&MCP server running on http://localhost:~a~a~%" port path)
  *sse-server*)

(defun stop-sse-server ()
  "Stop the MCP Streamable HTTP server."
  (when *sse-server*
    (hunchentoot:stop *sse-server*)
    (setf *sse-server* nil *mcp-session-id* nil)
    (when *sse-clients* (clrhash *sse-clients*))
    (when *pending-responses* (clrhash *pending-responses*))
    (log:info "MCP server stopped")))
