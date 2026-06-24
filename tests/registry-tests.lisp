;;;; tests/registry-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite registry-tests
  :description "Tests for tool, prompt, and resource registries"
  :in mcp-lisp-tests)

(in-suite registry-tests)

;;; Tool Registry Tests

(test tool-registry-register
  "register-tool adds tool to registry"
  (let ((registry (make-hash-table :test #'equal)))
    (mcp-lisp/src/primitives/tools/registry:register-tool
     "test-tool" "A test tool"
     (mcp-lisp:make-ht) (lambda (s sess args) (declare (ignore s sess args)) "result")
     :registry registry)
    (is (mcp-lisp/src/primitives/tools/registry:get-tool "test-tool" registry))))

(test tool-registry-unregister
  "unregister-tool removes tool from registry"
  (let ((registry (make-hash-table :test #'equal)))
    (mcp-lisp/src/primitives/tools/registry:register-tool
     "temp-tool" "Temporary tool"
     (mcp-lisp:make-ht) (lambda (s sess args) (declare (ignore s sess args)) nil)
     :registry registry)
    (is (mcp-lisp/src/primitives/tools/registry:get-tool "temp-tool" registry))
    (mcp-lisp/src/primitives/tools/registry:unregister-tool "temp-tool" registry)
    (is (null (mcp-lisp/src/primitives/tools/registry:get-tool "temp-tool" registry)))))

(test tool-registry-get-handler
  "get-tool-handler returns the handler function"
  (let* ((registry (make-hash-table :test #'equal))
         (handler (lambda (s sess args) (declare (ignore s sess args)) "handler-result")))
    (mcp-lisp/src/primitives/tools/registry:register-tool
     "handler-tool" "Test handler tool"
     (mcp-lisp:make-ht) handler
     :registry registry)
    (is (eq handler
            (mcp-lisp/src/primitives/tools/registry:get-tool-handler
             "handler-tool" registry)))))

(test tool-registry-descriptors
  "get-all-tool-descriptors returns vector of descriptors"
  (let ((registry (make-hash-table :test #'equal)))
    (mcp-lisp/src/primitives/tools/registry:register-tool
     "tool1" "First tool"
     (mcp-lisp:make-ht) (lambda (s sess args) (declare (ignore s sess args)) nil)
     :registry registry)
    (mcp-lisp/src/primitives/tools/registry:register-tool
     "tool2" "Second tool"
     (mcp-lisp:make-ht) (lambda (s sess args) (declare (ignore s sess args)) nil)
     :registry registry)
    (let ((descriptors (mcp-lisp/src/primitives/tools/registry:get-all-tool-descriptors registry)))
      (is (vectorp descriptors))
      (is (= 2 (length descriptors))))))

;;; Resource Registry Tests

(test resource-registry-static
  "register-resource adds static resource"
  (let ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry)))
    (mcp-lisp/src/primitives/resources/registry:register-resource
     "config://app/settings" "Settings" "App settings"
     (lambda (s sess) (declare (ignore s sess)) "settings-data")
     :registry registry)
    (is (mcp-lisp/src/primitives/resources/registry:get-resource
         "config://app/settings" registry))))

(test resource-registry-template
  "register-resource-template adds template resource"
  (let ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry)))
    (mcp-lisp/src/primitives/resources/registry:register-resource-template
     "file:///{path}" "Files" "Local files"
     (lambda (s sess params) (declare (ignore s sess)) (cdr (assoc "path" params :test #'string=)))
     :registry registry)
    (let ((templates (mcp-lisp/src/primitives/resources/registry:get-all-resource-templates registry)))
      (is (= 1 (length templates))))))

(test resource-registry-handler-static
  "get-resource-handler finds static resource handler"
  (let ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry)))
    (mcp-lisp/src/primitives/resources/registry:register-resource
     "test://static" "Static" "Static resource"
     (lambda (s sess) (declare (ignore s sess)) "static-result")
     :registry registry)
    (multiple-value-bind (handler params)
        (mcp-lisp/src/primitives/resources/registry:get-resource-handler
         "test://static" registry)
      (is (functionp handler))
      (is (null params)))))

(test resource-registry-handler-template
  "get-resource-handler matches template and extracts params"
  (let ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry)))
    (mcp-lisp/src/primitives/resources/registry:register-resource-template
     "db://{table}/{id}" "Database" "DB records"
     (lambda (s sess params) (declare (ignore s sess)) params)
     :registry registry)
    (multiple-value-bind (handler params)
        (mcp-lisp/src/primitives/resources/registry:get-resource-handler
         "db://users/123" registry)
      (is (functionp handler))
      (is (equal '(("table" . "users") ("id" . "123")) params)))))

(test find-matching-template-prefers-more-specific
  "When two templates match, the more specific (more literal) one wins"
  (let ((registry (mcp-lisp/src/primitives/resources/registry:make-resource-registry)))
    (mcp-lisp/src/primitives/resources/registry:register-resource-template
     "db://{a}/{b}" "General" "" (lambda (s sess p) (declare (ignore s sess p)) :general)
     :registry registry)
    (mcp-lisp/src/primitives/resources/registry:register-resource-template
     "db://users/{b}" "Specific" "" (lambda (s sess p) (declare (ignore s sess p)) :specific)
     :registry registry)
    (multiple-value-bind (entry params)
        (mcp-lisp/src/primitives/resources/registry:find-matching-template
         "db://users/42" registry)
      (is (string= "db://users/{b}"
                   (mcp-lisp/src/primitives/resources/registry:resource-template-entry-uri-template
                    entry)))
      (is (equal '(("b" . "42")) params)))))

;;; Prompt Registry Tests

(test prompt-registry-register
  "register-prompt adds prompt to registry"
  (let ((registry (make-hash-table :test #'equal)))
    (mcp-lisp/src/primitives/prompts/registry:register-prompt
     "test-prompt" "A test prompt"
     nil (lambda (s sess args) (declare (ignore s sess args)) (list (mcp-lisp:make-ht "role" "user")))
     registry)
    (is (mcp-lisp/src/primitives/prompts/registry:get-prompt "test-prompt" registry))))

(test prompt-registry-handler
  "get-prompt-handler returns handler function"
  (let* ((registry (make-hash-table :test #'equal))
         (handler (lambda (s sess args) (declare (ignore s sess args)) (list "message"))))
    (mcp-lisp/src/primitives/prompts/registry:register-prompt
     "handler-prompt" "Test prompt handler"
     nil handler
     registry)
    (is (eq handler
            (mcp-lisp/src/primitives/prompts/registry:get-prompt-handler
             "handler-prompt" registry)))))
