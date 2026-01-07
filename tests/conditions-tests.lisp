;;;; tests/conditions-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite conditions-tests
  :description "Tests for error conditions"
  :in mcp-lisp-tests)

(in-suite conditions-tests)

(test mcp-error-basic
  "mcp-error can be created and signaled"
  (signals mcp-lisp:mcp-error
    (error 'mcp-lisp:mcp-error :message "Test error")))

(test mcp-error-message
  "mcp-error has accessible message"
  (handler-case
      (error 'mcp-lisp:mcp-error :message "Test message")
    (mcp-lisp:mcp-error (e)
      (is (string= "Test message"
                   (mcp-lisp/src/conditions:mcp-error-message e))))))

(test protocol-error-code
  "protocol-error has error code"
  (handler-case
      (error 'mcp-lisp:protocol-error :code -32600 :message "Invalid request")
    (mcp-lisp:protocol-error (e)
      (is (= -32600 (mcp-lisp/src/conditions:protocol-error-code e))))))

(test protocol-error-inheritance
  "protocol-error is a subtype of mcp-error"
  (signals mcp-lisp:mcp-error
    (error 'mcp-lisp:protocol-error :code -32600 :message "Test")))

(test invalid-params-error-code
  "invalid-params-error has correct default code"
  (handler-case
      (error 'mcp-lisp/src/conditions:invalid-params-error :message "Bad params")
    (mcp-lisp:protocol-error (e)
      (is (= -32602 (mcp-lisp/src/conditions:protocol-error-code e))))))

(test method-not-found-error-code
  "method-not-found-error has correct default code"
  (handler-case
      (error 'mcp-lisp/src/conditions:method-not-found-error :message "Not found")
    (mcp-lisp:protocol-error (e)
      (is (= -32601 (mcp-lisp/src/conditions:protocol-error-code e))))))

(test internal-error-code
  "internal-error has correct default code"
  (handler-case
      (error 'mcp-lisp/src/conditions:internal-error :message "Internal")
    (mcp-lisp:protocol-error (e)
      (is (= -32603 (mcp-lisp/src/conditions:protocol-error-code e))))))

(test tool-error-name
  "tool-error includes tool name"
  (handler-case
      (error 'mcp-lisp:tool-error :tool-name "my-tool" :message "Failed")
    (mcp-lisp:tool-error (e)
      (is (string= "my-tool"
                   (mcp-lisp/src/conditions:tool-error-tool-name e))))))
