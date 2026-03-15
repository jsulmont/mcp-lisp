;;;; src/transport/mcp-http-client.lisp
;;;;
;;;; MCP client transport over Streamable HTTP.
;;;; Implements the same interface as mcp-client (stdio transport).

(defpackage #:mcp-lisp/src/transport/mcp-http-client
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:encode-json
                #:decode-json
                #:make-ht)
  (:import-from #:mcp-lisp/src/conditions
                #:mcp-error
                #:protocol-error)
  (:import-from #:dexador)
  (:export #:http-transport
           #:make-http-transport
           #:http-transport-start
           #:http-transport-stop
           #:http-transport-call
           #:http-transport-notify
           #:http-transport-running-p
           #:http-transport-notification-handler
           #:http-transport-session-id))

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
   (running :initform nil
            :accessor http-transport-running-p)
   (notification-handler :initform nil
                         :accessor http-transport-notification-handler
                         :documentation "Function (method params) for server notifications."))
  (:documentation "MCP client transport over Streamable HTTP."))

(defun make-http-transport (url)
  "Create a new HTTP transport for the given MCP server URL."
  (make-instance 'http-transport :url url))

(defun http-transport-start (transport)
  "Mark transport as running."
  (setf (http-transport-running-p transport) t)
  transport)

(defun http-transport-stop (transport)
  "Stop the transport."
  ;; Send DELETE to terminate session if we have one
  (when (http-transport-session-id transport)
    (handler-case
        (dex:delete (http-transport-url transport)
                    :headers (request-headers transport))
      (error () nil)))
  (setf (http-transport-running-p transport) nil
        (http-transport-session-id transport) nil)
  transport)

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
  "Parse a text/event-stream body into a list of (event-type . data) pairs.
Each SSE event is separated by a blank line."
  (let ((events nil)
        (current-event nil)
        (current-data nil))
    (dolist (line (split-lines body))
      (cond
        ((and (= 0 (length line)) current-data)
         ;; Blank line = event boundary
         (push (cons current-event (format nil "~{~a~^~%~}" (nreverse current-data))) events)
         (setf current-event nil current-data nil))
        ((starts-with-p "event: " line)
         (setf current-event (subseq line 7)))
        ((starts-with-p "data: " line)
         (push (subseq line 6) current-data))
        ((starts-with-p "data:" line)
         (push (subseq line 5) current-data))))
    ;; Handle trailing event without final blank line
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
                    ;; Strip trailing CR
                    (if (and (plusp (length line)) (char= (char line (1- (length line))) #\Return))
                        (subseq line 0 (1- (length line)))
                        line)))
        do (if pos (setf start (1+ pos)) (loop-finish))))

(defun starts-with-p (prefix string)
  (and (>= (length string) (length prefix))
       (string= prefix string :end2 (length prefix))))

;;; Request/response

(defun dispatch-sse-response (transport events)
  "Process SSE events. Dispatch notifications, return the JSON-RPC response."
  (let ((response nil))
    (dolist (event events)
      (let ((data (cdr event)))
        (when (plusp (length data))
          (handler-case
              (let* ((parsed (decode-json data))
                     (id (gethash "id" parsed))
                     (method (gethash "method" parsed)))
                (cond
                  ;; Server notification (has method, no id)
                  ((and method (null id))
                   (when (http-transport-notification-handler transport)
                     (handler-case
                         (funcall (http-transport-notification-handler transport)
                                  method (gethash "params" parsed))
                       (error (e) (log:warn "Notification handler error: ~a" e)))))
                  ;; Server request (has method and id) — for now just log it
                  ((and method id)
                   (log:debug "Server request received (unhandled): ~a" method))
                  ;; Response (has id, no method)
                  (id
                   (setf response parsed))))
            (error () nil)))))
    response))

(defun http-transport-call (transport method params &key (timeout 30))
  "Make a JSON-RPC call over HTTP. Returns the result or signals an error."
  (unless (http-transport-running-p transport)
    (error 'mcp-error :message "Transport not running"))
  (let* ((id (incf (http-transport-next-id transport)))
         (request (make-ht "jsonrpc" "2.0" "id" id "method" method))
         (is-init (string= method "initialize")))
    (when params
      (setf (gethash "params" request) params))
    (multiple-value-bind (body status headers)
        (dex:post (http-transport-url transport)
                  :headers (request-headers transport)
                  :content (encode-json request)
                  :read-timeout timeout
                  :connect-timeout timeout)
      (unless (= status 200)
        (error 'mcp-error :message (format nil "HTTP ~a: ~a" status body)))
      ;; Capture session ID from initialize response
      (when is-init
        (let ((sid (gethash "mcp-session-id" headers)))
          (when sid
            (setf (http-transport-session-id transport) sid))))
      ;; Parse response based on content-type
      (let ((ct (or (gethash "content-type" headers) "")))
        (let ((response
                (cond
                  ((search "text/event-stream" ct)
                   (dispatch-sse-response transport (parse-sse-events body)))
                  ((search "application/json" ct)
                   (decode-json body))
                  (t
                   (decode-json body)))))
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
          (or (gethash "result" response) response))))))

(defun http-transport-notify (transport method &optional params)
  "Send a JSON-RPC notification over HTTP. Expects 202 Accepted."
  (unless (http-transport-running-p transport)
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
