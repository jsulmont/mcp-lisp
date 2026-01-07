;;;; src/client/operations.lisp
;;;;
;;;; High-level MCP client operations.

(defpackage #:mcp-lisp/src/client/operations
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/client/client
                #:mcp-client
                #:client-call
                #:client-initialized-p)
  (:import-from #:mcp-lisp/src/conditions
                #:mcp-error)
  (:export #:list-tools
           #:call-tool
           #:list-resources
           #:read-resource
           #:list-prompts
           #:get-prompt
           #:ping))

(in-package #:mcp-lisp/src/client/operations)

(defun ensure-initialized (client)
  "Signal an error if CLIENT is not initialized."
  (unless (client-initialized-p client)
    (error 'mcp-error :message "Client not initialized")))

;;; Tools

(defun list-tools (client)
  "List available tools from the server.
Returns a list of tool descriptors."
  (ensure-initialized client)
  (let ((result (client-call client "tools/list" nil)))
    (coerce (gethash "tools" result) 'list)))

(defun call-tool (client name &rest args)
  "Call a tool on the server.
NAME is the tool name string.
ARGS are keyword arguments passed to the tool.
Returns the content from the tool response."
  (ensure-initialized client)
  (let* ((arguments (make-hash-table :test #'equal)))
    ;; Convert keyword args to hash-table
    (loop for (key value) on args by #'cddr
          do (setf (gethash (string-downcase (symbol-name key)) arguments) value))
    (let* ((params (make-ht "name" name "arguments" arguments))
           (result (client-call client "tools/call" params)))
      (values (gethash "content" result)
              (gethash "isError" result)))))

;;; Resources

(defun list-resources (client)
  "List available resources from the server.
Returns a list of resource descriptors."
  (ensure-initialized client)
  (let ((result (client-call client "resources/list" nil)))
    (coerce (gethash "resources" result) 'list)))

(defun read-resource (client uri)
  "Read a resource from the server.
URI is the resource URI string.
Returns the resource contents."
  (ensure-initialized client)
  (let* ((params (make-ht "uri" uri))
         (result (client-call client "resources/read" params)))
    (gethash "contents" result)))

;;; Prompts

(defun list-prompts (client)
  "List available prompts from the server.
Returns a list of prompt descriptors."
  (ensure-initialized client)
  (let ((result (client-call client "prompts/list" nil)))
    (coerce (gethash "prompts" result) 'list)))

(defun get-prompt (client name &rest args)
  "Get a prompt from the server.
NAME is the prompt name string.
ARGS are keyword arguments for the prompt.
Returns the prompt messages."
  (ensure-initialized client)
  (let* ((arguments (make-hash-table :test #'equal)))
    (loop for (key value) on args by #'cddr
          do (setf (gethash (string-downcase (symbol-name key)) arguments) value))
    (let* ((params (make-ht "name" name "arguments" arguments))
           (result (client-call client "prompts/get" params)))
      (gethash "messages" result))))

;;; Utility

(defun ping (client)
  "Ping the server. Returns T on success."
  (ensure-initialized client)
  (client-call client "ping" nil)
  t)
