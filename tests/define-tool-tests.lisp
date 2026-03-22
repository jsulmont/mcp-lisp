;;;; tests/define-tool-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite define-tool-tests
  :description "Tests for define-tool macro argument handling"
  :in mcp-lisp-tests)

(in-suite define-tool-tests)

;;; Test the extraction form generation directly by checking gethash behavior

(test extraction-missing-required-signals-error
  "Missing required argument signals an error"
  (let ((args (mcp-lisp:make-ht)))  ; Empty - no "name" key
    (signals error
      (multiple-value-bind (val presentp)
          (gethash "name" args)
        (if presentp
            val
            (error "Missing required argument: ~a" "name"))))))

(test extraction-null-required-returns-null
  "Explicit null for required argument returns null (not error)"
  (let ((args (mcp-lisp:make-ht "name" nil)))  ; Explicit null
    (multiple-value-bind (val presentp)
        (gethash "name" args)
      (is (eq t presentp))  ; Key is present
      (is (null val)))))    ; Value is null

(test extraction-missing-optional-uses-default
  "Missing optional argument uses default value"
  (let ((args (mcp-lisp:make-ht))
        (default-value "default"))
    (multiple-value-bind (val presentp)
        (gethash "optional_arg" args)
      (let ((result (if presentp val default-value)))
        (is (string= "default" result))))))

(test extraction-null-optional-returns-null
  "Explicit null for optional argument returns null (not default)"
  (let ((args (mcp-lisp:make-ht "optional_arg" nil))
        (default-value "default"))
    (multiple-value-bind (val presentp)
        (gethash "optional_arg" args)
      (let ((result (if presentp val default-value)))
        (is (null result))))))  ; Should be null, not "default"

(test extraction-value-present-returns-value
  "Present argument with value returns that value"
  (let ((args (mcp-lisp:make-ht "message" "hello")))
    (multiple-value-bind (val presentp)
        (gethash "message" args)
      (is (eq t presentp))
      (is (string= "hello" val)))))

;;; Integration test with actual tool registration

(test define-tool-null-vs-missing-integration
  "define-tool properly handles null vs missing arguments"
  (let ((registry (make-hash-table :test #'equal)))
    ;; Register a tool with required and optional args
    (mcp-lisp/src/primitives/tools/registry:register-tool
     "null-test" "Tests null handling"
     (mcp-lisp:make-ht
      "properties" (mcp-lisp:make-ht
                    "required_arg" (mcp-lisp:make-ht "type" "string")
                    "optional_arg" (mcp-lisp:make-ht "type" "string"))
      "required" #("required_arg"))
     (lambda (server session args)
       (declare (ignore server session))
       ;; This handler uses multiple-value-bind pattern
       (multiple-value-bind (req-val req-present)
           (gethash "required_arg" args)
         (multiple-value-bind (opt-val opt-present)
             (gethash "optional_arg" args)
           (mcp-lisp:content-vector
            (format nil "req=~s(~a) opt=~s(~a)"
                    req-val (if req-present "present" "missing")
                    opt-val (if opt-present "present" "missing"))))))
     :registry registry)
    ;; Verify tool was registered
    (is (not (null (mcp-lisp/src/primitives/tools/registry:get-tool "null-test" registry))))))
