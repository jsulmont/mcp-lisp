;;;; src/transport/mcp-sse.lisp
;;;;
;;;; MCP SSE (Server-Sent Events) transport over HTTP.

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
                #:mcp-error-message)
  (:export #:start-sse-server
           #:stop-sse-server
           #:*sse-server*))

(in-package #:mcp-lisp/src/transport/mcp-sse)

(defvar *sse-server* nil "Current Hunchentoot acceptor.")
(defvar *handlers* nil "Hash-table of method handlers.")
(defvar *sse-clients* nil "List of active SSE client streams.")
(defvar *sse-clients-lock* (bt:make-lock "sse-clients"))

(defun make-json-rpc-response (id result)
  "Create a JSON-RPC success response."
  (make-ht "jsonrpc" "2.0" "id" id "result" result))

(defun make-json-rpc-error (id code message &optional data)
  "Create a JSON-RPC error response."
  (let ((err (make-ht "code" code "message" message)))
    (when data
      (setf (gethash "data" err) data))
    (make-ht "jsonrpc" "2.0" "id" id "error" err)))

(defun write-utf8 (string stream)
  "Write STRING to binary STREAM as UTF-8 bytes."
  (write-sequence (flexi-streams:string-to-octets string :external-format :utf-8) stream))

(defun send-sse-event (stream data &optional event-type)
  "Send an SSE event to a stream."
  (when event-type
    (write-utf8 (format nil "event: ~a~%" event-type) stream))
  (write-utf8 (format nil "data: ~a~%~%" data) stream)
  (force-output stream))

(defun broadcast-sse (data &optional event-type)
  "Send SSE event to all connected clients."
  (bt:with-lock-held (*sse-clients-lock*)
    (setf *sse-clients*
          (loop for client in *sse-clients*
                when (open-stream-p client)
                collect client
                and do (ignore-errors
                         (send-sse-event client data event-type))))))

(defun handle-json-rpc-request (request-json)
  "Process a JSON-RPC request and return response JSON."
  (handler-case
      (let* ((request (decode-json request-json))
             (id (gethash "id" request))
             (method (gethash "method" request))
             (params (gethash "params" request))
             (handler (gethash method *handlers*)))
        (log:debug "Request: method=~a id=~a" method id)
        (cond
          ;; Notification (no id)
          ((null id)
           (log:debug "Notification: ~a" method)
           (when handler
             (ignore-errors (funcall handler params)))
           nil)
          ;; Request with handler
          (handler
           (handler-case
               (let ((result (funcall handler params)))
                 (log:debug "Response: id=~a success" id)
                 (encode-json (make-json-rpc-response id result)))
             (protocol-error (e)
               (log:error "Protocol error: ~a" e)
               (encode-json (make-json-rpc-error id
                                                 (protocol-error-code e)
                                                 (mcp-error-message e))))
             (error (e)
               (log:error "Handler error: ~a" e)
               (encode-json (make-json-rpc-error id -32603 (princ-to-string e))))))
          ;; Unknown method
          (t
           (log:warn "Unknown method: ~a" method)
           (encode-json (make-json-rpc-error id -32601
                                             (format nil "Method not found: ~a" method))))))
    (error (e)
      (log:error "Parse error: ~a" e)
      (encode-json (make-json-rpc-error nil -32700 "Parse error")))))

(defun sse-handler ()
  "Handle GET /sse - establish SSE connection."
  (log:info "SSE client connected")
  (setf (hunchentoot:content-type*) "text/event-stream")
  (setf (hunchentoot:header-out "Cache-Control") "no-cache")
  (setf (hunchentoot:header-out "Connection") "keep-alive")
  (setf (hunchentoot:header-out "Access-Control-Allow-Origin") "*")

  (let ((stream (hunchentoot:send-headers)))
    (bt:with-lock-held (*sse-clients-lock*)
      (push stream *sse-clients*))
    ;; Send initial endpoint event (MCP protocol requirement)
    (send-sse-event stream "/message" "endpoint")
    ;; Keep connection alive
    (loop
      (unless (open-stream-p stream)
        (log:info "SSE client disconnected")
        (return))
      (sleep 30)
      ;; Send keepalive comment
      (ignore-errors
        (write-utf8 (format nil ": keepalive~%~%") stream)
        (force-output stream)))))

(defun message-handler ()
  "Handle POST /message - receive JSON-RPC requests."
  (setf (hunchentoot:content-type*) "application/json")
  (setf (hunchentoot:header-out "Access-Control-Allow-Origin") "*")

  (let* ((body (hunchentoot:raw-post-data :force-text t))
         (response (handle-json-rpc-request body)))
    (when response
      ;; Also broadcast via SSE
      (broadcast-sse response "message"))
    (or response "")))

(defun options-handler ()
  "Handle CORS preflight requests."
  (setf (hunchentoot:header-out "Access-Control-Allow-Origin") "*")
  (setf (hunchentoot:header-out "Access-Control-Allow-Methods") "GET, POST, OPTIONS")
  (setf (hunchentoot:header-out "Access-Control-Allow-Headers") "Content-Type")
  "")

(defclass mcp-acceptor (hunchentoot:acceptor)
  ()
  (:documentation "Custom acceptor for MCP SSE server."))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor mcp-acceptor) request)
  (let ((path (hunchentoot:script-name request))
        (method (hunchentoot:request-method request)))
    (log:debug "HTTP ~a ~a" method path)
    (cond
      ((eq method :options)
       (options-handler))
      ((and (eq method :get) (string= path "/sse"))
       (sse-handler))
      ((and (eq method :post) (string= path "/message"))
       (message-handler))
      (t
       (setf (hunchentoot:return-code*) 404)
       "Not Found"))))

(defun start-sse-server (handlers &key (port 8080))
  "Start MCP SSE server on PORT with HANDLERS hash-table."
  (when *sse-server*
    (stop-sse-server))
  (setf *handlers* handlers)
  (setf *sse-clients* nil)
  (setf *sse-server* (make-instance 'mcp-acceptor :port port))
  (hunchentoot:start *sse-server*)
  (log:info "MCP SSE server started on port ~a" port)
  (format t "~&MCP SSE server running on http://localhost:~a/sse~%" port)
  *sse-server*)

(defun stop-sse-server ()
  "Stop the MCP SSE server."
  (when *sse-server*
    (hunchentoot:stop *sse-server*)
    (setf *sse-server* nil)
    (setf *sse-clients* nil)
    (log:info "MCP SSE server stopped")))
