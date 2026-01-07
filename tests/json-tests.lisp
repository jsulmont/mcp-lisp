;;;; tests/json-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite json-tests
  :description "Tests for JSON utilities"
  :in mcp-lisp-tests)

(in-suite json-tests)

(test make-ht-empty
  "make-ht with no args creates empty hash-table"
  (let ((ht (mcp-lisp:make-ht)))
    (is (hash-table-p ht))
    (is (zerop (hash-table-count ht)))))

(test make-ht-with-pairs
  "make-ht creates hash-table with key-value pairs"
  (let ((ht (mcp-lisp:make-ht "name" "test" "value" 42)))
    (is (= 2 (hash-table-count ht)))
    (is (string= "test" (gethash "name" ht)))
    (is (= 42 (gethash "value" ht)))))

(test make-ht-nested
  "make-ht handles nested hash-tables"
  (let ((ht (mcp-lisp:make-ht "outer" (mcp-lisp:make-ht "inner" "value"))))
    (is (hash-table-p (gethash "outer" ht)))
    (is (string= "value" (gethash "inner" (gethash "outer" ht))))))

(test encode-json-simple
  "encode-json handles simple values"
  (is (string= "\"hello\"" (mcp-lisp:encode-json "hello")))
  (is (string= "42" (mcp-lisp:encode-json 42)))
  (is (string= "true" (mcp-lisp:encode-json t)))
  (is (string= "false" (mcp-lisp:encode-json nil))))

(test encode-json-hash-table
  "encode-json handles hash-tables"
  (let* ((ht (mcp-lisp:make-ht "name" "test"))
         (json (mcp-lisp:encode-json ht)))
    (is (stringp json))
    (is (search "\"name\"" json))
    (is (search "\"test\"" json))))

(test decode-json-simple
  "decode-json parses simple JSON"
  (is (string= "hello" (mcp-lisp:decode-json "\"hello\"")))
  (is (= 42 (mcp-lisp:decode-json "42")))
  (is (eq t (mcp-lisp:decode-json "true")))
  (is (eq 'null (mcp-lisp:decode-json "null"))))

(test decode-json-object
  "decode-json parses JSON objects to hash-tables"
  (let ((ht (mcp-lisp:decode-json "{\"name\":\"test\",\"value\":42}")))
    (is (hash-table-p ht))
    (is (string= "test" (gethash "name" ht)))
    (is (= 42 (gethash "value" ht)))))

(test json-roundtrip
  "JSON encode/decode roundtrip preserves data"
  (let* ((original (mcp-lisp:make-ht "name" "test" "count" 123))
         (json (mcp-lisp:encode-json original))
         (decoded (mcp-lisp:decode-json json)))
    (is (string= (gethash "name" original) (gethash "name" decoded)))
    (is (= (gethash "count" original) (gethash "count" decoded)))))
