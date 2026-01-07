;;;; src/primitives/tools/schema.lisp
;;;;
;;;; JSON Schema generation for tool input schemas.

(defpackage #:mcp-lisp/src/primitives/tools/schema
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:export #:type-to-json-type
           #:make-property-schema
           #:make-input-schema))

(in-package #:mcp-lisp/src/primitives/tools/schema)

(defun type-to-json-type (type)
  "Convert a Lisp type specifier to JSON Schema type string."
  (etypecase type
    (symbol
     (case type
       (string "string")
       (integer "integer")
       (number "number")
       (boolean "boolean")
       ((array list) "array")
       ((object hash-table) "object")
       (t "string")))))

(defun make-property-schema (type &key description enum)
  "Create a JSON Schema property definition."
  (let ((ht (make-ht "type" (type-to-json-type type))))
    (when description
      (setf (gethash "description" ht) description))
    (when enum
      (setf (gethash "enum" ht) (coerce enum 'vector)))
    ht))

(defun make-input-schema (properties required-list)
  "Create a complete inputSchema object.
PROPERTIES is a hash-table of property-name -> property-schema.
REQUIRED-LIST is a list of required property names."
  (let ((ht (make-ht "type" "object"
                     "properties" properties)))
    (when required-list
      (setf (gethash "required" ht)
            (coerce required-list 'vector)))
    ht))
