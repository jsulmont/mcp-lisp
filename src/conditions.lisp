;;;; src/conditions.lisp
;;;;
;;;; Error conditions for mcp-lisp.

(defpackage #:mcp-lisp/src/conditions
  (:use #:cl)
  (:export #:mcp-error
           #:mcp-error-message
           #:protocol-error
           #:protocol-error-code
           #:tool-error
           #:tool-error-tool-name
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
         :reader protocol-error-code))
  (:report (lambda (c s)
             (format s "MCP Protocol Error ~a: ~a"
                     (protocol-error-code c)
                     (mcp-error-message c))))
  (:documentation "JSON-RPC protocol level error."))

(define-condition tool-error (mcp-error)
  ((tool-name :initarg :tool-name
              :initform nil
              :reader tool-error-tool-name))
  (:report (lambda (c s)
             (format s "Tool Error~@[ (~a)~]: ~a"
                     (tool-error-tool-name c)
                     (mcp-error-message c))))
  (:documentation "Error during tool execution."))

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
