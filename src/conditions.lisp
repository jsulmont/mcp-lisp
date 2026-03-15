;;;; src/conditions.lisp
;;;;
;;;; Error conditions for mcp-lisp.

(defpackage #:mcp-lisp/src/conditions
  (:use #:cl)
  (:export #:mcp-error
           #:mcp-error-message
           #:protocol-error
           #:protocol-error-code
           #:protocol-error-data
           #:invalid-params-error
           #:method-not-found-error
           #:internal-error
           #:tool-error
           #:tool-error-tool-name
           #:tool-error-category
           #:tool-error-retryable-p
           #:transport-error
           #:validation-error
           #:validation-error-field))

(in-package #:mcp-lisp/src/conditions)

(define-condition mcp-error (error)
  ((message :initarg :message
            :initform "MCP error"
            :reader mcp-error-message))
  (:report (lambda (c s)
             (format s "MCP Error: ~a" (mcp-error-message c))))
  (:documentation "Base condition for all MCP errors."))

(define-condition protocol-error (mcp-error)
  ((code :initarg :code
         :initform -32600
         :reader protocol-error-code)
   (data :initarg :data
         :initform nil
         :reader protocol-error-data))
  (:report (lambda (c s)
             (format s "MCP Protocol Error ~a: ~a"
                     (protocol-error-code c)
                     (mcp-error-message c))))
  (:documentation "JSON-RPC protocol level error."))

(define-condition invalid-params-error (protocol-error)
  ((code :initform -32602))
  (:documentation "Invalid method parameters."))

(define-condition method-not-found-error (protocol-error)
  ((code :initform -32601))
  (:documentation "Method not found."))

(define-condition internal-error (protocol-error)
  ((code :initform -32603))
  (:documentation "Internal JSON-RPC error."))

(define-condition tool-error (mcp-error)
  ((tool-name :initarg :tool-name
              :initform nil
              :reader tool-error-tool-name)
   (category :initarg :category
             :initform nil
             :reader tool-error-category
             :documentation "Error category: :transient, :validation, :permission, or :business")
   (retryable-p :initarg :retryable
                :initform nil
                :reader tool-error-retryable-p))
  (:report (lambda (c s)
             (format s "Tool Error~@[ (~a)~]~@[ [~a]~]: ~a"
                     (tool-error-tool-name c)
                     (tool-error-category c)
                     (mcp-error-message c))))
  (:documentation "Error during tool execution.
CATEGORY classifies the error for recovery decisions:
  :transient   - Temporary failure, retry may succeed (timeouts, rate limits)
  :validation  - Bad input, don't retry with same args
  :permission  - Access denied, don't retry
  :business    - Policy violation (e.g., refund exceeds limit)"))

(define-condition transport-error (mcp-error)
  ()
  (:documentation "Transport layer error."))

(define-condition validation-error (mcp-error)
  ((field :initarg :field
          :initform nil
          :reader validation-error-field))
  (:report (lambda (c s)
             (format s "Validation Error~@[ (field: ~a)~]: ~a"
                     (validation-error-field c)
                     (mcp-error-message c))))
  (:documentation "Input validation error."))
