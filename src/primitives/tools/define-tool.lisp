;;;; src/primitives/tools/define-tool.lisp
;;;;
;;;; Macro for defining MCP tools with minimal boilerplate.

(defpackage #:mcp-lisp/src/primitives/tools/define-tool
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/content
                #:text-content
                #:content-vector)
  (:import-from #:mcp-lisp/src/primitives/tools/registry
                #:register-tool)
  (:import-from #:mcp-lisp/src/primitives/tools/schema
                #:type-to-json-type
                #:make-property-schema
                #:make-input-schema)
  (:export #:define-tool))

(in-package #:mcp-lisp/src/primitives/tools/define-tool)

;;; Argument spec format: (name type "description" &key required default)
;;; Example: (message string "The message to echo" :required t)

(defun kebab-to-snake (string)
  "Convert kebab-case STRING to snake_case."
  (substitute #\_ #\- string))

(defun symbol-to-json-name (sym)
  "Convert symbol SYM to a snake_case JSON key string."
  (kebab-to-snake (string-downcase (symbol-name sym))))

(defun parse-arg-spec (spec)
  "Parse an argument specification into a normalized plist.
Format: (name type description &key required default)"
  (destructuring-bind (name type description &key (required nil) (default nil)) spec
    (list :name name
          :json-name (symbol-to-json-name name)
          :type type
          :description description
          :required required
          :default default)))

(defun generate-property-form (parsed-spec)
  "Generate code to add a property to the properties hash-table."
  (let ((json-name (getf parsed-spec :json-name))
        (type (getf parsed-spec :type))
        (description (getf parsed-spec :description)))
    `(setf (gethash ,json-name properties)
           (make-property-schema ',type :description ,description))))

(defun generate-extraction-form (parsed-spec args-var)
  "Generate code to extract an argument from the args hash-table."
  (let ((name (getf parsed-spec :name))
        (json-name (getf parsed-spec :json-name))
        (required (getf parsed-spec :required))
        (default (getf parsed-spec :default)))
    `(,name (let ((val (gethash ,json-name ,args-var)))
              (if (null val)
                  ,(if required
                       `(error "Missing required argument: ~a" ,json-name)
                       default)
                  val)))))

(defun collect-required-args (parsed-specs)
  "Return a list of JSON names for required arguments."
  (loop for spec in parsed-specs
        when (getf spec :required)
          collect (getf spec :json-name)))

(defmacro define-tool (name (&rest args) &body body)
  "Define an MCP tool with automatic schema generation and registration.

NAME is a symbol naming the tool (converted to snake_case for MCP).

ARGS is a list of argument specifications, each of the form:
  (arg-name type \"description\" &key required default)

The first form in BODY may be a docstring describing the tool.

The handler body has access to:
  - Each argument name as a lexical variable
  - SERVER - the current server instance
  - SESSION - the current session
  - ARGS-HT - the raw arguments hash-table

The body should return either:
  - A string (wrapped in text content automatically)
  - A content block hash-table
  - A vector of content blocks

Example:
  (define-tool echo ((message string \"The message to echo\" :required t))
    \"Echoes the input message back\"
    (format nil \"Echo: ~a\" message))"
  (let* ((parsed-specs (mapcar #'parse-arg-spec args))
         (required-names (collect-required-args parsed-specs))
         (tool-name-string (symbol-to-json-name name))
         (docstring (if (stringp (first body)) (first body) nil))
         (actual-body (if docstring (rest body) body))
         (handler-name (intern (format nil "~a-HANDLER" (symbol-name name))))
         (args-ht-sym (gensym "ARGS")))
    `(progn
       (defun ,handler-name (server session ,args-ht-sym)
         ,@(when docstring (list docstring))
         (declare (ignorable server session))
         (let (,@(mapcar (lambda (spec)
                           (generate-extraction-form spec args-ht-sym))
                         parsed-specs))
           (let ((result (progn ,@actual-body)))
             (etypecase result
               (string (content-vector result))
               (hash-table (content-vector result))
               (vector result)))))

       (let ((properties (make-hash-table :test #'equal)))
         ,@(mapcar #'generate-property-form parsed-specs)
         (register-tool ,tool-name-string
                        ,(or docstring "")
                        (make-input-schema properties ',(coerce required-names 'list))
                        #',handler-name))

       ',name)))
