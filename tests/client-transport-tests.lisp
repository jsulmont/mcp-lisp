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
