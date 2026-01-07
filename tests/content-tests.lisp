;;;; tests/content-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite content-tests
  :description "Tests for content helpers"
  :in mcp-lisp-tests)

(in-suite content-tests)

(test text-content-basic
  "text-content creates proper content block"
  (let ((content (mcp-lisp:text-content "Hello World")))
    (is (hash-table-p content))
    (is (string= "text" (gethash "type" content)))
    (is (string= "Hello World" (gethash "text" content)))))

(test text-content-empty
  "text-content handles empty string"
  (let ((content (mcp-lisp:text-content "")))
    (is (string= "text" (gethash "type" content)))
    (is (string= "" (gethash "text" content)))))

(test image-content-basic
  "image-content creates proper content block"
  (let ((content (mcp-lisp:image-content "base64data" "image/png")))
    (is (hash-table-p content))
    (is (string= "image" (gethash "type" content)))
    (is (string= "base64data" (gethash "data" content)))
    (is (string= "image/png" (gethash "mimeType" content)))))

(test content-vector-from-string
  "content-vector wraps string in text content vector"
  (let ((cv (mcp-lisp:content-vector "test message")))
    (is (vectorp cv))
    (is (= 1 (length cv)))
    (is (string= "text" (gethash "type" (aref cv 0))))
    (is (string= "test message" (gethash "text" (aref cv 0))))))

(test content-vector-from-hash-table
  "content-vector wraps hash-table in vector"
  (let* ((ht (mcp-lisp:text-content "test"))
         (cv (mcp-lisp:content-vector ht)))
    (is (vectorp cv))
    (is (= 1 (length cv)))
    (is (eq ht (aref cv 0)))))

(test content-vector-multiple
  "content-vector handles multiple content blocks"
  (let ((cv (mcp-lisp:content-vector
             (mcp-lisp:text-content "one")
             (mcp-lisp:text-content "two"))))
    (is (vectorp cv))
    (is (= 2 (length cv)))
    (is (string= "one" (gethash "text" (aref cv 0))))
    (is (string= "two" (gethash "text" (aref cv 1))))))
