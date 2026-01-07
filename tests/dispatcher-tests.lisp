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
     (mcp-lisp:make-ht) (lambda (s sess args) "result")
     registry)
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
       (mcp-lisp:content-vector (format nil "Echo: ~a" (gethash "message" args))))
     registry)
    (let* ((params (mcp-lisp:make-ht "name" "echo"
                                     "arguments" (mcp-lisp:make-ht "message" "hello")))
           (result (mcp-lisp/src/server/dispatcher:handle-tools-call-result
                    params nil session registry)))
      (is (hash-table-p result))
      (is (vectorp (gethash "content" result))))))

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
