;;;; src/server/dispatcher.lisp
;;;;
;;;; Request dispatching for MCP server.

(defpackage #:mcp-lisp/src/server/dispatcher
  (:use #:cl)
  (:import-from #:jsonrpc)
  (:import-from #:mcp-lisp/src/core
                #:protocol-version>=)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/content
                #:text-content)
  (:import-from #:mcp-lisp/src/server/state
                #:session-protocol-version)
  (:import-from #:mcp-lisp/src/primitives/tools/registry
                #:get-tool-handler
                #:get-all-tool-descriptors)
  (:import-from #:mcp-lisp/src/primitives/prompts/registry
                #:get-prompt-handler
                #:get-all-prompt-descriptors)
  (:import-from #:mcp-lisp/src/primitives/resources/registry
                #:get-resource-handler
                #:get-all-resource-descriptors
                #:get-all-template-descriptors)
  (:export #:handle-tools-list-result
           #:handle-tools-call-result
           #:handle-prompts-list-result
           #:handle-prompts-get-result
           #:handle-resources-list-result
           #:handle-resources-read-result
           #:handle-resources-templates-list-result))

(in-package #:mcp-lisp/src/server/dispatcher)

(defun make-result (id payload)
  "Create a JSON-RPC success response."
  (make-ht "jsonrpc" "2.0" "id" id "result" payload))

(defun make-error-response (id code message &optional data)
  "Create a JSON-RPC error response."
  (let ((err (make-ht "code" code "message" message)))
    (when data
      (setf (gethash "data" err) data))
    (make-ht "jsonrpc" "2.0" "id" id "error" err)))

(defun make-tool-error (id message &optional session)
  "Create a tool execution error response.
For protocol >= 2025-11-25, uses isError flag.
For older protocols, uses JSON-RPC error."
  (let ((version (and session (session-protocol-version session))))
    (if (protocol-version>= version "2025-11-25")
        (make-result id (make-ht "content" (vector (text-content message))
                                 "isError" t))
        (make-error-response id -32602 message))))

(defun normalize-tool-name (name)
  "Normalize a tool name (handle namespacing, case)."
  (let* ((s (string-downcase name))
         (dot (position #\. s :from-end t))
         (slash (position #\/ s :from-end t))
         (idx (max (or dot -1) (or slash -1))))
    (substitute #\- #\_ (subseq s (1+ idx)))))

(defun handle-tools-list-result (registry)
  "Return tools/list result payload."
  (make-ht "tools" (get-all-tool-descriptors registry)))

(defun handle-tools-call-result (params server session registry)
  "Return tools/call result payload. Signals jsonrpc error on failure."
  (let* ((name (and params (gethash "name" params)))
         (args (and params (gethash "arguments" params)))
         (normalized (and name (normalize-tool-name name)))
         (handler (and normalized (get-tool-handler normalized registry))))
    (cond
      ((null name)
       (error 'jsonrpc:jsonrpc-invalid-params :message "Missing tool name"))
      ((null handler)
       (error 'jsonrpc:jsonrpc-method-not-found
              :message (format nil "Tool not found: ~a" name)))
      (t
       (handler-case
           (let ((content (funcall handler server session (or args (make-hash-table)))))
             (make-ht "content" content))
         (error (e)
           (let ((version (session-protocol-version session)))
             (if (protocol-version>= version "2025-11-25")
                 (make-ht "content" (vector (text-content (format nil "Tool error: ~a" e)))
                          "isError" t)
                 (error 'jsonrpc:jsonrpc-internal-error
                        :message (format nil "Tool error: ~a" e))))))))))

;;; Prompts

(defun handle-prompts-list-result (registry)
  "Return prompts/list result payload."
  (make-ht "prompts" (get-all-prompt-descriptors registry)))

(defun handle-prompts-get-result (params server session registry)
  "Return prompts/get result payload. Signals jsonrpc error on failure."
  (let* ((name (and params (gethash "name" params)))
         (args (and params (gethash "arguments" params)))
         (handler (and name (get-prompt-handler name registry))))
    (cond
      ((null name)
       (error 'jsonrpc:jsonrpc-invalid-params :message "Missing prompt name"))
      ((null handler)
       (error 'jsonrpc:jsonrpc-method-not-found
              :message (format nil "Prompt not found: ~a" name)))
      (t
       (handler-case
           (let ((messages (funcall handler server session (or args (make-hash-table)))))
             (make-ht "messages" (coerce messages 'vector)))
         (error (e)
           (error 'jsonrpc:jsonrpc-internal-error
                  :message (format nil "Prompt error: ~a" e))))))))

;;; Resources

(defun handle-resources-list-result (registry)
  "Return resources/list result payload."
  (make-ht "resources" (get-all-resource-descriptors registry)))

(defun handle-resources-templates-list-result (registry)
  "Return resources/templates/list result payload."
  (make-ht "resourceTemplates" (get-all-template-descriptors registry)))

(defun handle-resources-read-result (params server session registry)
  "Return resources/read result payload. Signals jsonrpc error on failure."
  (let ((uri (and params (gethash "uri" params))))
    (cond
      ((null uri)
       (error 'jsonrpc:jsonrpc-invalid-params :message "Missing resource URI"))
      (t
       (multiple-value-bind (handler template-params)
           (get-resource-handler uri registry)
         (cond
           ((null handler)
            (error 'jsonrpc:jsonrpc-error
                   :code -32002
                   :message (format nil "Resource not found: ~a" uri)))
           (t
            (handler-case
                (let ((content (if template-params
                                   (funcall handler server session template-params)
                                   (funcall handler server session))))
                  (let ((text (if (stringp content)
                                  content
                                  (mcp-lisp/src/json:encode-json content))))
                    (make-ht "contents"
                             (vector (make-ht "uri" uri "text" text)))))
              (error (e)
                (error 'jsonrpc:jsonrpc-internal-error
                       :message (format nil "Resource error: ~a" e)))))))))))
