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
  (:import-from #:mcp-lisp/src/conditions
                #:invalid-params-error)
  (:export #:define-tool
           #:server
           #:session))

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
Format: (name type description &key required default enum items)"
  (destructuring-bind (name type description &key required default enum items) spec
    (list :name name
          :json-name (symbol-to-json-name name)
          :type type
          :description description
          :required required
          :default default
          :enum enum
          :items items)))

(defun generate-property-form (parsed-spec)
  "Generate code to add a property to the properties hash-table."
  (let ((json-name (getf parsed-spec :json-name))
        (type (getf parsed-spec :type))
        (description (getf parsed-spec :description))
        (enum (getf parsed-spec :enum))
        (items (getf parsed-spec :items)))
    `(let ((schema (make-property-schema ',type
                                         :description ,description
                                         ,@(when enum `(:enum ',enum)))))
       ,@(when items
           `((setf (gethash "items" schema)
                   (make-property-schema ',(first items)
                                         ,@(when (second items)
                                             `(:description ,(second items)))))))
       (setf (gethash ,json-name properties) schema))))

(defun generate-extraction-form (parsed-spec args-var)
  "Generate code to extract an argument from the args hash-table.
Properly distinguishes between missing keys and explicit null values."
  (let ((name (getf parsed-spec :name))
        (json-name (getf parsed-spec :json-name))
        (required (getf parsed-spec :required))
        (default (getf parsed-spec :default)))
    `(,name (multiple-value-bind (val presentp)
                (gethash ,json-name ,args-var)
              (if presentp
                  val  ; Return value even if null
                  ,(if required
                       `(error 'invalid-params-error
                               :message (format nil "Missing required argument: ~a" ,json-name))
                       default))))))

(defun collect-required-args (parsed-specs)
  "Return a list of JSON names for required arguments."
  (loop for spec in parsed-specs
        when (getf spec :required)
          collect (getf spec :json-name)))

(defun parse-annotations (form)
  "Parse an (:annotations ...) form into a hash-table constructor form.
Accepts keyword pairs: :read-only, :destructive, :idempotent, :open-world."
  (let ((pairs (rest form))
        (setfs nil))
    (loop for (key val) on pairs by #'cddr
          do (let ((json-key (ecase key
                               (:read-only "readOnlyHint")
                               (:destructive "destructiveHint")
                               (:idempotent "idempotentHint")
                               (:open-world "openWorldHint"))))
               (push `(setf (gethash ,json-key annotations) ,val) setfs)))
    (when setfs
      `(let ((annotations (make-hash-table :test #'equal)))
         ,@(nreverse setfs)
         annotations))))

(defmacro define-tool (name (&rest args) &body body)
  "Define an MCP tool with automatic schema generation and registration.

NAME is a symbol naming the tool (converted to snake_case for MCP).

ARGS is a list of argument specifications, each of the form:
  (arg-name type \"description\" &key required default)

The first form in BODY may be a docstring describing the tool.
An optional (:annotations ...) form may appear before or after the docstring
to declare tool behavior hints:
  (:annotations :read-only t :destructive nil :idempotent t :open-world nil)

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
  (define-tool get-weather ((location string \"City name\" :required t))
    \"Get current weather for a location\"
    (:annotations :read-only t :open-world t)
    (fetch-weather location))"
  (let* ((parsed-specs (mapcar #'parse-arg-spec args))
         (required-names (collect-required-args parsed-specs))
         (tool-name-string (symbol-to-json-name name))
         ;; Extract docstring, title, annotations, output-schema, and actual body
         (docstring nil)
         (title-form nil)
         (annotations-form nil)
         (output-schema-form nil)
         (remaining body))
    ;; Parse leading declarations in any order
    (loop while remaining
          do (cond
               ((and (null docstring) (stringp (first remaining)))
                (setf docstring (pop remaining)))
               ((and (null title-form)
                     (consp (first remaining))
                     (eq (caar remaining) :title))
                (setf title-form (second (pop remaining))))
               ((and (null annotations-form)
                     (consp (first remaining))
                     (eq (caar remaining) :annotations))
                (setf annotations-form (pop remaining)))
               ((and (null output-schema-form)
                     (consp (first remaining))
                     (eq (caar remaining) :output-schema))
                (setf output-schema-form (second (pop remaining))))
               (t (return))))
    (let ((actual-body remaining)
          (handler-name (intern (format nil "~a-HANDLER" (symbol-name name))))
          (args-ht-sym (gensym "ARGS"))
          (annotations-code (and annotations-form (parse-annotations annotations-form))))
      `(progn
         (defun ,handler-name (server session ,args-ht-sym)
           ,@(when docstring (list docstring))
           (declare (ignorable server session))
           (let (,@(mapcar (lambda (spec)
                             (generate-extraction-form spec args-ht-sym))
                           parsed-specs))
             (let ((result (progn ,@actual-body)))
               (etypecase result
                 (null #())
                 (string (content-vector result))
                 (hash-table (content-vector result))
                 (list (apply #'content-vector result))
                 (vector result)))))

         (let ((properties (make-hash-table :test #'equal)))
           ,@(mapcar #'generate-property-form parsed-specs)
           (register-tool ,tool-name-string
                          ,(or docstring "")
                          (make-input-schema properties ',(coerce required-names 'list))
                          #',handler-name
                          ,@(when title-form `(:title ,title-form))
                          ,@(when output-schema-form `(:output-schema ,output-schema-form))
                          :annotations ,annotations-code))

         ',name))))
