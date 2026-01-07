;;;; src/primitives/prompts/define-prompt.lisp
;;;;
;;;; Macro for defining MCP prompts declaratively.

(defpackage #:mcp-lisp/src/primitives/prompts/define-prompt
  (:use #:cl)
  (:import-from #:mcp-lisp/src/primitives/prompts/registry
                #:register-prompt
                #:*global-prompt-registry*)
  (:export #:define-prompt))

(in-package #:mcp-lisp/src/primitives/prompts/define-prompt)

(defun parse-prompt-arg (arg-spec)
  "Parse a prompt argument specification.
Format: (name type description &key required)
Returns (values name type description required)."
  (destructuring-bind (name type description &key (required nil)) arg-spec
    (values name type description required)))

(defun make-argument-descriptor (name type description required)
  "Create an MCP argument descriptor hash-table."
  (declare (ignore type))
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "name" ht) (string-downcase (symbol-name name)))
    (setf (gethash "description" ht) description)
    (when required
      (setf (gethash "required" ht) t))
    ht))

(defun generate-prompt-handler (name args body)
  "Generate the handler function for a prompt.
The handler receives (server session arguments) and returns a list of messages."
  (let ((handler-name (intern (format nil "~a-PROMPT-HANDLER" name)))
        (arg-names (mapcar #'car args)))
    `(defun ,handler-name (server session arguments)
       (declare (ignorable server session))
       (let ,(mapcar (lambda (arg-name)
                       `(,arg-name (gethash ,(string-downcase (symbol-name arg-name))
                                            arguments)))
                     arg-names)
         ,@body))))

(defmacro define-prompt (name (&rest args) &body body)
  "Define an MCP prompt.

NAME is the prompt name (symbol).
ARGS is a list of argument specs: (name type description &key required)
BODY should return a list of message hash-tables.

Example:
  (define-prompt code-review ((code string \"Code to review\" :required t))
    \"Review code for issues\"
    (list (make-ht \"role\" \"user\"
                   \"content\" (make-ht \"type\" \"text\"
                                       \"text\" (format nil \"Review: ~a\" code)))))

The first string in BODY is the description."
  (let* ((description (if (stringp (car body)) (car body) ""))
         (actual-body (if (stringp (car body)) (cdr body) body))
         (handler-name (intern (format nil "~a-PROMPT-HANDLER" name)))
         (prompt-name (string-downcase (symbol-name name)))
         (arg-descriptors (mapcar (lambda (arg-spec)
                                    (multiple-value-bind (n typ desc req)
                                        (parse-prompt-arg arg-spec)
                                      (make-argument-descriptor n typ desc req)))
                                  args)))
    `(progn
       ,(generate-prompt-handler name args actual-body)
       (register-prompt ,prompt-name
                        ,description
                        (list ,@(mapcar (lambda (desc)
                                          `(let ((ht (make-hash-table :test #'equal)))
                                             ,@(loop for key being the hash-keys of desc
                                                       using (hash-value val)
                                                     collect `(setf (gethash ,key ht) ,val))
                                             ht))
                                        arg-descriptors))
                        #',handler-name
                        *global-prompt-registry*)
       ',name)))
