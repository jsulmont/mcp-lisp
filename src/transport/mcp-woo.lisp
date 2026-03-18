;;;; src/transport/mcp-woo.lisp
;;;;
;;;; MCP Streamable HTTP transport using Woo (libev).
;;;;
;;;; Architecture:
;;;;   - N event loops (one per core), each handles requests inline
;;;;   - All handlers run on the event loop thread that received the request
;;;;   - Per-event-loop ev_async bridge for cross-thread SSE writes (send-to-session)

(defpackage #:mcp-lisp/src/transport/mcp-woo
  (:use #:cl #:log4cl)
  (:import-from #:mcp-lisp/src/json
                #:encode-json
                #:decode-json
                #:make-ht)
  (:import-from #:mcp-lisp/src/conditions
                #:protocol-error
                #:protocol-error-code
                #:protocol-error-data
                #:mcp-error-message)
  (:import-from #:mcp-lisp/src/server/state
                #:*current-session*
                #:session-protocol-version)
  (:import-from #:mcp-lisp/src/transport/worker-pool
                #:make-worker-pool
                #:submit-to-pool
                #:stop-worker-pool)
  (:export #:start-sse-server
           #:stop-sse-server
           #:*sse-server*
           #:*stream-notify-fn*
           #:*stream-call-fn*
           #:*access-log-stream*
           #:generate-session-id
           #:send-to-session
           #:*sse-clients*
           #:*sse-clients-lock*
           #:*sessions*))

(in-package #:mcp-lisp/src/transport/mcp-woo)

;;; =====================================================================
;;; Module globals
;;; =====================================================================

(defvar *sse-server* nil "Woo listener (returned by woo:run, used by woo:stop).")
(defvar *server-thread* nil "Thread running the Woo event loop.")
(defvar *handlers* nil "Hash-table of method -> handler function.")
(defvar *mcp-session-id* nil "Session ID for the current request, bound per-request.")
(defvar *sessions* nil "Hash-table :synchronized t — thread-safe without explicit lock.")
(defvar *session-factory* nil "Function () -> new session object.")
(defvar *sse-clients* nil "Hash-table: session-id -> (cons writer bridge).")
(defvar *sse-clients-lock* (bt:make-lock "sse-clients"))
(defvar *session-id-lock* (bt:make-lock "session-id"))
(defvar *next-session-id* 0)
(defvar *mcp-path* "/mcp")

;;; Mid-execution messaging
(defvar *stream-notify-fn* nil)
(defvar *stream-call-fn* nil)

;;; Pending responses for server→client requests
(defvar *pending-responses* (make-hash-table :test #'equal))
(defvar *pending-responses-lock* (bt:make-lock "pending-responses"))
(defvar *next-request-id* 0)
(defvar *request-id-lock* (bt:make-lock "request-id"))

;;; Access logging
(defvar *access-log-stream* nil)

;;; Keepalive
(defvar *keepalive-thread* nil "Keepalive thread for SSE clients.")
(defvar *keepalive-stop* nil "Flag to signal keepalive thread to exit.")

;;; Worker pool for streaming handlers (tools/call)
(defvar *tool-pool* nil "Worker pool for tool execution (avoids blocking event loops).")

;;; A2A handler (set externally)
(defvar *a2a-handler* nil
  "Function (env method path body) -> clack response triple, or NIL.
Set by a2a/server.lisp to handle A2A routes on the same Woo server.")

;;; =====================================================================
;;; Data structures
;;; =====================================================================

(defstruct evloop-bridge
  "Per-event-loop state for the ev_async bridge."
  evloop-ptr      ; CFFI pointer to the libev event loop
  async-watcher   ; CFFI pointer to ev_async watcher
  result-queue)   ; sb-concurrency:queue — workers enqueue here

(defvar *bridges* (make-hash-table :test #'eql)
  "Map: evloop-pointer-address (integer) → evloop-bridge.
Writes happen once per event loop at startup (locked); reads are lock-free after.")
(defvar *bridges-lock* (bt:make-lock "bridges-write"))

(defstruct completion
  type       ; :sse-write | :full-response | :sse-close
  responder  ; Clack responder fn (for :full-response)
  writer     ; Clack streaming writer fn (for :sse-write / :sse-close)
  data)      ; string — SSE frame or response body list

;;; =====================================================================
;;; Reused helpers: timestamps, access logging, sessions
;;; =====================================================================

(defun format-iso8601 ()
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            year month day hour min sec)))

(defun extract-target (method params)
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

(defun emit-access-log (method id session-id duration-us status &key error-msg target)
  (when *access-log-stream*
    (let ((entry (make-ht "ts" (format-iso8601)
                          "session" (or session-id "-")
                          "method" (or method "-")
                          "id" id
                          "duration_us" duration-us
                          "status" status)))
      (when target (setf (gethash "target" entry) target))
      (when error-msg (setf (gethash "error" entry) error-msg))
      (handler-case
          (progn
            (write-string (encode-json entry) *access-log-stream*)
            (terpri *access-log-stream*)
            (force-output *access-log-stream*))
        (error () nil)))))

(defun call-with-access-log (method id params thunk)
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

(defun generate-session-id ()
  (bt:with-lock-held (*session-id-lock*)
    (format nil "~a-~a" (get-universal-time) (incf *next-session-id*))))

(defun get-session (session-id)
  (when (and session-id *sessions*)
    (gethash session-id *sessions*)))

(defun add-session (session-id session)
  (when *sessions*
    (setf (gethash session-id *sessions*) session)))

(defun remove-session (session-id)
  (when *sessions*
    (remhash session-id *sessions*)))

(defun session-count ()
  (if *sessions* (hash-table-count *sessions*) 0))

(defun next-request-id ()
  (bt:with-lock-held (*request-id-lock*)
    (format nil "srv-~a" (incf *next-request-id*))))

;;; =====================================================================
;;; JSON-RPC envelope helpers (per-thread reusable hash-tables)
;;; =====================================================================

(defvar *thread-envelopes* (make-hash-table :test #'eq :synchronized t)
  "Thread → envelope-list map.  Each thread gets its own reusable
JSON-RPC hash-tables on first access.  :synchronized t for safe init.")

(defun make-envelope-list ()
  (list (make-hash-table :test #'equal :size 4)   ; response
        (make-hash-table :test #'equal :size 4)   ; error
        (make-hash-table :test #'equal :size 4)   ; error-inner
        (make-hash-table :test #'equal :size 5)   ; request
        (make-hash-table :test #'equal :size 4))) ; notification

(defun thread-envelopes ()
  (let ((thread (bt:current-thread)))
    (or (gethash thread *thread-envelopes*)
        (setf (gethash thread *thread-envelopes*) (make-envelope-list)))))

(defun make-json-rpc-response (id result)
  (let ((ht (first (thread-envelopes))))
    (setf (gethash "jsonrpc" ht) "2.0"
          (gethash "id" ht) id
          (gethash "result" ht) result)
    (remhash "error" ht)
    ht))

(defun make-json-rpc-error (id code message &optional data)
  (destructuring-bind (resp err-ht err-inner &rest _) (thread-envelopes)
    (declare (ignore resp _))
    (setf (gethash "code" err-inner) code
          (gethash "message" err-inner) message)
    (if data
        (setf (gethash "data" err-inner) data)
        (remhash "data" err-inner))
    (setf (gethash "jsonrpc" err-ht) "2.0"
          (gethash "id" err-ht) id
          (gethash "error" err-ht) err-inner)
    (remhash "result" err-ht)
    err-ht))

(defun make-json-rpc-request (id method params)
  (let ((ht (fourth (thread-envelopes))))
    (setf (gethash "jsonrpc" ht) "2.0"
          (gethash "id" ht) id
          (gethash "method" ht) method)
    (if params
        (setf (gethash "params" ht) params)
        (remhash "params" ht))
    ht))

(defun make-json-rpc-notification (method params)
  (let ((ht (fifth (thread-envelopes))))
    (setf (gethash "jsonrpc" ht) "2.0"
          (gethash "method" ht) method)
    (if params
        (setf (gethash "params" ht) params)
        (remhash "params" ht))
    (remhash "id" ht)
    ht))

;;; =====================================================================
;;; Response routing for server→client requests
;;; =====================================================================

(defun is-json-rpc-response-p (parsed)
  (and (hash-table-p parsed)
       (gethash "id" parsed)
       (null (gethash "method" parsed))
       (or (nth-value 1 (gethash "result" parsed))
           (nth-value 1 (gethash "error" parsed)))))

(defun deliver-pending-response (parsed)
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

;;; =====================================================================
;;; DNS rebinding protection (adapted for Clack env)
;;; =====================================================================

(defun strip-port (host)
  "Strip port suffix from HOST string.  Handles IPv6 bracket notation:
  localhost:8080    → localhost
  127.0.0.1:8080   → 127.0.0.1
  [::1]:8080       → [::1]
  [::1]            → [::1]
  ::1              → ::1"
  (if (and (plusp (length host)) (char= (char host 0) #\[))
      ;; Bracketed IPv6: port follows the closing bracket
      (let ((bracket (position #\] host)))
        (if bracket (subseq host 0 (1+ bracket)) host))
      ;; Non-bracketed: strip only when there's exactly one colon (host:port).
      ;; Multiple colons means bare IPv6 — don't strip.
      (let ((first-colon (position #\: host))
            (last-colon (position #\: host :from-end t)))
        (if (and first-colon (= first-colon last-colon))
            (subseq host 0 first-colon)
            host))))

(defun localhost-p (host)
  "Return T if HOST (with optional port) refers to localhost."
  (when host
    (let ((h (strip-port (string-downcase host))))
      (or (string= h "localhost")
          (string= h "127.0.0.1")
          (string= h "[::1]")
          (string= h "::1")))))

(defun valid-origin-p (env)
  (let* ((headers (getf env :headers))
         (origin (and headers (gethash "origin" headers))))
    (if origin
        (let* ((scheme-end (search "://" origin))
               (host-part (if scheme-end (subseq origin (+ 3 scheme-end)) origin)))
          (localhost-p host-part))
        t)))

;;; =====================================================================
;;; SSE helpers (write via completion queue → event loop)
;;; =====================================================================

(defun format-sse-event (data &optional event-type)
  "Format an SSE event as a string."
  (with-output-to-string (s)
    (when event-type
      (format s "event: ~a~%" event-type))
    (format s "data: ~a~%~%" data)))

(defun enqueue-to-bridge (bridge completion)
  "Enqueue a completion and wake the bridge's event loop."
  (sb-concurrency:enqueue completion (evloop-bridge-result-queue bridge))
  (lev:ev-async-send (evloop-bridge-evloop-ptr bridge)
                      (evloop-bridge-async-watcher bridge)))

(defun send-to-session (session-id data &optional event-type)
  "Send SSE event to a session's GET stream via its event loop's bridge."
  (let ((entry nil))
    (bt:with-lock-held (*sse-clients-lock*)
      (setf entry (and *sse-clients* (gethash session-id *sse-clients*))))
    (when entry
      (destructuring-bind (writer . bridge) entry
        (enqueue-to-bridge bridge
         (make-completion :type :sse-write
                          :writer writer
                          :data (format-sse-event data event-type)))
        t))))

;;; =====================================================================
;;; ev_async bridge: drain callback (runs on event loop thread)
;;; =====================================================================

(defun handle-completion (c)
  "Process a single completion on the event loop thread."
  (handler-case
      (ecase (completion-type c)
        (:sse-write
         (let ((writer (completion-writer c))
               (bytes (trivial-utf-8:string-to-utf-8-bytes (completion-data c))))
           (funcall writer bytes)))
        (:sse-close
         (let ((writer (completion-writer c)))
           (funcall writer nil :close t)))
        (:full-response
         (let ((responder (completion-responder c)))
           (funcall responder (completion-data c)))))
    (error (e)
      (log:debug "Completion write error: ~a" e)
      ;; Dead client — try to remove from sse-clients
      (when (and (completion-writer c)
                 (member (completion-type c) '(:sse-write :sse-close)))
        (bt:with-lock-held (*sse-clients-lock*)
          (let ((dead-sids nil))
            (maphash (lambda (sid entry)
                       (when (eq (car entry) (completion-writer c))
                         (push sid dead-sids)))
                     *sse-clients*)
            (dolist (sid dead-sids)
              (remhash sid *sse-clients*))))))))

(cffi:defcallback drain-results-cb :void ((evloop :pointer) (w :pointer) (revents :int))
  (declare (ignore w revents))
  (let ((bridge (gethash (cffi:pointer-address evloop) *bridges*)))
    (when bridge
      (loop for c = (sb-concurrency:dequeue (evloop-bridge-result-queue bridge))
            while c
            do (handle-completion c)))))

(defun ensure-bridge ()
  "Initialize ev_async bridge for the current event loop thread. Idempotent.
Returns the bridge for this event loop."
  (let ((key (cffi:pointer-address woo.ev.event-loop:*evloop*)))
    (or (gethash key *bridges*)  ; lock-free read (fast path)
        (bt:with-lock-held (*bridges-lock*)
          ;; Double-check after acquiring lock
          (or (gethash key *bridges*)
              (let* ((evloop woo.ev.event-loop:*evloop*)
                     (queue (sb-concurrency:make-queue :name "mcp-results"))
                     (watcher (cffi:foreign-alloc '(:struct lev:ev-async)))
                     (bridge (make-evloop-bridge :evloop-ptr evloop
                                                  :async-watcher watcher
                                                  :result-queue queue)))
                (lev:ev-async-init watcher 'drain-results-cb)
                (lev:ev-async-start evloop watcher)
                (setf (gethash key *bridges*) bridge)
                (log:debug "ev_async bridge created for evloop ~a" key)
                bridge))))))

(defun current-bridge ()
  "Get the bridge for the current event loop thread."
  (gethash (cffi:pointer-address woo.ev.event-loop:*evloop*) *bridges*))

;;; =====================================================================
;;; SSE direct write helpers (inline on event loop thread)
;;; =====================================================================

(defun write-sse (writer data)
  "Write an SSE frame directly to a Woo writer (same thread)."
  (funcall writer (trivial-utf-8:string-to-utf-8-bytes data)))

(defun close-sse (writer)
  "Close an SSE stream."
  (funcall writer nil :close t))

;;; =====================================================================
;;; stream-call (server→client request, runs on worker thread)
;;; =====================================================================

(defun stream-call-via-bridge (bridge writer method params timeout)
  "Send a JSON-RPC request via SSE and wait for the response.
Writes go through the bridge (safe from any thread); the calling thread
blocks on a CV until the response POST arrives on an event loop."
  (let* ((id (next-request-id))
         (lock (bt:make-lock "stream-call"))
         (cv (bt:make-condition-variable :name "stream-call-cv"))
         (result-cell (list nil)))
    ;; Register pending response
    (bt:with-lock-held (*pending-responses-lock*)
      (setf (gethash id *pending-responses*) (cons lock (cons cv result-cell))))
    (unwind-protect
         (progn
           ;; Send request via bridge (not direct write — we're on a worker thread)
           (let ((req-json (encode-json (make-json-rpc-request id method params))))
             (enqueue-to-bridge bridge
               (make-completion :type :sse-write
                                :writer writer
                                :data (format-sse-event req-json "message"))))
           ;; Wait for response — blocks the worker thread, not the event loop
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

;;; =====================================================================
;;; SSE keepalive thread
;;; =====================================================================

(defun keepalive-loop ()
  (loop until *keepalive-stop*
        do (sleep 30)
           (unless *keepalive-stop*
             (handler-case
                 (let ((clients nil))
                   (bt:with-lock-held (*sse-clients-lock*)
                     (when *sse-clients*
                       (maphash (lambda (sid entry)
                                  (declare (ignore sid))
                                  (push entry clients))
                                *sse-clients*)))
                   (dolist (entry clients)
                     (destructuring-bind (writer . bridge) entry
                       (enqueue-to-bridge bridge
                        (make-completion :type :sse-write
                                         :writer writer
                                         :data (format nil ": keepalive~%~%"))))))
               (error (e)
                 (log:debug "Keepalive error: ~a" e))))))

(defun start-keepalive ()
  (setf *keepalive-stop* nil)
  (setf *keepalive-thread*
        (bt:make-thread #'keepalive-loop :name "mcp-keepalive")))

(defun stop-keepalive ()
  (setf *keepalive-stop* t)
  (setf *keepalive-thread* nil))

;;; =====================================================================
;;; Clack env helpers
;;; =====================================================================

(defun env-header (env name)
  "Get a header value from Clack env."
  (let ((headers (getf env :headers)))
    (when headers
      (gethash name headers))))

(defun read-body-string (env)
  "Read the request body as a UTF-8 string from Clack env."
  (let ((raw-body (getf env :raw-body))
        (content-length (getf env :content-length)))
    (when raw-body
      (etypecase raw-body
        ((simple-array (unsigned-byte 8) (*))
         (trivial-utf-8:utf-8-bytes-to-string raw-body))
        (stream
         (let* ((len (or content-length 65536))
                (buf (make-array len :element-type '(unsigned-byte 8))))
           (let ((n (read-sequence buf raw-body)))
             (trivial-utf-8:utf-8-bytes-to-string buf :end n))))))))

;;; =====================================================================
;;; Request handlers (called on event loop thread via Clack app)
;;; =====================================================================

(defun make-immediate-response (status headers body-string)
  "Create an immediate Clack response triple. BODY-STRING is a single string."
  (list status headers (list body-string)))

(defun make-sse-headers (&optional extra-headers)
  "Create SSE response headers as a plist."
  (append (list :content-type "text/event-stream"
                :cache-control "no-cache"
                :access-control-allow-origin "*")
          extra-headers))

(defun make-json-headers ()
  (list :content-type "application/json"
        :access-control-allow-origin "*"))

(defun handle-post (env responder)
  "Handle POST /mcp — JSON-RPC dispatch.
All handlers run inline on the event loop thread."
  (let* ((body (read-body-string env))
         (parsed (handler-case (decode-json body)
                   (error () nil))))
    (unless parsed
      (funcall responder (make-immediate-response 400 nil "Bad Request: invalid JSON"))
      (return-from handle-post))
    (cond
      ;; JSON-RPC response to a pending server→client request
      ((is-json-rpc-response-p parsed)
       (deliver-pending-response parsed)
       (funcall responder (make-immediate-response 202 (list :access-control-allow-origin "*") "")))

      ;; Notification (no id) — run inline
      ((null (gethash "id" parsed))
       (let* ((session-id (env-header env "mcp-session-id"))
              (*current-session* (get-session session-id))
              (*mcp-session-id* session-id)
              (method (gethash "method" parsed))
              (params (gethash "params" parsed))
              (handler (and method (gethash method *handlers*))))
         (when handler
           (handler-case
               (call-with-access-log method nil params (lambda () (funcall handler params)))
             (error (e) (log:error "Notification handler error (~a): ~a" method e)))))
       (funcall responder (make-immediate-response 202 (list :access-control-allow-origin "*") "")))

      ;; tools/call — SSE streaming (needs *stream-notify-fn* and *stream-call-fn*)
      ((equal "tools/call" (gethash "method" parsed))
       (handle-post-streaming env responder parsed))

      ;; All other JSON-RPC requests — handle inline, return JSON
      (t
       (handle-post-inline env responder parsed)))))

(defun handle-post-inline (env responder parsed)
  "Handle a JSON-RPC request inline on the event loop. Returns JSON response."
  (let* ((is-init (equal "initialize" (gethash "method" parsed)))
         (session-id (if is-init
                         (generate-session-id)
                         (env-header env "mcp-session-id")))
         (session (if is-init
                      (funcall *session-factory*)
                      (get-session session-id))))
    (unless session
      (funcall responder (make-immediate-response
                          400 (list :access-control-allow-origin "*")
                          "Bad Request: invalid or missing session"))
      (return-from handle-post-inline))
    (let* ((*current-session* session)
           (*mcp-session-id* session-id)
           (*stream-notify-fn* nil)
           (*stream-call-fn* nil)
           (id (gethash "id" parsed))
           (method (gethash "method" parsed))
           (params (gethash "params" parsed))
           (handler (gethash method *handlers*)))
      (if handler
          (let ((response-json
                  (handler-case
                      (let ((result (call-with-access-log method id params
                                      (lambda () (funcall handler params)))))
                        (when (and is-init (session-protocol-version session))
                          (add-session session-id session))
                        (encode-json (make-json-rpc-response id result)))
                    (protocol-error (e)
                      (encode-json (make-json-rpc-error
                                    id (protocol-error-code e)
                                    (mcp-error-message e) (protocol-error-data e))))
                    (error (e)
                      (encode-json (make-json-rpc-error id -32603 (princ-to-string e)))))))
            (funcall responder
                     (make-immediate-response
                      200
                      (append (make-json-headers)
                              (when is-init (list :mcp-session-id session-id)))
                      response-json)))
          ;; Unknown method
          (progn
            (emit-access-log method id *mcp-session-id* 0 "not_found"
                            :target (extract-target method params))
            (funcall responder
                     (make-immediate-response
                      200 (make-json-headers)
                      (encode-json (make-json-rpc-error
                                    id -32601
                                    (format nil "Method not found: ~a" method))))))))))

(defun handle-post-streaming (env responder parsed)
  "Handle a JSON-RPC request via SSE streaming.
The handler runs on a worker thread so it can block (e.g. stream-call
for sampling/elicitation) without deadlocking the event loop.  All SSE
writes go through the ev_async bridge."
  (let* ((session-id (env-header env "mcp-session-id"))
         (session (get-session session-id)))
    (unless session
      (funcall responder (make-immediate-response
                          400 (list :access-control-allow-origin "*")
                          "Bad Request: invalid or missing session"))
      (return-from handle-post-streaming))
    (let* ((bridge (ensure-bridge))
           (writer (funcall responder (list 200 (make-sse-headers))))
           (id (gethash "id" parsed))
           (method (gethash "method" parsed))
           (params (gethash "params" parsed))
           (handler (gethash method *handlers*)))
      (if handler
          ;; Dispatch to worker pool — event loop returns immediately
          (submit-to-pool *tool-pool*
            (lambda ()
              (let* ((*current-session* session)
                     (*mcp-session-id* session-id)
                     (*stream-notify-fn*
                       (lambda (m p)
                         (let ((notif-json (encode-json (make-json-rpc-notification m p))))
                           (enqueue-to-bridge bridge
                             (make-completion :type :sse-write
                                              :writer writer
                                              :data (format-sse-event notif-json "message"))))))
                     (*stream-call-fn*
                       (lambda (m p &key (timeout 30))
                         (stream-call-via-bridge bridge writer m p timeout)))
                     (response-json
                       (handler-case
                           (encode-json
                            (make-json-rpc-response
                             id (call-with-access-log method id params
                                  (lambda () (funcall handler params)))))
                         (protocol-error (e)
                           (encode-json (make-json-rpc-error
                                         id (protocol-error-code e)
                                         (mcp-error-message e) (protocol-error-data e))))
                         (error (e)
                           (encode-json (make-json-rpc-error id -32603 (princ-to-string e)))))))
                (enqueue-to-bridge bridge
                  (make-completion :type :sse-write
                                   :writer writer
                                   :data (format-sse-event response-json "message")))
                (enqueue-to-bridge bridge
                  (make-completion :type :sse-close :writer writer)))))
          ;; Unknown method — respond inline (no handler to run)
          (progn
            (emit-access-log method id session-id 0 "not_found"
                            :target (extract-target method params))
            (let ((err (encode-json (make-json-rpc-error
                                      id -32601 (format nil "Method not found: ~a" method)))))
              (write-sse writer (format-sse-event err "message"))
              (close-sse writer)))))))

(defun handle-get (env responder)
  "Handle GET /mcp — SSE listener for server-initiated messages.
Registers the writer with its event loop's bridge."
  (let* ((bridge (ensure-bridge))
         (session-id (env-header env "mcp-session-id"))
         (session (get-session session-id)))
    (unless session
      (funcall responder (make-immediate-response
                           400 (list :access-control-allow-origin "*")
                           "Bad Request: invalid session"))
      (return-from handle-get))
    ;; Start SSE stream, get writer
    (let ((writer (funcall responder
                           (list 200 (make-sse-headers
                                      (list :connection "keep-alive"))))))
      ;; Register writer + bridge for this session
      (bt:with-lock-held (*sse-clients-lock*)
        (setf (gethash session-id *sse-clients*) (cons writer bridge))))))

(defun handle-delete (env responder)
  "Handle DELETE /mcp — session termination."
  (let ((session-id (env-header env "mcp-session-id")))
    (when (get-session session-id)
      (let ((entry nil))
        (bt:with-lock-held (*sse-clients-lock*)
          (when *sse-clients*
            (setf entry (gethash session-id *sse-clients*))
            (remhash session-id *sse-clients*)))
        ;; Close the SSE writer via its event loop's bridge
        (when entry
          (destructuring-bind (writer . bridge) entry
            (enqueue-to-bridge bridge
             (make-completion :type :sse-close :writer writer)))))
      (remove-session session-id)
      (log:debug "Session terminated: ~a" session-id)))
  (funcall responder (make-immediate-response 202 (list :access-control-allow-origin "*") "")))

(defun handle-options (env responder)
  (declare (ignore env))
  (funcall responder
           (list 200
                 (list :access-control-allow-origin "*"
                       :access-control-allow-methods "GET, POST, DELETE, OPTIONS"
                       :access-control-allow-headers "Content-Type, Accept, MCP-Session-Id, MCP-Protocol-Version")
                 '(""))))

(defun handle-health (env responder)
  (declare (ignore env))
  (funcall responder
           (list 200 (make-json-headers)
                 (list (encode-json
                        (make-ht "heap_mb" (round (/ (sb-kernel:dynamic-usage) 1048576))
                                 "threads" (length (bt:all-threads))
                                 "sessions" (session-count)
                                 "pending_responses" (hash-table-count *pending-responses*)
                                 "sse_clients" (if *sse-clients* (hash-table-count *sse-clients*) 0)
                                 "bridges" (hash-table-count *bridges*)))))))

;;; =====================================================================
;;; Clack app function
;;; =====================================================================

(defun clack-app (env)
  "Main Clack application — dispatches by method and path.
Returns a delayed response (lambda (responder) ...) for all routes."
  (lambda (responder)
    (let ((method (getf env :request-method))
          (path (getf env :path-info)))
      (log:debug "HTTP ~a ~a" method path)
      ;; CORS / origin check
      (if (and (not (eq method :options)) (not (valid-origin-p env)))
          (funcall responder (make-immediate-response
                               403 (list :access-control-allow-origin "*")
                               "Forbidden: invalid origin"))
          (cond
            ((eq method :options)
             (handle-options env responder))
            ((and (eq method :post) (string= path *mcp-path*))
             (handle-post env responder))
            ((and (eq method :get) (string= path *mcp-path*))
             (handle-get env responder))
            ((and (eq method :delete) (string= path *mcp-path*))
             (handle-delete env responder))
            ((and (eq method :get) (string= path "/health"))
             (handle-health env responder))
            ;; A2A routes
            ((and *a2a-handler*
                  (or (and (eq method :get) (string= path "/.well-known/agent.json"))
                      (and (eq method :post) (string= path "/a2a/message"))
                      (and (eq method :post) (alexandria:starts-with-subseq "/a2a/task/" path)
                           (alexandria:ends-with-subseq "/cancel" path))
                      (and (eq method :get) (alexandria:starts-with-subseq "/a2a/task/" path))))
             (let ((body (when (eq method :post) (read-body-string env))))
               (let ((response (funcall *a2a-handler* env method path body)))
                 (if response
                     (funcall responder response)
                     (funcall responder (make-immediate-response 404 nil "Not Found"))))))
            (t
             (funcall responder (make-immediate-response 404 nil "Not Found"))))))))

;;; =====================================================================
;;; Public API
;;; =====================================================================

(defun cpu-count ()
  "Return the number of available CPU cores."
  (or (ignore-errors
        (parse-integer
         (string-trim '(#\Newline #\Space #\Return)
          (uiop:run-program
           #+darwin '("sysctl" "-n" "hw.logicalcpu")
           #-darwin '("nproc")
           :output :string))))
      4))

(defun start-sse-server (handlers &key (port 8080) (path "/mcp")
                                       (session-factory #'mcp-lisp/src/server/state:make-session)
                                       (event-loops nil)
                                       (tool-workers nil))
  "Start MCP Streamable HTTP server on PORT.
EVENT-LOOPS: number of Woo event loop threads (nil = auto-detect CPU cores).
TOOL-WORKERS: number of worker threads for tools/call (nil = same as event loops).
Most requests run inline on event loops; tools/call runs on the worker
pool so it can block for sampling/elicitation without deadlocking.
Blocks until the server is listening or signals an error on failure."
  (when *sse-server* (stop-sse-server))
  (let ((num-loops (or event-loops (cpu-count))))
    (setf *handlers* handlers
          *mcp-path* path
          *session-factory* session-factory
          *sessions* (make-hash-table :test #'equal :synchronized t)
          *mcp-session-id* nil
          *sse-clients* (make-hash-table :test #'equal)
          *pending-responses* (make-hash-table :test #'equal))
    (clrhash *bridges*)
    ;; Start worker pool for streaming handlers (tools/call)
    (setf *tool-pool* (make-worker-pool (or tool-workers num-loops)
                                         :name "mcp-tool-worker"))
    ;; Start keepalive thread
    (start-keepalive)
    ;; Start Woo in a separate thread (woo:run blocks).
    ;; Poll until the port is accepting connections or the thread dies.
    (let ((startup-error nil))
      (setf *server-thread*
            (bt:make-thread
             (lambda ()
               (handler-case
                   (woo:run (lambda (env)
                              (funcall #'clack-app env))
                            :port port
                            :address "0.0.0.0"
                            :worker-num num-loops
                            :debug nil)
                 (error (e)
                   (setf startup-error e)
                   (log:error "Woo server error: ~a" e))))
             :name "mcp-woo-server"))
      (loop for attempt from 0 below 50  ; up to 5 seconds
            do (cond
                 ((not (bt:thread-alive-p *server-thread*))
                  (stop-keepalive)
                  (error "Woo server died on port ~a: ~a" port (or startup-error "unknown")))
                 ((ignore-errors
                    (let ((sock (usocket:socket-connect "127.0.0.1" port)))
                      (usocket:socket-close sock)
                      t))
                  (return))
                 (t (sleep 0.1)))
            finally (progn
                      (stop-keepalive)
                      (bt:destroy-thread *server-thread*)
                      (setf *server-thread* nil)
                      (error "Woo not accepting connections after 5s on port ~a" port))))
    (setf *sse-server* t)
    (log:info "MCP Streamable HTTP server started on port ~a (~a event loop~:p)"
              port num-loops)
    (format t "~&MCP server running on http://localhost:~a~a~%" port path)
    *server-thread*))

(defun stop-sse-server ()
  "Stop the MCP Streamable HTTP server."
  ;; Stop keepalive
  (stop-keepalive)
  ;; Stop worker pool
  (when *tool-pool*
    (stop-worker-pool *tool-pool* :timeout 5)
    (setf *tool-pool* nil))
  ;; Stop Woo
  (when (and *server-thread* (bt:thread-alive-p *server-thread*))
    (bt:destroy-thread *server-thread*)
    (setf *server-thread* nil))
  ;; Cleanup bridges
  (maphash (lambda (key bridge)
             (declare (ignore key))
             (handler-case
                 (cffi:foreign-free (evloop-bridge-async-watcher bridge))
               (error () nil)))
           *bridges*)
  (clrhash *bridges*)
  (setf *sse-server* nil *mcp-session-id* nil)
  (when *sessions* (clrhash *sessions*))
  (when *sse-clients* (clrhash *sse-clients*))
  (when *pending-responses* (clrhash *pending-responses*))
  (log:info "MCP server stopped"))
