;;;; src/transport/mcp-stdio.lisp
;;;;
;;;; MCP stdio transport using newline-delimited JSON.

(defpackage #:mcp-lisp/src/transport/mcp-stdio
  (:use #:cl #:log4cl)
  (:import-from #:mcp-lisp/src/json
                #:encode-json
                #:decode-json
                #:make-ht)
  (:import-from #:mcp-lisp/src/conditions
                #:protocol-error
                #:protocol-error-code
                #:mcp-error-message)
  (:export #:run-mcp-server
           #:mcp-server-loop
           #:setup-file-logging))

(in-package #:mcp-lisp/src/transport/mcp-stdio)

(defun setup-file-logging (path &key (level :debug))
  "Configure log4cl to write to a file. Call before starting server.
LEVEL can be :debug, :info, :warn, :error (default :debug)."
  (log:config :daily path :backup nil)
  (log:config :sane2)
  (log:config level))

(defun read-json-line (stream)
  "Read a line and parse as JSON. Returns NIL on EOF."
  (let ((line (read-line stream nil nil)))
    (when (and line (> (length line) 0))
      (decode-json line))))

(defun write-json-line (object stream)
  "Write object as JSON followed by newline."
  (write-string (encode-json object) stream)
  (terpri stream)
  (force-output stream))

(defun make-response (id result)
  "Create a JSON-RPC success response."
  (make-ht "jsonrpc" "2.0" "id" id "result" result))

(defun make-error-response (id code message &optional data)
  "Create a JSON-RPC error response."
  (let ((err (make-ht "code" code "message" message)))
    (when data
      (setf (gethash "data" err) data))
    (make-ht "jsonrpc" "2.0" "id" id "error" err)))

(defun mcp-server-loop (handlers &key (input *standard-input*) (output *standard-output*))
  "Run MCP server loop with HANDLERS hash-table mapping method names to functions.
Each handler receives (params) and should return the result or signal an error."
  (log:info "MCP server starting")
  (loop
    (let ((request (read-json-line input)))
      (unless request
        (log:info "EOF received, shutting down")
        (return))
      (let* ((id (gethash "id" request))
             (method (gethash "method" request))
             (params (gethash "params" request))
             (handler (gethash method handlers)))
        (log:debug "Request: method=~a id=~a" method id)
        (cond
          ;; Notification (no id) - just call handler, no response
          ((null id)
           (log:debug "Notification: ~a" method)
           (when handler
             (handler-case (funcall handler params)
               (error (e)
                 (log:error "Notification handler error (~a): ~a" method e)))))
          ;; Request with handler
          (handler
           (handler-case
               (let ((result (funcall handler params)))
                 (log:debug "Response: id=~a success" id)
                 (write-json-line (make-response id result) output))
             (protocol-error (e)
               (log:error "Protocol error: ~a" e)
               (write-json-line (make-error-response id
                                                     (protocol-error-code e)
                                                     (mcp-error-message e))
                                output))
             (error (e)
               (log:error "Handler error: ~a" e)
               (write-json-line (make-error-response id -32603 (princ-to-string e)) output))))
          ;; Unknown method
          (t
           (log:warn "Unknown method: ~a" method)
           (write-json-line (make-error-response id -32601 (format nil "Method not found: ~a" method)) output)))))))

(defun run-mcp-server (setup-fn &key (input *standard-input*) (output *standard-output*))
  "Run an MCP server. SETUP-FN receives a handlers hash-table to populate.
Example:
  (run-mcp-server
    (lambda (handlers)
      (setf (gethash \"initialize\" handlers) #'handle-initialize)
      (setf (gethash \"tools/list\" handlers) #'handle-tools-list)))"
  (let ((handlers (make-hash-table :test #'equal)))
    (funcall setup-fn handlers)
    (mcp-server-loop handlers :input input :output output)))
