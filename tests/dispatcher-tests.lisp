;;;; tests/dispatcher-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite dispatcher-tests
  :description "Tests for request dispatcher"
  :in mcp-lisp-tests)

(in-suite dispatcher-tests)

(test handle-tools-list-result
  "handle-tools-list-result returns proper structure"
  (let* ((registry (make-hash-table :test #'equal))
         (result (mcp-lisp/src/server/dispatcher:handle-tools-list-result registry)))
    (is (hash-table-p result))
    (is (vectorp (gethash "tools" result)))))

(test handle-tools-list-with-tools
  "handle-tools-list-result includes registered tools"
  (let ((registry (make-hash-table :test #'equal)))
    (mcp-lisp/src/primitives/tools/registry:register-tool
     "test-tool" "Test tool description"
     (mcp-lisp:make-ht) (lambda (s sess args) (declare (ignore s sess args)) "result")
     :registry registry)
    (let* ((result (mcp-lisp/src/server/dispatcher:handle-tools-list-result registry))
           (tools (gethash "tools" result)))
      (is (= 1 (length tools))))))

(test handle-prompts-list-result
  "handle-prompts-list-result returns proper structure"
  (let* ((registry (make-hash-table :test #'equal))
         (result (mcp-lisp/src/server/dispatcher:handle-prompts-list-result registry)))
    (is (hash-table-p result))
    (is (vectorp (gethash "prompts" result)))))

(test handle-resources-list-result
  "handle-resources-list-result returns proper structure"
  (let* ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry))
         (result (mcp-lisp/src/server/dispatcher:handle-resources-list-result registry)))
    (is (hash-table-p result))
    (is (vectorp (gethash "resources" result)))))

(test handle-resources-templates-list-result
  "handle-resources-templates-list-result returns proper structure"
  (let* ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry))
         (result (mcp-lisp/src/server/dispatcher:handle-resources-templates-list-result registry)))
    (is (hash-table-p result))
    (is (vectorp (gethash "resourceTemplates" result)))))

(test handle-tools-call-missing-name
  "handle-tools-call-result signals error for missing name"
  (let ((registry (make-hash-table :test #'equal))
        (session (mcp-lisp/src/server/state:make-session)))
    (signals mcp-lisp/src/conditions:invalid-params-error
      (mcp-lisp/src/server/dispatcher:handle-tools-call-result
       (mcp-lisp:make-ht) nil session registry))))

(test handle-tools-call-not-found
  "handle-tools-call-result signals error for unknown tool"
  (let ((registry (make-hash-table :test #'equal))
        (session (mcp-lisp/src/server/state:make-session))
        (params (mcp-lisp:make-ht "name" "nonexistent")))
    (signals mcp-lisp/src/conditions:method-not-found-error
      (mcp-lisp/src/server/dispatcher:handle-tools-call-result
       params nil session registry))))

(test handle-tools-call-success
  "handle-tools-call-result executes tool successfully"
  (let ((registry (make-hash-table :test #'equal))
        (session (mcp-lisp/src/server/state:make-session)))
    (mcp-lisp/src/primitives/tools/registry:register-tool
     "echo" "Echoes input"
     (mcp-lisp:make-ht)
     (lambda (server session args)
       (declare (ignore server session))
       (mcp-lisp:content-vector (format nil "Echo: ~a" (gethash "message" args))))
     :registry registry)
    (let* ((params (mcp-lisp:make-ht "name" "echo"
                                     "arguments" (mcp-lisp:make-ht "message" "hello")))
           (result (mcp-lisp/src/server/dispatcher:handle-tools-call-result
                    params nil session registry)))
      (is (hash-table-p result))
      (is (vectorp (gethash "content" result))))))

(test handle-tools-call-name-normalization
  "handle-tools-call-result resolves hyphen/namespaced variants to the snake_case key"
  (let ((registry (make-hash-table :test #'equal))
        (session (mcp-lisp/src/server/state:make-session)))
    ;; define-tool registers snake_case keys; mirror that here
    (mcp-lisp/src/primitives/tools/registry:register-tool
     "my_tool" "Tool"
     (mcp-lisp:make-ht)
     (lambda (server session args)
       (declare (ignore server session args))
       (mcp-lisp:content-vector "ok"))
     :registry registry)
    ;; Hyphenated and namespaced variants all normalize to the snake_case key
    (dolist (name '("my-tool" "srv.my_tool" "srv/my-tool"))
      (let* ((params (mcp-lisp:make-ht "name" name "arguments" (mcp-lisp:make-ht)))
             (result (mcp-lisp/src/server/dispatcher:handle-tools-call-result
                      params nil session registry)))
        (is (vectorp (gethash "content" result)))))))

(test handle-prompts-get-missing-name
  "handle-prompts-get-result signals error for missing name"
  (let ((registry (make-hash-table :test #'equal))
        (session (mcp-lisp/src/server/state:make-session)))
    (signals mcp-lisp/src/conditions:invalid-params-error
      (mcp-lisp/src/server/dispatcher:handle-prompts-get-result
       (mcp-lisp:make-ht) nil session registry))))

(test handle-prompts-get-not-found
  "handle-prompts-get-result signals error for unknown prompt"
  (let ((registry (make-hash-table :test #'equal))
        (session (mcp-lisp/src/server/state:make-session))
        (params (mcp-lisp:make-ht "name" "nonexistent")))
    (signals mcp-lisp/src/conditions:method-not-found-error
      (mcp-lisp/src/server/dispatcher:handle-prompts-get-result
       params nil session registry))))

(test handle-resources-read-missing-uri
  "handle-resources-read-result signals error for missing URI"
  (let ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry))
        (session (mcp-lisp/src/server/state:make-session)))
    (signals mcp-lisp/src/conditions:invalid-params-error
      (mcp-lisp/src/server/dispatcher:handle-resources-read-result
       (mcp-lisp:make-ht) nil session registry))))

(test handle-resources-read-not-found
  "handle-resources-read-result signals error for unknown resource"
  (let ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry))
        (session (mcp-lisp/src/server/state:make-session))
        (params (mcp-lisp:make-ht "uri" "unknown://resource")))
    (signals mcp-lisp:protocol-error
      (mcp-lisp/src/server/dispatcher:handle-resources-read-result
       params nil session registry))))

(test handle-resources-read-includes-mime-type
  "handle-resources-read-result includes mimeType when registered"
  (let ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry))
        (session (mcp-lisp/src/server/state:make-session)))
    (mcp-lisp/src/primitives/resources/registry:register-resource
     "test://data" "Test Resource" "A test resource"
     (lambda (server session) (declare (ignore server session)) "test content")
     :mime-type "application/json"
     :registry registry)
    (let* ((params (mcp-lisp:make-ht "uri" "test://data"))
           (result (mcp-lisp/src/server/dispatcher:handle-resources-read-result
                    params nil session registry))
           (contents (gethash "contents" result))
           (first-content (aref contents 0)))
      (is (string= "application/json" (gethash "mimeType" first-content)))
      (is (string= "test://data" (gethash "uri" first-content)))
      (is (string= "test content" (gethash "text" first-content))))))

(test handle-resources-read-template-with-mime-type
  "handle-resources-read-result includes mimeType for template resources"
  (let ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry))
        (session (mcp-lisp/src/server/state:make-session)))
    (mcp-lisp/src/primitives/resources/registry:register-resource-template
     "data://{id}" "Data Resource" "A data resource"
     (lambda (server session params)
       (declare (ignore server session))
       (format nil "data for ~a" (cdr (assoc "id" params :test #'string=))))
     :mime-type "text/plain"
     :registry registry)
    (let* ((params (mcp-lisp:make-ht "uri" "data://123"))
           (result (mcp-lisp/src/server/dispatcher:handle-resources-read-result
                    params nil session registry))
           (contents (gethash "contents" result))
           (first-content (aref contents 0)))
      (is (string= "text/plain" (gethash "mimeType" first-content)))
      (is (string= "data://123" (gethash "uri" first-content)))
      (is (string= "data for 123" (gethash "text" first-content))))))

(test handle-resources-read-without-mime-type
  "handle-resources-read-result omits mimeType when not registered"
  (let ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry))
        (session (mcp-lisp/src/server/state:make-session)))
    (mcp-lisp/src/primitives/resources/registry:register-resource
     "test://plain" "Plain Resource" "A plain resource"
     (lambda (server session) (declare (ignore server session)) "plain content")
     :registry registry)  ; No :mime-type
    (let* ((params (mcp-lisp:make-ht "uri" "test://plain"))
           (result (mcp-lisp/src/server/dispatcher:handle-resources-read-result
                    params nil session registry))
           (contents (gethash "contents" result))
           (first-content (aref contents 0)))
      (is (null (gethash "mimeType" first-content)))
      (is (string= "plain content" (gethash "text" first-content))))))

(test tool-context-progress-and-sampling
  "Tool handlers report progress and sample via the bound tool-context"
  (let ((registry (make-hash-table :test #'equal))
        (notifs nil))
    (mcp-lisp/src/primitives/tools/registry:register-tool
     "ctx_tool" "probe"
     (mcp-lisp:make-ht)
     (lambda (s sess args)
       (declare (ignore s sess args))
       (mcp-lisp:tool-report-progress 50 :total 100 :message "halfway")
       (let ((c (mcp-lisp:tool-sample
                 (list (mcp-lisp:make-sampling-message "user" "hi")) :max-tokens 10)))
         (mcp-lisp/src/content:content-vector
          (format nil "stream=~a sample=~a"
                  (mcp-lisp:tool-streaming-available-p)
                  (gethash "x" c)))))
     :registry registry)
    (let ((mcp-lisp/src/server/tool-context:*stream-notify-fn*
            (lambda (m p) (push (cons m p) notifs)))
          (mcp-lisp/src/server/tool-context:*stream-call-fn*
            (lambda (m p &key timeout)
              (declare (ignore m p timeout))
              (mcp-lisp:make-ht "x" "ok")))
          (session (mcp-lisp/src/server/state:make-session)))
      (let* ((params (mcp-lisp:make-ht
                      "name" "ctx_tool"
                      "arguments" (make-hash-table :test #'equal)
                      "_meta" (mcp-lisp:make-ht "progressToken" "tok-1")))
             (result (mcp-lisp/src/server/dispatcher:handle-tools-call-result
                      params nil session registry))
             (text (gethash "text" (aref (gethash "content" result) 0)))
             (notif (cdr (first notifs))))
        (is (string= "stream=T sample=ok" text))
        (is (= 1 (length notifs)))
        (is (string= "notifications/progress" (car (first notifs))))
        (is (string= "tok-1" (gethash "progressToken" notif)))
        (is (= 50 (gethash "progress" notif)))
        (is (= 100 (gethash "total" notif)))))))

(test tool-context-degrades-without-channel
  "Progress no-ops and sampling signals when no server->client channel is bound"
  (let ((registry (make-hash-table :test #'equal))
        (streaming-seen :unset))
    (mcp-lisp/src/primitives/tools/registry:register-tool
     "ctx_degraded" "probe"
     (mcp-lisp:make-ht)
     (lambda (s sess args)
       (declare (ignore s sess args))
       (mcp-lisp:tool-report-progress 10)          ; must no-op, not error
       (setf streaming-seen (mcp-lisp:tool-streaming-available-p))
       (mcp-lisp:tool-sample (list (mcp-lisp:make-sampling-message "user" "hi"))))
     :registry registry)
    (let ((session (mcp-lisp/src/server/state:make-session)))
      (signals error
        (mcp-lisp/src/server/dispatcher:handle-tools-call-result
         (mcp-lisp:make-ht "name" "ctx_degraded"
                           "arguments" (make-hash-table :test #'equal))
         nil session registry)))
    (is (null streaming-seen))))
