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

;;; --- Bidirectional stdio server loop ---

(def-suite stdio-server-tests
  :description "Tests for the bidirectional stdio server loop"
  :in mcp-lisp-tests)

(in-suite stdio-server-tests)

(defun %stdio-pending-count (chan)
  (hash-table-count (mcp-lisp/src/transport/mcp-stdio::stdio-channel-pending chan)))

(test stdio-channel-call-roundtrip
  "channel-call writes a request, blocks, and returns when its response is routed"
  (let* ((chan (mcp-lisp/src/transport/mcp-stdio::make-stdio-channel
                :output (make-string-output-stream)))
         (result nil) (err nil)
         (th (bt:make-thread
              (lambda ()
                (handler-case
                    (setf result (mcp-lisp/src/transport/mcp-stdio::channel-call
                                  chan "sampling/createMessage"
                                  (mcp-lisp:make-ht "maxTokens" 10) 5))
                  (error (e) (setf err e)))))))
    ;; wait until the call has registered its pending waiter
    (loop repeat 200 until (plusp (%stdio-pending-count chan)) do (sleep 0.01))
    (mcp-lisp/src/transport/mcp-stdio::channel-resolve
     chan (mcp-lisp:make-ht "jsonrpc" "2.0" "id" 1
                            "result" (mcp-lisp:make-ht "model" "claude")))
    (bt:join-thread th)
    (is (null err))
    (is (string= "claude" (gethash "model" result)))))

(test stdio-channel-resolve-all-unblocks
  "channel-resolve-all fails in-flight server->client calls when stdin closes"
  (let* ((chan (mcp-lisp/src/transport/mcp-stdio::make-stdio-channel
                :output (make-string-output-stream)))
         (err nil)
         (th (bt:make-thread
              (lambda ()
                (handler-case
                    (mcp-lisp/src/transport/mcp-stdio::channel-call
                     chan "elicitation/create" (mcp-lisp:make-ht) 5)
                  (error (e) (setf err e)))))))
    (loop repeat 200 until (plusp (%stdio-pending-count chan)) do (sleep 0.01))
    (mcp-lisp/src/transport/mcp-stdio::channel-resolve-all chan "stdin closed")
    (bt:join-thread th)
    (is (not (null err)))))

(test stdio-server-loop-basic-request
  "mcp-server-loop processes a request and writes a JSON-RPC response"
  (let ((handlers (make-hash-table :test #'equal))
        (in (make-string-input-stream
             (format nil "~a~%"
                     (mcp-lisp:encode-json
                      (mcp-lisp:make-ht "jsonrpc" "2.0" "id" 7 "method" "ping")))))
        (out (make-string-output-stream)))
    (setf (gethash "ping" handlers)
          (lambda (p) (declare (ignore p)) (mcp-lisp:make-ht "ok" t)))
    (mcp-lisp/src/transport/mcp-stdio:mcp-server-loop handlers :input in :output out)
    (let ((resp (mcp-lisp:decode-json
                 (string-trim '(#\Newline #\Return) (get-output-stream-string out)))))
      (is (= 7 (gethash "id" resp)))
      (is (eq t (gethash "ok" (gethash "result" resp)))))))

(test stdio-server-loop-notification-no-response
  "mcp-server-loop runs a notification handler and writes no response"
  (let ((handlers (make-hash-table :test #'equal))
        (seen nil)
        (in (make-string-input-stream
             (format nil "~a~%"
                     (mcp-lisp:encode-json
                      (mcp-lisp:make-ht "jsonrpc" "2.0"
                                        "method" "notifications/initialized")))))
        (out (make-string-output-stream)))
    (setf (gethash "notifications/initialized" handlers)
          (lambda (p) (declare (ignore p)) (setf seen t)))
    (mcp-lisp/src/transport/mcp-stdio:mcp-server-loop handlers :input in :output out)
    (is (eq t seen))
    (is (string= "" (get-output-stream-string out)))))

;;; --- Server->client requests reach the client request handler ---
;;; A server-initiated request carries BOTH method and id. The reader must route
;;; it to the request handler and reply — not mistake it for a response (the bug
;;; that made the stdio client silently drop sampling/elicitation requests).

(test stdio-client-routes-server-request-to-handler
  "reader-loop dispatches a server-initiated request to the handler, which replies"
  (let* ((req (mcp-lisp:encode-json
               (mcp-lisp:make-ht "jsonrpc" "2.0" "id" 7
                                 "method" "sampling/createMessage"
                                 "params" (mcp-lisp:make-ht "maxTokens" 8))))
         (in (make-string-input-stream (format nil "~a~%" req)))
         (out (make-string-output-stream))
         (transport (mcp-lisp/src/transport/mcp-client:make-stdio-transport '("true")))
         (captured-method nil)
         (sem (bt:make-semaphore)))
    (setf (mcp-lisp/src/transport/mcp-client::transport-input transport) in
          (mcp-lisp/src/transport/mcp-client::transport-output transport) out
          (mcp-lisp/src/transport/protocol:transport-running-p transport) t
          (mcp-lisp/src/transport/mcp-client:stdio-transport-request-handler transport)
          (lambda (method params)
            (declare (ignore params))
            (setf captured-method method)
            (bt:signal-semaphore sem)
            (mcp-lisp:make-ht "model" "test")))
    ;; reads the request (spawns a handler thread), then hits EOF and returns
    (mcp-lisp/src/transport/mcp-client::reader-loop transport)
    (is (bt:wait-on-semaphore sem :timeout 5))
    (is (string= "sampling/createMessage" captured-method))
    ;; the handler thread writes a JSON-RPC response back to OUT
    (let ((written ""))
      (loop repeat 60
            do (setf written (concatenate 'string written (get-output-stream-string out)))
               (when (search "result" written) (return))
               (sleep 0.05))
      (is (search "\"id\":7" written))
      (is (search "result" written)))))

;;; --- Live HTTP end-to-end: server-initiated sampling round-trip ---
;;; This is the regression guard the original unit test lacked. A buffered SSE
;;; read deadlocks here (server holds the stream open awaiting our response while
;;; dex:post buffers the whole body); the incremental reader returns promptly.

(test http-sampling-roundtrip-end-to-end
  "Server-initiated sampling completes over a live HTTP/SSE transport"
  (mcp-lisp:define-tool sampling-probe-tool ()
    "Asks the client to sample and returns the sampled text."
    (let* ((res (mcp-lisp:tool-sample
                 (list (mcp-lisp:make-sampling-message "user" "hi")) :max-tokens 8))
           (content (and (hash-table-p res) (gethash "content" res))))
      (and (hash-table-p content) (gethash "text" content))))
  (let ((port 18837))
    (mcp-lisp:run-server :name "sampling-test" :version "1.0" :transport :sse :port port)
    (unwind-protect
         (let ((client (mcp-lisp:make-http-client
                        (format nil "http://localhost:~a/mcp" port))))
           (mcp-lisp:client-connect client)
           (mcp-lisp:client-initialize client)
           (setf (mcp-lisp:client-request-handler client)
                 (lambda (method params)
                   (declare (ignore method params))
                   (mcp-lisp:make-ht "role" "assistant"
                                     "content" (mcp-lisp:make-ht "type" "text"
                                                                 "text" "SAMPLED-OK")
                                     "model" "test" "stopReason" "endTurn")))
           ;; A short timeout: a regression to buffered reads fails fast here
           ;; instead of hanging for the server's 30s stream-call timeout.
           (let ((r (mcp-lisp:client-call
                     client "tools/call"
                     (mcp-lisp:make-ht "name" "sampling_probe_tool"
                                       "arguments" (mcp-lisp:make-ht))
                     :timeout 8)))
             (is (string= "SAMPLED-OK"
                          (gethash "text" (aref (gethash "content" r) 0)))))
           (mcp-lisp:client-disconnect client))
      (mcp-lisp/src/transport/mcp-woo:stop-sse-server))))
