;;;; tests/uri-template-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite uri-template-tests
  :description "Tests for URI template compilation and matching"
  :in mcp-lisp-tests)

(in-suite uri-template-tests)

(defun %match (template uri)
  (mcp-lisp/src/primitives/resources/registry::match-uri-template template uri))

;;; --- Simple {var}: matches exactly one path segment, never crosses '/' ---

(test match-single-segment
  "{var} matches a single path segment"
  (is (equal '(("name" . "users")) (%match "api://{name}" "api://users"))))

(test match-single-segment-rejects-slash
  "{var} does not cross '/' (the old greedy behavior was a bug)"
  (is (null (%match "api://{name}" "api://users/123"))))

(test match-multiple-segments
  "multiple {var} split on '/'"
  (is (equal '(("table" . "users") ("id" . "123"))
             (%match "db://{table}/{id}" "db://users/123"))))

(test match-suffix
  "{var} with a literal suffix"
  (is (equal '(("name" . "users")) (%match "api://{name}.json" "api://users.json"))))

(test match-suffix-no-match
  "wrong suffix does not match"
  (is (null (%match "api://{name}.json" "api://users.xml"))))

(test match-middle-param
  "{var} in the middle of literals"
  (is (equal '(("path" . "users"))
             (%match "http://example.com/{path}/info" "http://example.com/users/info"))))

(test match-no-match-prefix
  "wrong scheme/prefix does not match"
  (is (null (%match "file:///{+path}" "http://example.com"))))

;;; --- Reserved {+var}: may span '/' ---

(test match-reserved-crosses-slash
  "{+var} captures across '/'"
  (is (equal '(("path" . "foo/bar.txt"))
             (%match "file:///{+path}" "file:///foo/bar.txt"))))

(test match-reserved-backtracks-to-suffix
  "{+var} backtracks so a trailing literal still matches"
  (is (equal '(("path" . "a/b/c"))
             (%match "files://{+path}/meta" "files://a/b/c/meta"))))

;;; --- Exact templates (no params) ---

(test match-exact-no-params
  "exact template with no params matches (empty alist -> NIL)"
  (is (null (%match "config://server/info" "config://server/info"))))

(test match-exact-no-params-no-match
  "exact template returns NIL when the URI differs"
  (is (null (%match "config://server/info" "config://server/other"))))

;;; --- Percent-decoding of captured values ---

(test match-percent-decodes-value
  "captured values are percent-decoded"
  (is (equal '(("name" . "foo bar")) (%match "api://{name}" "api://foo%20bar"))))

(test match-percent-encoded-slash-stays-in-segment
  "%2F is matched literally by {var} and decoded afterward, not treated as '/'"
  (is (equal '(("name" . "a/b")) (%match "api://{name}" "api://a%2Fb"))))

;;; --- Registration-time validation (fail fast on malformed templates) ---

(test compile-rejects-adjacent-placeholders
  "adjacent placeholders are ambiguous and rejected"
  (signals error
    (mcp-lisp/src/primitives/resources/registry::compile-uri-template "x://{a}{b}")))

(test compile-rejects-unbalanced-brace
  "an unbalanced '{' is rejected"
  (signals error
    (mcp-lisp/src/primitives/resources/registry::compile-uri-template "file://{path")))

(test compile-rejects-unsupported-operator
  "unsupported RFC 6570 operators are rejected"
  (signals error
    (mcp-lisp/src/primitives/resources/registry::compile-uri-template "x://{?query}")))

(test compile-rejects-empty-placeholder
  "an empty placeholder is rejected"
  (signals error
    (mcp-lisp/src/primitives/resources/registry::compile-uri-template "x://{}")))
