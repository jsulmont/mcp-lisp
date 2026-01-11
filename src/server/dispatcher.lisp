;;;; src/server/dispatcher.lisp
;;;;
;;;; Request dispatching for MCP server.

(defpackage #:mcp-lisp/src/server/dispatcher
  (:use #:cl)
  (:import-from #:mcp-lisp/src/core
                #:protocol-version>=)
  (:import-from #:mcp-lisp/src/json
                #:make-ht
                #:encode-json)
  (:import-from #:mcp-lisp/src/content
                #:text-content)
  (:import-from #:mcp-lisp/src/conditions
                #:invalid-params-error
                #:method-not-found-error
                #:internal-error
                #:protocol-error)
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

(defun normalize-tool-name (name)
  "Normalize a tool name (handle namespacing, case)."
  (let* ((s (string-downcase name))
         (dot (position #\. s :from-end t))
         (slash (position #\/ s :from-end t))
         (idx (max (or dot -1) (or slash -1))))
    (substitute #\_ #\- (subseq s (1+ idx)))))

(defun handle-tools-list-result (registry)
  "Return tools/list result payload."
  (make-ht "tools" (get-all-tool-descriptors registry)))

(defun handle-tools-call-result (params server session registry)
  "Return tools/call result payload. Signals error on failure."
  (let* ((name (and params (gethash "name" params)))
         (args (and params (gethash "arguments" params)))
         (normalized (and name (normalize-tool-name name)))
         (handler (or (and name (get-tool-handler name registry))
                      (and normalized (get-tool-handler normalized registry)))))
    (cond
      ((null name)
       (error 'invalid-params-error :message "Missing tool name"))
      ((null handler)
       (error 'method-not-found-error
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
                 (error 'internal-error
                        :message (format nil "Tool error: ~a" e))))))))))

;;; Prompts

(defun handle-prompts-list-result (registry)
  "Return prompts/list result payload."
  (make-ht "prompts" (get-all-prompt-descriptors registry)))

(defun handle-prompts-get-result (params server session registry)
  "Return prompts/get result payload. Signals error on failure."
  (let* ((name (and params (gethash "name" params)))
         (args (and params (gethash "arguments" params)))
         (handler (and name (get-prompt-handler name registry))))
    (cond
      ((null name)
       (error 'invalid-params-error :message "Missing prompt name"))
      ((null handler)
       (error 'method-not-found-error
              :message (format nil "Prompt not found: ~a" name)))
      (t
       (handler-case
           (let ((messages (funcall handler server session (or args (make-hash-table)))))
             (make-ht "messages" (coerce messages 'vector)))
         (error (e)
           (error 'internal-error
                  :message (format nil "Prompt error: ~a" e))))))))

;;; Resources

(defun handle-resources-list-result (registry)
  "Return resources/list result payload."
  (make-ht "resources" (get-all-resource-descriptors registry)))

(defun handle-resources-templates-list-result (registry)
  "Return resources/templates/list result payload."
  (make-ht "resourceTemplates" (get-all-template-descriptors registry)))

(defun handle-resources-read-result (params server session registry)
  "Return resources/read result payload. Signals error on failure."
  (let ((uri (and params (gethash "uri" params))))
    (cond
      ((null uri)
       (error 'invalid-params-error :message "Missing resource URI"))
      (t
       (multiple-value-bind (handler template-params)
           (get-resource-handler uri registry)
         (cond
           ((null handler)
            (error 'protocol-error
                   :code -32002
                   :message (format nil "Resource not found: ~a" uri)))
           (t
            (handler-case
                (let ((content (if template-params
                                   (funcall handler server session template-params)
                                   (funcall handler server session))))
                  (let ((text (if (stringp content)
                                  content
                                  (encode-json content))))
                    (make-ht "contents"
                             (vector (make-ht "uri" uri "text" text)))))
              (error (e)
                (error 'internal-error
                       :message (format nil "Resource error: ~a" e)))))))))))
