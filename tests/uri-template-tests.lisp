;;;; tests/uri-template-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite uri-template-tests
  :description "Tests for URI template parsing and matching"
  :in mcp-lisp-tests)

(in-suite uri-template-tests)

(test parse-uri-template-simple
  "parse-uri-template handles single parameter"
  (multiple-value-bind (literals params)
      (mcp-lisp/src/primitives/resources/registry::parse-uri-template "file:///{path}")
    (is (equal '("file:///" "") literals))
    (is (equal '("path") params))))

(test parse-uri-template-multiple
  "parse-uri-template handles multiple parameters"
  (multiple-value-bind (literals params)
      (mcp-lisp/src/primitives/resources/registry::parse-uri-template "db://{table}/{id}")
    (is (equal '("db://" "/" "") literals))
    (is (equal '("table" "id") params))))

(test parse-uri-template-no-params
  "parse-uri-template handles templates with no parameters"
  (multiple-value-bind (literals params)
      (mcp-lisp/src/primitives/resources/registry::parse-uri-template "config://static")
    (is (equal '("config://static") literals))
    (is (null params))))

(test parse-uri-template-adjacent
  "parse-uri-template handles adjacent parameters"
  (multiple-value-bind (literals params)
      (mcp-lisp/src/primitives/resources/registry::parse-uri-template "{scheme}://{host}")
    (is (equal '("" "://" "") literals))
    (is (equal '("scheme" "host") params))))

(test match-uri-template-simple
  "match-uri-template extracts single parameter"
  (let ((result (mcp-lisp/src/primitives/resources/registry::match-uri-template
                 "file:///{path}" "file:///foo/bar.txt")))
    (is (equal '(("path" . "foo/bar.txt")) result))))

(test match-uri-template-multiple
  "match-uri-template extracts multiple parameters"
  (let ((result (mcp-lisp/src/primitives/resources/registry::match-uri-template
                 "db://{table}/{id}" "db://users/123")))
    (is (equal '(("table" . "users") ("id" . "123")) result))))

(test match-uri-template-no-match-prefix
  "match-uri-template returns nil for wrong prefix"
  (let ((result (mcp-lisp/src/primitives/resources/registry::match-uri-template
                 "file:///{path}" "http://example.com")))
    (is (null result))))

(test match-uri-template-no-match-suffix
  "match-uri-template returns nil for wrong suffix"
  (let ((result (mcp-lisp/src/primitives/resources/registry::match-uri-template
                 "api://{endpoint}.json" "api://users.xml")))
    (is (null result))))

(test match-uri-template-exact
  "match-uri-template handles exact match with no params"
  (let ((result (mcp-lisp/src/primitives/resources/registry::match-uri-template
                 "config://server/info" "config://server/info")))
    (is (null result))))

(test match-uri-template-exact-no-match
  "match-uri-template returns nil for non-matching exact template"
  (let ((result (mcp-lisp/src/primitives/resources/registry::match-uri-template
                 "config://server/info" "config://server/other")))
    (is (null result))))

(test match-uri-template-with-suffix
  "match-uri-template handles templates with suffix after param"
  (let ((result (mcp-lisp/src/primitives/resources/registry::match-uri-template
                 "api://{name}.json" "api://users.json")))
    (is (equal '(("name" . "users")) result))))

(test match-uri-template-middle-param
  "match-uri-template handles parameter in middle"
  (let ((result (mcp-lisp/src/primitives/resources/registry::match-uri-template
                 "http://example.com/{path}/info" "http://example.com/users/info")))
    (is (equal '(("path" . "users")) result))))
