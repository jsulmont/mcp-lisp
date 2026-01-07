;;;; run-tests.lisp - Test the mcp-lisp SDK

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push (truename ".") asdf:*central-registry*)
(ql:quickload :mcp-lisp :silent t)

(defpackage #:mcp-tests
  (:use #:cl #:mcp-lisp/main))

(in-package #:mcp-tests)

;;; Define test tools
(define-tool echo ((message string "The message to echo" :required t))
  "Echoes the input message back."
  (format nil "Echo: ~a" message))

(define-tool add ((a integer "First number" :required t)
                  (b integer "Second number" :required t))
  "Adds two numbers."
  (format nil "~a + ~a = ~a" a b (+ a b)))

;;; Test 1: Tool Registry
(format t "~%=== Test 1: Tool Registry ===~%")
(let ((tools (get-all-tools)))
  (format t "Tools registered: ~a~%" (length tools))
  (assert (>= (length tools) 2) nil "Expected at least 2 tools")
  (format t "PASS: Registry has tools~%"))

;;; Test 2: Get specific tool
(format t "~%=== Test 2: Get Tool ===~%")
(let ((echo-tool (get-tool "echo")))
  (assert echo-tool nil "Expected to find echo tool")
  (format t "Found tool: ~a~%" (mcp-lisp/src/primitives/tools/registry:tool-entry-name echo-tool))
  (format t "PASS: Can retrieve tool by name~%"))

;;; Test 3: Server creation
(format t "~%=== Test 3: Server Creation ===~%")
(let ((server (make-server :name "test-server" :version "1.0.0")))
  (assert server nil "Expected server to be created")
  (assert (string= (server-name server) "test-server") nil "Server name mismatch")
  (assert (string= (server-version server) "1.0.0") nil "Server version mismatch")
  (format t "Server created: ~a v~a~%" (server-name server) (server-version server))
  (format t "PASS: Server creation works~%"))

;;; Test 4: JSON utilities
(format t "~%=== Test 4: JSON Utilities ===~%")
(let* ((ht (make-ht "name" "test" "value" 42))
       (json (encode-json ht))
       (parsed (decode-json json)))
  (assert (string= (gethash "name" parsed) "test") nil "JSON roundtrip failed for name")
  (assert (= (gethash "value" parsed) 42) nil "JSON roundtrip failed for value")
  (format t "JSON roundtrip: ~a~%" json)
  (format t "PASS: JSON encode/decode works~%"))

;;; Test 5: Content helpers
(format t "~%=== Test 5: Content Helpers ===~%")
(let ((content (text-content "Hello World")))
  (assert (hash-table-p content) nil "Expected hash-table")
  (assert (string= (gethash "type" content) "text") nil "Expected type=text")
  (assert (string= (gethash "text" content) "Hello World") nil "Text mismatch")
  (format t "Content: ~a~%" (encode-json content))
  (format t "PASS: text-content works~%"))

;;; Test 6: Tool schema generation
(format t "~%=== Test 6: Tool Schema ===~%")
(let* ((echo-entry (get-tool "echo"))
       (schema (mcp-lisp/src/primitives/tools/registry:tool-entry-input-schema echo-entry))
       (props (gethash "properties" schema)))
  (assert (gethash "message" props) nil "Expected message property in schema")
  (format t "Schema properties: ~a~%" (alexandria:hash-table-keys props))
  (format t "PASS: Tool schema generated correctly~%"))

;;; Test 7: Dispatcher - tools/list
(format t "~%=== Test 7: Dispatcher tools/list ===~%")
(let ((result (mcp-lisp/src/server/dispatcher:handle-tools-list-result *global-tool-registry*)))
  (assert (hash-table-p result) nil "Expected hash-table result")
  (let ((tools (gethash "tools" result)))
    (assert tools nil "Expected tools key in result")
    (format t "tools/list returned ~a tools~%" (length tools))
    (format t "PASS: tools/list dispatcher works~%")))

;;; Test 8: Client creation (without connecting)
(format t "~%=== Test 8: Client Creation ===~%")
(let ((client (make-client "echo" "arg1" "arg2")))
  (assert client nil "Expected client to be created")
  (assert (string= (client-name client) "mcp-lisp-client") nil "Client name mismatch")
  (assert (null (client-connected-p client)) nil "Client should not be connected yet")
  (format t "Client created: ~a~%" (client-name client))
  (format t "PASS: Client creation works~%"))

(format t "~%=== All tests passed! ===~%")
