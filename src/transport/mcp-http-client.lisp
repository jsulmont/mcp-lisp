;;;; src/transport/mcp-http-client.lisp
;;;;
;;;; MCP client transport over Streamable HTTP.

(defpackage #:mcp-lisp/src/transport/mcp-http-client
  (:use #:cl)
  (:import-from #:bordeaux-threads)
  (:import-from #:mcp-lisp/src/json
                #:encode-json
                #:decode-json
                #:make-ht)
  (:import-from #:mcp-lisp/src/conditions
                #:mcp-error
                #:protocol-error)
  (:import-from #:mcp-lisp/src/transport/protocol
                #:transport-start
                #:transport-stop
                #:transport-call
                #:transport-notify
                #:transport-running-p
                #:transport-notification-handler)
  (:import-from #:serapeum #:string-prefix-p)
  (:import-from #:dexador)
  (:export #:http-transport
           #:make-http-transport
           #:http-transport-request-handler
           ;; Re-export protocol GFs
           #:transport-start
           #:transport-stop
           #:transport-call
           #:transport-notify
           #:transport-running-p
           #:transport-notification-handler))

(in-package #:mcp-lisp/src/transport/mcp-http-client)

(defclass http-transport ()
  ((url :initarg :url
        :reader http-transport-url
        :documentation "MCP server endpoint URL.")
   (session-id :initform nil
               :accessor http-transport-session-id
               :documentation "MCP-Session-Id from server.")
   (protocol-version :initform nil
                     :accessor http-transport-protocol-version
                     :documentation "Negotiated protocol version for MCP-Protocol-Version header.")
   (next-id :initform 0
            :accessor http-transport-next-id)
   (next-id-lock :initform (bt:make-lock "http-next-id")
                 :accessor http-transport-next-id-lock
                 :documentation "Serializes request-id allocation across concurrent callers.")
   (running :initform nil
            :accessor transport-running-p)
   (notification-handler :initform nil
                         :accessor transport-notification-handler
                         :documentation "Function (method params) for server notifications.")
   (request-handler :initform nil
                    :accessor http-transport-request-handler
                    :documentation "Function (method params) -> result for server-initiated requests.
Used for sampling/createMessage, elicitation/create, etc."))
  (:documentation "MCP client transport over Streamable HTTP."))

(defun make-http-transport (url)
  "Create a new HTTP transport for the given MCP server URL."
  (make-instance 'http-transport :url url))

(defun request-headers (transport)
  "Build common request headers."
  (let ((headers `(("Content-Type" . "application/json")
                   ("Accept" . "application/json, text/event-stream"))))
    (when (http-transport-session-id transport)
      (push (cons "MCP-Session-Id" (http-transport-session-id transport)) headers))
    (when (http-transport-protocol-version transport)
      (push (cons "MCP-Protocol-Version" (http-transport-protocol-version transport)) headers))
    headers))

;;; SSE parsing

(defun parse-sse-events (body)
  "Parse a text/event-stream body into a list of (event-type . data) pairs."
  (let ((events nil)
        (current-event nil)
        (current-data nil))
    (dolist (line (split-lines body))
      (cond
        ((and (= 0 (length line)) current-data)
         (push (cons current-event (format nil "~{~a~^~%~}" (nreverse current-data))) events)
         (setf current-event nil current-data nil))
        ((string-prefix-p "event: " line)
         (setf current-event (subseq line 7)))
        ((string-prefix-p "data: " line)
         (push (subseq line 6) current-data))
        ((string-prefix-p "data:" line)
         (push (subseq line 5) current-data))))
    (when current-data
      (push (cons current-event (format nil "~{~a~^~%~}" (nreverse current-data))) events))
    (nreverse events)))

(defun split-lines (string)
  "Split STRING into lines."
  (loop with start = 0
        with len = (length string)
        for pos = (position #\Newline string :start start)
        collect (let ((line-end (or pos len)))
                  (let ((line (subseq string start line-end)))
                    (if (and (plusp (length line)) (char= (char line (1- (length line))) #\Return))
                        (subseq line 0 (1- (length line)))
                        line)))
        do (if pos (setf start (1+ pos)) (loop-finish))))

;;; SSE event dispatch

(defun post-json-rpc-response (transport id result &key error-msg)
  "POST a JSON-RPC response back to the server for a server-initiated request."
  (let ((resp (if error-msg
                  (make-ht "jsonrpc" "2.0" "id" id
                           "error" (make-ht "code" -32603 "message" error-msg))
                  (make-ht "jsonrpc" "2.0" "id" id "result" result))))
    (handler-case
        (dex:post (http-transport-url transport)
                  :headers (request-headers transport)
                  :content (encode-json resp))
      (error (e) (log:warn "Failed to POST response for ~a: ~a" id e)))))

(defun handle-sse-payload (transport payload)
  "Dispatch a single SSE data PAYLOAD (a JSON string). Notifications go to the
notification handler; server-initiated requests go to the request handler and
their response is POSTed back; a response to one of our calls is returned (else NIL)."
  (handler-case
      (let* ((parsed (decode-json payload))
             (id (gethash "id" parsed))
             (method (gethash "method" parsed)))
        (cond
          ;; Server notification (has method, no id)
          ((and method (null id))
           (when (transport-notification-handler transport)
             (handler-case
                 (funcall (transport-notification-handler transport)
                          method (gethash "params" parsed))
               (error (e) (log:warn "Notification handler error: ~a" e))))
           nil)
          ;; Server request (has method and id) — invoke handler, POST response back
          ((and method id)
           (let ((handler (http-transport-request-handler transport)))
             (if handler
                 (handler-case
                     (let ((result (funcall handler method (gethash "params" parsed))))
                       (post-json-rpc-response transport id result))
                   (error (e)
                     (post-json-rpc-response transport id nil
                                             :error-msg (princ-to-string e))))
                 (post-json-rpc-response transport id nil
                                         :error-msg (format nil "No handler for server request: ~a" method))))
           nil)
          ;; Response (has id, no method) — the answer to our request
          (id parsed)
          (t nil)))
    (error () nil)))

(defun dispatch-sse-response (transport events)
  "Process a fully-buffered list of SSE (event-type . data) pairs. Returns the
JSON-RPC response. Used for non-streaming bodies and by the unit tests."
  (let ((response nil))
    (dolist (event events)
      (let ((data (cdr event)))
        (when (plusp (length data))
          (let ((r (handle-sse-payload transport data)))
            (when r (setf response r))))))
    response))

;;; Incremental SSE reading — required for mid-stream server->client requests.
;;; A buffered read (whole body, then dispatch) deadlocks: the server holds the
;;; tools/call stream open until it receives our response to its sampling /
;;; elicitation request, but we cannot send that response until the body closes.
;;; So we read the stream line by line and dispatch each event as it arrives.

(defun utf8-bytes-to-string (bytes)
  (trivial-utf-8:utf-8-bytes-to-string
   (coerce bytes '(simple-array (unsigned-byte 8) (*)))))

(defun sse-read-line (stream)
  "Read one LF-terminated line from STREAM (octet or character), CR stripped.
Returns the line string, or :eof at end of stream."
  (if (subtypep (stream-element-type stream) 'character)
      (let ((line (read-line stream nil :eof)))
        (if (eq line :eof) :eof (string-right-trim '(#\Return) line)))
      (let ((bytes (make-array 64 :element-type '(unsigned-byte 8)
                                  :adjustable t :fill-pointer 0)))
        (loop for b = (read-byte stream nil :eof)
              do (cond
                   ((eq b :eof)
                    (return (if (zerop (fill-pointer bytes)) :eof
                                (utf8-bytes-to-string bytes))))
                   ((= b 10)
                    (when (and (plusp (fill-pointer bytes))
                               (= 13 (aref bytes (1- (fill-pointer bytes)))))
                      (decf (fill-pointer bytes)))
                    (return (utf8-bytes-to-string bytes)))
                   (t (vector-push-extend b bytes)))))))

(defun sse-field-value (line prefix-length)
  "The value of an SSE field LINE after its PREFIX-LENGTH (one optional space stripped)."
  (let ((s (subseq line prefix-length)))
    (if (and (plusp (length s)) (char= (char s 0) #\Space)) (subseq s 1) s)))

(defun dispatch-sse-stream (transport stream)
  "Read text/event-stream from STREAM incrementally, dispatching notifications and
server-initiated requests as they arrive. Returns the JSON-RPC response object
(the answer to our request) once seen."
  (let ((event-data nil) (response nil))
    (flet ((flush ()
             (when event-data
               (let ((payload (format nil "~{~a~^~%~}" (nreverse event-data))))
                 (setf event-data nil)
                 (when (plusp (length payload))
                   (let ((r (handle-sse-payload transport payload)))
                     (when r (setf response r))))))))
      (loop
        (let ((line (sse-read-line stream)))
          (when (eq line :eof) (flush) (return response))
          (cond
            ((zerop (length line))
             (flush)
             (when response (return response)))
            ((string-prefix-p "data:" line)
             (push (sse-field-value line 5) event-data))
            ;; event:/id:/retry: lines carry no JSON-RPC payload for us — ignored.
            (t nil)))))))

(defun slurp-stream (stream)
  "Read all of STREAM (octet or character) into a string (UTF-8 for octets)."
  (if (subtypep (stream-element-type stream) 'character)
      (with-output-to-string (out)
        (loop for c = (read-char stream nil :eof)
              until (eq c :eof) do (write-char c out)))
      (let ((bytes (make-array 256 :element-type '(unsigned-byte 8)
                                   :adjustable t :fill-pointer 0)))
        (loop for b = (read-byte stream nil :eof)
              until (eq b :eof) do (vector-push-extend b bytes))
        (utf8-bytes-to-string bytes))))

;;; --- Protocol implementation ---

(defmethod transport-start ((transport http-transport))
  "Mark transport as running."
  (setf (transport-running-p transport) t)
  transport)

(defmethod transport-stop ((transport http-transport))
  "Stop the transport, terminate the session."
  (when (http-transport-session-id transport)
    (handler-case
        (dex:delete (http-transport-url transport)
                    :headers (request-headers transport))
      (error () nil)))
  (setf (transport-running-p transport) nil
        (http-transport-session-id transport) nil)
  transport)

(defmethod transport-call ((transport http-transport) method params &key (timeout 30))
  "Make a JSON-RPC call over HTTP."
  (unless (transport-running-p transport)
    (error 'mcp-error :message "Transport not running"))
  (let* ((id (bt:with-lock-held ((http-transport-next-id-lock transport))
               (incf (http-transport-next-id transport))))
         (request (make-ht "jsonrpc" "2.0" "id" id "method" method))
         (is-init (string= method "initialize")))
    (when params
      (setf (gethash "params" request) params))
    ;; :want-stream lets us read SSE incrementally so we can answer mid-stream
    ;; server->client requests (sampling/elicitation) before the body closes.
    (multiple-value-bind (stream status headers)
        (dex:post (http-transport-url transport)
                  :headers (request-headers transport)
                  :content (encode-json request)
                  :want-stream t
                  :force-binary t
                  :keep-alive nil
                  :read-timeout timeout
                  :connect-timeout timeout)
      (unwind-protect
           (progn
             (unless (= status 200)
               (error 'mcp-error :message (format nil "HTTP ~a" status)))
             ;; Capture session ID from initialize response
             (when is-init
               (let ((sid (gethash "mcp-session-id" headers)))
                 (when sid
                   (setf (http-transport-session-id transport) sid))))
             ;; Parse response based on content-type
             (let* ((ct (or (gethash "content-type" headers) ""))
                    (response
                      (if (search "text/event-stream" ct)
                          (dispatch-sse-stream transport stream)
                          (decode-json (slurp-stream stream)))))
               (unless response
                 (error 'mcp-error :message "No response received"))
               ;; Capture protocol version from initialize
               (when is-init
                 (let ((result (gethash "result" response)))
                   (when result
                     (setf (http-transport-protocol-version transport)
                           (gethash "protocolVersion" result)))))
               ;; Check for error
               (let ((err (gethash "error" response)))
                 (when err
                   (error 'protocol-error
                          :code (gethash "code" err)
                          :message (gethash "message" err))))
               (or (gethash "result" response) response)))
        (ignore-errors (close stream))))))

(defmethod transport-notify ((transport http-transport) method &optional params)
  "Send a JSON-RPC notification over HTTP."
  (unless (transport-running-p transport)
    (error 'mcp-error :message "Transport not running"))
  (let ((notification (make-ht "jsonrpc" "2.0" "method" method)))
    (when params
      (setf (gethash "params" notification) params))
    (handler-case
        (dex:post (http-transport-url transport)
                  :headers (request-headers transport)
                  :content (encode-json notification))
      (error (e)
        (log:debug "Notify error: ~a" e))))
  nil)
