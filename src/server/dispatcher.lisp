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
                #:protocol-error
                #:tool-error
                #:tool-error-category
                #:tool-error-retryable-p)
  (:import-from #:mcp-lisp/src/server/state
                #:session-protocol-version)
  (:import-from #:mcp-lisp/src/primitives/tools/registry
                #:get-tool
                #:get-tool-handler
                #:get-all-tool-descriptors
                #:tool-entry-output-schema)
  (:import-from #:mcp-lisp/src/primitives/prompts/registry
                #:get-prompt-handler
                #:get-all-prompt-descriptors)
  (:import-from #:mcp-lisp/src/primitives/resources/registry
                #:get-resource
                #:find-matching-template
                #:resource-entry-handler
                #:resource-entry-mime-type
                #:resource-template-entry-handler
                #:resource-template-entry-mime-type
                #:get-all-resource-descriptors
                #:get-all-template-descriptors)
  (:export #:*request-meta*
           #:handle-tools-list-result
           #:handle-tools-call-result
           #:handle-prompts-list-result
           #:handle-prompts-get-result
           #:handle-resources-list-result
           #:handle-resources-read-result
           #:handle-resources-templates-list-result))

(in-package #:mcp-lisp/src/server/dispatcher)

(defvar *request-meta* nil
  "Bound to the _meta object from the current tools/call request params.
Contains progressToken and other request metadata.")

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

(defun format-tool-error (e)
  "Format a tool-error into an actionable error string with category/retryable metadata."
  (let ((category (tool-error-category e))
        (retryable (tool-error-retryable-p e))
        (msg (mcp-lisp/src/conditions:mcp-error-message e)))
    (if category
        (format nil "~a~%errorCategory: ~a~%isRetryable: ~a"
                msg
                (string-downcase (symbol-name category))
                (if retryable "true" "false"))
        msg)))

(defun handle-tools-call-result (params server session registry)
  "Return tools/call result payload. Signals error on failure."
  (let* ((name (and params (gethash "name" params)))
         (args (and params (gethash "arguments" params)))
         (normalized (and name (normalize-tool-name name)))
         (tool-entry (or (and name (get-tool name registry))
                         (and normalized (get-tool normalized registry))))
         (handler (and tool-entry (mcp-lisp/src/primitives/tools/registry:tool-entry-handler tool-entry))))
    (cond
      ((null name)
       (error 'invalid-params-error :message "Missing tool name"))
      ((null handler)
       (error 'method-not-found-error
              :message (format nil "Tool not found: ~a" name)))
      (t
       (handler-case
           (let* ((*request-meta* (and params (gethash "_meta" params)))
                  (content (funcall handler server session (or args (make-hash-table))))
                  (result (make-ht "content" content)))
             ;; If tool has outputSchema, check for structured content.
             ;; Content-vector wraps hash-tables as JSON text, so we parse it back.
             (when (and (tool-entry-output-schema tool-entry)
                        (= 1 (length content)))
               (let* ((block (aref content 0))
                      (text (and (hash-table-p block) (gethash "text" block))))
                 (when text
                   (handler-case
                       (let ((parsed (mcp-lisp/src/json:decode-json text)))
                         (when (hash-table-p parsed)
                           (setf (gethash "structuredContent" result) parsed)))
                     (error () nil)))))
             result)
         (tool-error (e)
           (let ((version (session-protocol-version session)))
             (if (protocol-version>= version "2025-11-25")
                 (make-ht "content" (vector (text-content (format-tool-error e)))
                          "isError" t)
                 (error 'internal-error
                        :message (format-tool-error e)))))
         ;; Protocol errors (bad params, etc.) are JSON-RPC errors, not tool
         ;; results — re-signal so the transport reports the proper code.
         (protocol-error (e)
           (error e))
         (error (e)
           (let ((version (session-protocol-version session)))
             (if (protocol-version>= version "2025-11-25")
                 (make-ht "content" (vector (text-content (princ-to-string e)))
                          "isError" t)
                 (error 'internal-error
                        :message (princ-to-string e))))))))))

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
         (protocol-error (e)
           (error e))
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

(defun format-resource-result (uri content mime-type)
  "Build a resources/read response from URI, raw CONTENT, and optional MIME-TYPE."
  (let ((entry (make-ht "uri" uri)))
    (cond
      ((stringp content)
       (setf (gethash "text" entry) content))
      ((and (hash-table-p content) (gethash "blob" content))
       (setf (gethash "blob" entry) (gethash "blob" content)))
      (t
       (setf (gethash "text" entry) (encode-json content))))
    (when mime-type
      (setf (gethash "mimeType" entry) mime-type))
    (make-ht "contents" (vector entry))))

(defun handle-resources-read-result (params server session registry)
  "Return resources/read result payload. Signals error on failure."
  (let ((uri (and params (gethash "uri" params))))
    (unless uri
      (error 'invalid-params-error :message "Missing resource URI"))
    (let ((static-entry (get-resource uri registry)))
      (if static-entry
          (handler-case
              (format-resource-result
               uri
               (funcall (resource-entry-handler static-entry) server session)
               (resource-entry-mime-type static-entry))
            (protocol-error (e)
              (error e))
            (error (e)
              (error 'internal-error
                     :message (format nil "Resource error: ~a" e))))
          ;; Try template match
          (multiple-value-bind (template-entry template-params)
              (find-matching-template uri registry)
            (unless template-entry
              (error 'protocol-error
                     :code -32002
                     :message (format nil "Resource not found: ~a" uri)))
            (handler-case
                (format-resource-result
                 uri
                 (funcall (resource-template-entry-handler template-entry)
                          server session template-params)
                 (resource-template-entry-mime-type template-entry))
              (error (e)
                (error 'internal-error
                       :message (format nil "Resource error: ~a" e)))))))))
