;;;; tests/schema-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite schema-tests
  :description "Tests for JSON Schema generation"
  :in mcp-lisp-tests)

(in-suite schema-tests)

(test type-to-json-type-string
  "type-to-json-type maps string correctly"
  (is (string= "string"
               (mcp-lisp/src/primitives/tools/schema:type-to-json-type 'string))))

(test type-to-json-type-integer
  "type-to-json-type maps integer correctly"
  (is (string= "integer"
               (mcp-lisp/src/primitives/tools/schema:type-to-json-type 'integer))))

(test type-to-json-type-number
  "type-to-json-type maps number correctly"
  (is (string= "number"
               (mcp-lisp/src/primitives/tools/schema:type-to-json-type 'number))))

(test type-to-json-type-boolean
  "type-to-json-type maps boolean correctly"
  (is (string= "boolean"
               (mcp-lisp/src/primitives/tools/schema:type-to-json-type 'boolean))))

(test type-to-json-type-array
  "type-to-json-type maps array/list correctly"
  (is (string= "array"
               (mcp-lisp/src/primitives/tools/schema:type-to-json-type 'array)))
  (is (string= "array"
               (mcp-lisp/src/primitives/tools/schema:type-to-json-type 'list))))

(test type-to-json-type-object
  "type-to-json-type maps object/hash-table correctly"
  (is (string= "object"
               (mcp-lisp/src/primitives/tools/schema:type-to-json-type 'object)))
  (is (string= "object"
               (mcp-lisp/src/primitives/tools/schema:type-to-json-type 'hash-table))))

(test type-to-json-type-unknown
  "type-to-json-type defaults to string for unknown types"
  (is (string= "string"
               (mcp-lisp/src/primitives/tools/schema:type-to-json-type 'unknown-type))))

(test make-property-schema-basic
  "make-property-schema creates basic schema"
  (let ((schema (mcp-lisp/src/primitives/tools/schema:make-property-schema 'string)))
    (is (hash-table-p schema))
    (is (string= "string" (gethash "type" schema)))))

(test make-property-schema-with-description
  "make-property-schema includes description"
  (let ((schema (mcp-lisp/src/primitives/tools/schema:make-property-schema
                 'string :description "A test property")))
    (is (string= "A test property" (gethash "description" schema)))))

(test make-property-schema-with-enum
  "make-property-schema includes enum values"
  (let ((schema (mcp-lisp/src/primitives/tools/schema:make-property-schema
                 'string :enum '("one" "two" "three"))))
    (let ((enum (gethash "enum" schema)))
      (is (vectorp enum))
      (is (= 3 (length enum))))))

(test make-input-schema-basic
  "make-input-schema creates complete schema"
  (let* ((props (mcp-lisp:make-ht
                 "name" (mcp-lisp/src/primitives/tools/schema:make-property-schema 'string)
                 "count" (mcp-lisp/src/primitives/tools/schema:make-property-schema 'integer)))
         (schema (mcp-lisp/src/primitives/tools/schema:make-input-schema props '("name"))))
    (is (string= "object" (gethash "type" schema)))
    (is (hash-table-p (gethash "properties" schema)))
    (let ((required (gethash "required" schema)))
      (is (vectorp required))
      (is (= 1 (length required)))
      (is (string= "name" (aref required 0))))))

(test make-input-schema-no-required
  "make-input-schema handles no required fields"
  (let* ((props (mcp-lisp:make-ht
                 "optional" (mcp-lisp/src/primitives/tools/schema:make-property-schema 'string)))
         (schema (mcp-lisp/src/primitives/tools/schema:make-input-schema props nil)))
    (is (null (gethash "required" schema)))))
