;;;; tests/client-transport-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite client-transport-tests
  :description "Tests for MCP client transport"
  :in mcp-lisp-tests)

(in-suite client-transport-tests)

;;; Test notification handler slot

(test transport-notification-handler-default-nil
  "Transport notification handler defaults to NIL"
  (let ((transport (mcp-lisp/src/transport/mcp-client:make-stdio-transport
                    '("echo"))))
    (is (null (mcp-lisp/src/transport/protocol:transport-notification-handler
               transport)))))

(test transport-notification-handler-settable
  "Transport notification handler can be set"
  (let ((transport (mcp-lisp/src/transport/mcp-client:make-stdio-transport
                    '("echo")))
        (handler (lambda (method params)
                   (declare (ignore method params)))))
    (setf (mcp-lisp/src/transport/protocol:transport-notification-handler transport)
          handler)
    (is (eq handler
            (mcp-lisp/src/transport/protocol:transport-notification-handler
             transport)))))

;;; Test notification dispatch in reader loop
;;; These tests verify the structure; full integration requires a real server

(test notification-has-method-no-id
  "Server notifications have method but no id"
  ;; Verify the structure we expect to receive
  (let ((notification (mcp-lisp:make-ht
                       "jsonrpc" "2.0"
                       "method" "notifications/progress"
                       "params" (mcp-lisp:make-ht "progress" 50))))
    (is (null (gethash "id" notification)))
    (is (string= "notifications/progress" (gethash "method" notification)))
    (is (hash-table-p (gethash "params" notification)))))

(test response-has-id-no-method
  "Server responses have id but no method"
  ;; Verify the structure we expect for responses
  (let ((response (mcp-lisp:make-ht
                   "jsonrpc" "2.0"
                   "id" 1
                   "result" (mcp-lisp:make-ht "success" t))))
    (is (= 1 (gethash "id" response)))
    (is (null (gethash "method" response)))))

;;; Test client-level notification handler

(test client-notification-handler-before-connect
  "client-notification-handler returns NIL before connect"
  (let ((client (mcp-lisp:make-client "echo")))
    (is (null (mcp-lisp:client-notification-handler client)))))

(test client-notification-handler-set-requires-connection
  "Setting client-notification-handler requires connection"
  (let ((client (mcp-lisp:make-client "echo")))
    (signals mcp-lisp:mcp-error
      (setf (mcp-lisp:client-notification-handler client)
            (lambda (m p) (declare (ignore m p)))))))

;;; Test HTTP transport request handler

(test http-transport-request-handler-default-nil
  "HTTP transport request handler defaults to NIL"
  (let ((transport (mcp-lisp/src/transport/mcp-http-client:make-http-transport
                    "http://localhost:9999/mcp")))
    (is (null (mcp-lisp/src/transport/mcp-http-client:http-transport-request-handler
               transport)))))

(test http-transport-request-handler-invoked
  "dispatch-sse-response invokes request handler for server requests"
  (let* ((captured-method nil)
         (captured-params nil)
         (transport (mcp-lisp/src/transport/mcp-http-client:make-http-transport
                     "http://localhost:9999/mcp")))
    (setf (mcp-lisp/src/transport/mcp-http-client:http-transport-request-handler transport)
          (lambda (method params)
            (setf captured-method method
                  captured-params params)
            ;; Return a result — the POST-back will fail (no server), but handler is called
            (mcp-lisp:make-ht "model" "test" "content" "hello")))
    ;; Construct SSE events: a server request followed by the actual response
    (let* ((server-req (mcp-lisp:encode-json
                        (mcp-lisp:make-ht "jsonrpc" "2.0"
                                           "id" "srv-1"
                                           "method" "sampling/createMessage"
                                           "params" (mcp-lisp:make-ht "maxTokens" 100))))
           (response (mcp-lisp:encode-json
                      (mcp-lisp:make-ht "jsonrpc" "2.0"
                                         "id" 1
                                         "result" (mcp-lisp:make-ht "ok" t))))
           (events (list (cons "message" server-req)
                         (cons "message" response))))
      ;; dispatch-sse-response processes both events
      (let ((result (mcp-lisp/src/transport/mcp-http-client::dispatch-sse-response
                     transport events)))
        ;; The handler was invoked with the server request
        (is (string= "sampling/createMessage" captured-method))
        (is (= 100 (gethash "maxTokens" captured-params)))
        ;; The actual response is still returned
        (is (hash-table-p result))
        (is (= 1 (gethash "id" result)))))))
