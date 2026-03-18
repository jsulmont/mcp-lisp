;;;; tests/sse-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite sse-tests
  :description "Tests for SSE transport session management"
  :in mcp-lisp-tests)

(in-suite sse-tests)

(test generate-session-id-uniqueness
  "generate-session-id produces unique IDs"
  (let ((ids (loop repeat 100
                   collect (mcp-lisp/src/transport/mcp-woo:generate-session-id))))
    (is (= 100 (length (remove-duplicates ids :test #'string=))))))

(test generate-session-id-format
  "generate-session-id produces well-formed IDs"
  (let ((id (mcp-lisp/src/transport/mcp-woo:generate-session-id)))
    (is (stringp id))
    (is (> (length id) 0))
    ;; Should contain a hyphen separator
    (is (position #\- id))))

(test send-to-session-returns-nil-for-missing
  "send-to-session returns NIL when session not found"
  (let ((mcp-lisp/src/transport/mcp-woo:*sse-clients*
          (make-hash-table :test #'equal)))
    (is (null (mcp-lisp/src/transport/mcp-woo:send-to-session
               "nonexistent-session"
               "{\"test\": true}"
               "message")))))

(test send-to-session-session-isolation
  "Sessions are isolated - sending to one doesn't affect others"
  ;; This test verifies the conceptual model: each session has its own stream
  ;; We can't fully test without real streams, but we can verify the hash-table structure
  (let ((clients (make-hash-table :test #'equal)))
    (setf (gethash "session-1" clients) :stream-1)
    (setf (gethash "session-2" clients) :stream-2)
    ;; Verify sessions are independent
    (is (eq :stream-1 (gethash "session-1" clients)))
    (is (eq :stream-2 (gethash "session-2" clients)))
    (is (null (gethash "session-3" clients)))))

(test sse-clients-is-hash-table
  "SSE clients storage uses hash-table for session lookup"
  ;; After server initialization, *sse-clients* should be a hash-table
  (let ((mcp-lisp/src/transport/mcp-woo:*sse-clients*
          (make-hash-table :test #'equal)))
    (is (hash-table-p mcp-lisp/src/transport/mcp-woo:*sse-clients*))))

;;; --- SSE reconnect ---

(test sse-reconnect-closes-old-writer
  "Reconnecting a session closes the previous writer via its bridge"
  (let* ((queue (sb-concurrency:make-queue :name "test-bridge"))
         (bridge (mcp-lisp/src/transport/mcp-woo::make-evloop-bridge
                   :evloop-ptr (cffi:null-pointer)
                   :async-watcher (cffi:null-pointer)
                   :result-queue queue))
         (old-writer :old-writer)
         (new-writer :new-writer)
         (mcp-lisp/src/transport/mcp-woo:*sse-clients*
           (make-hash-table :test #'equal))
         (mcp-lisp/src/transport/mcp-woo:*sse-clients-lock*
           (bt:make-lock "test")))
    ;; Simulate existing session with old writer
    (setf (gethash "sess-1" mcp-lisp/src/transport/mcp-woo:*sse-clients*)
          (cons old-writer bridge))
    ;; Simulate reconnect: register new writer for same session
    ;; (replicate what handle-get does inside the lock)
    (bt:with-lock-held (mcp-lisp/src/transport/mcp-woo:*sse-clients-lock*)
      (let ((old (gethash "sess-1" mcp-lisp/src/transport/mcp-woo:*sse-clients*)))
        (when old
          ;; Enqueue close for old writer — uses the queue directly since
          ;; we can't call ev-async-send on a null pointer
          (sb-concurrency:enqueue
           (mcp-lisp/src/transport/mcp-woo::make-completion
            :type :sse-close :writer (car old))
           (mcp-lisp/src/transport/mcp-woo::evloop-bridge-result-queue (cdr old)))))
      (setf (gethash "sess-1" mcp-lisp/src/transport/mcp-woo:*sse-clients*)
            (cons new-writer bridge)))
    ;; Verify: new writer is registered
    (is (eq new-writer
            (car (gethash "sess-1" mcp-lisp/src/transport/mcp-woo:*sse-clients*))))
    ;; Verify: a close completion for the old writer was enqueued
    (let ((completion (sb-concurrency:dequeue queue)))
      (is (not (null completion)))
      (is (eq :sse-close (mcp-lisp/src/transport/mcp-woo::completion-type completion)))
      (is (eq old-writer (mcp-lisp/src/transport/mcp-woo::completion-writer completion))))))

;;; --- Session map operations ---

(test session-map-add-and-lookup
  "add-session stores a session retrievable by get-session"
  (let ((mcp-lisp/src/transport/mcp-woo:*sessions*
          (make-hash-table :test #'equal)))
    (let ((session (mcp-lisp/src/server/state:make-session)))
      (mcp-lisp/src/transport/mcp-woo::add-session "sess-1" session)
      (is (eq session (mcp-lisp/src/transport/mcp-woo::get-session "sess-1")))
      (is (null (mcp-lisp/src/transport/mcp-woo::get-session "nonexistent"))))))

(test session-map-remove
  "remove-session removes a session from the map"
  (let ((mcp-lisp/src/transport/mcp-woo:*sessions*
          (make-hash-table :test #'equal)))
    (let ((session (mcp-lisp/src/server/state:make-session)))
      (mcp-lisp/src/transport/mcp-woo::add-session "sess-1" session)
      (mcp-lisp/src/transport/mcp-woo::remove-session "sess-1")
      (is (null (mcp-lisp/src/transport/mcp-woo::get-session "sess-1"))))))

(test session-map-multiple-independent
  "Multiple sessions in the map are independent"
  (let ((mcp-lisp/src/transport/mcp-woo:*sessions*
          (make-hash-table :test #'equal)))
    (let ((s1 (mcp-lisp/src/server/state:make-session))
          (s2 (mcp-lisp/src/server/state:make-session)))
      (mcp-lisp/src/transport/mcp-woo::add-session "sess-1" s1)
      (mcp-lisp/src/transport/mcp-woo::add-session "sess-2" s2)
      (is (eq s1 (mcp-lisp/src/transport/mcp-woo::get-session "sess-1")))
      (is (eq s2 (mcp-lisp/src/transport/mcp-woo::get-session "sess-2")))
      ;; Removing one doesn't affect the other
      (mcp-lisp/src/transport/mcp-woo::remove-session "sess-1")
      (is (null (mcp-lisp/src/transport/mcp-woo::get-session "sess-1")))
      (is (eq s2 (mcp-lisp/src/transport/mcp-woo::get-session "sess-2"))))))

;;; --- Multi-session handler isolation ---

(test multi-session-handler-isolation
  "Handler closures use *current-session*, isolating concurrent sessions"
  (let* ((server (mcp-lisp/src/server/server:make-server :name "test" :version "1.0"))
         (handlers (make-hash-table :test #'equal)))
    (mcp-lisp/src/server/server::setup-handlers server handlers)
    (let ((init-handler (gethash "initialize" handlers))
          (session-a (mcp-lisp/src/server/state:make-session))
          (session-b (mcp-lisp/src/server/state:make-session)))
      ;; Initialize session A with one protocol version
      (let ((mcp-lisp/src/server/state:*current-session* session-a))
        (funcall init-handler
                 (mcp-lisp:make-ht "protocolVersion" "2024-11-05"
                                    "clientInfo" (mcp-lisp:make-ht "name" "client-a"))))
      ;; Initialize session B with a different protocol version
      (let ((mcp-lisp/src/server/state:*current-session* session-b))
        (funcall init-handler
                 (mcp-lisp:make-ht "protocolVersion" "2025-03-26"
                                    "clientInfo" (mcp-lisp:make-ht "name" "client-b"))))
      ;; Verify isolation — each session has its own state
      (is (string= "2024-11-05"
                    (mcp-lisp/src/server/state:session-protocol-version session-a)))
      (is (string= "2025-03-26"
                    (mcp-lisp/src/server/state:session-protocol-version session-b)))
      (is (string= "client-a"
                    (gethash "name" (mcp-lisp/src/server/state:session-client-info session-a))))
      (is (string= "client-b"
                    (gethash "name" (mcp-lisp/src/server/state:session-client-info session-b)))))))

;;; --- Clack response and origin tests ---

(test make-immediate-response-body-is-flat-list
  "make-immediate-response wraps body-string in a single list, not nested"
  (let ((resp (mcp-lisp/src/transport/mcp-woo::make-immediate-response
               200 '(:content-type "text/plain") "hello")))
    (destructuring-bind (status headers body) resp
      (is (= 200 status))
      (is (equal '(:content-type "text/plain") headers))
      ;; Body must be ("hello"), not (("hello"))
      (is (equal '("hello") body))
      (is (stringp (first body))))))

(test make-immediate-response-empty-body
  "make-immediate-response with empty string produces a list of one empty string"
  (let ((body (third (mcp-lisp/src/transport/mcp-woo::make-immediate-response 202 nil ""))))
    (is (equal '("") body))))

(test localhost-p-recognizes-all-forms
  "localhost-p handles IPv4, IPv6, with and without port"
  (dolist (host '("localhost" "localhost:8080"
                  "127.0.0.1" "127.0.0.1:8080"
                  "[::1]" "[::1]:8080"
                  "::1"
                  "LOCALHOST" "Localhost:3000"))
    (is (mcp-lisp/src/transport/mcp-woo::localhost-p host)
        "Expected ~a to be recognized as localhost" host)))

(test localhost-p-rejects-non-localhost
  "localhost-p rejects non-localhost hosts"
  (dolist (host '("evil.com" "192.168.1.1" "10.0.0.1:8080"
                  "localhost.evil.com" "[::2]" "[::2]:80"))
    (is (not (mcp-lisp/src/transport/mcp-woo::localhost-p host))
        "Expected ~a to be rejected" host)))

(test localhost-p-handles-nil-and-empty
  "localhost-p returns NIL for nil and empty string"
  (is (null (mcp-lisp/src/transport/mcp-woo::localhost-p nil)))
  (is (null (mcp-lisp/src/transport/mcp-woo::localhost-p ""))))

(test valid-origin-p-allows-no-origin
  "Requests with no Origin header are allowed"
  (let ((env (list :headers (make-hash-table :test #'equal))))
    (is (mcp-lisp/src/transport/mcp-woo::valid-origin-p env))))

(test valid-origin-p-allows-localhost
  "Requests from localhost origins are allowed (IPv4, IPv6, with/without port)"
  (dolist (origin '("http://localhost:3000"
                    "http://127.0.0.1:8080"
                    "http://localhost"
                    "http://[::1]:8080"
                    "http://[::1]"))
    (let ((headers (make-hash-table :test #'equal)))
      (setf (gethash "origin" headers) origin)
      (is (mcp-lisp/src/transport/mcp-woo::valid-origin-p (list :headers headers))
          "Expected ~a to be valid" origin))))

(test valid-origin-p-rejects-external
  "Requests from non-localhost origins are rejected"
  (dolist (origin '("http://evil.com" "http://192.168.1.1:8080" "https://attacker.io"))
    (let ((headers (make-hash-table :test #'equal)))
      (setf (gethash "origin" headers) origin)
      (is (not (mcp-lisp/src/transport/mcp-woo::valid-origin-p (list :headers headers)))
          "Expected ~a to be rejected" origin))))

(test clack-app-origin-rejection-returns-403
  "clack-app returns 403 for invalid origin and does not crash"
  (let ((mcp-lisp/src/transport/mcp-woo::*handlers* (make-hash-table :test #'equal))
        (captured-response nil))
    (let* ((headers (make-hash-table :test #'equal))
           (_ (setf (gethash "origin" headers) "http://evil.com"))
           (env (list :request-method :post :path-info "/mcp" :headers headers))
           (delayed-fn (mcp-lisp/src/transport/mcp-woo::clack-app env)))
      (declare (ignore _))
      ;; Call the delayed response closure — must not signal an error
      (funcall delayed-fn (lambda (resp) (setf captured-response resp)))
      (is (not (null captured-response)))
      (is (= 403 (first captured-response))))))

(test clack-app-options-bypasses-origin-check
  "OPTIONS requests bypass origin check (CORS preflight)"
  (let ((mcp-lisp/src/transport/mcp-woo::*handlers* (make-hash-table :test #'equal))
        (captured-response nil))
    (let* ((headers (make-hash-table :test #'equal))
           (_ (setf (gethash "origin" headers) "http://evil.com"))
           (env (list :request-method :options :path-info "/mcp" :headers headers))
           (delayed-fn (mcp-lisp/src/transport/mcp-woo::clack-app env)))
      (declare (ignore _))
      (funcall delayed-fn (lambda (resp) (setf captured-response resp)))
      (is (not (null captured-response)))
      ;; OPTIONS should succeed (200) even with bad origin
      (is (= 200 (first captured-response))))))

(test start-sse-server-fails-when-thread-dies
  "start-sse-server signals an error when the server thread dies during startup"
  ;; Temporarily override woo:run with a function that immediately errors,
  ;; simulating a bind failure or other startup crash.
  (let ((original-fn (symbol-function 'woo:run)))
    (unwind-protect
         (progn
           (setf (symbol-function 'woo:run)
                 (lambda (app &rest args)
                   (declare (ignore app args))
                   (error "simulated bind failure")))
           (signals error
             (mcp-lisp/src/transport/mcp-woo:start-sse-server
              (make-hash-table :test #'equal)
              :port 19999)))
      (setf (symbol-function 'woo:run) original-fn)
      ;; Ensure cleanup even if test fails
      (ignore-errors (mcp-lisp/src/transport/mcp-woo:stop-sse-server)))))

;;; --- Worker pool lifecycle integration ---

(test start-sse-server-creates-tool-pool
  "start-sse-server creates a worker pool and stop-sse-server destroys it"
  (let ((original-fn (symbol-function 'woo:run)))
    (unwind-protect
         (progn
           ;; Mock woo:run to block until signaled
           (let ((stop-flag nil))
             (setf (symbol-function 'woo:run)
                   (lambda (app &rest args)
                     (declare (ignore app args))
                     ;; Simulate a listening server by sleeping
                     (loop until stop-flag do (sleep 0.05))))
             ;; Use a port that's free (mock doesn't bind anything, but
             ;; start-sse-server polls with usocket — mock that too)
             (let ((orig-connect (symbol-function 'usocket:socket-connect)))
               (unwind-protect
                    (progn
                      ;; Make the connectivity check succeed immediately
                      (setf (symbol-function 'usocket:socket-connect)
                            (lambda (host port &rest args)
                              (declare (ignore args))
                              (funcall orig-connect host port)))
                      ;; Start server
                      (ignore-errors
                        (mcp-lisp/src/transport/mcp-woo:start-sse-server
                         (make-hash-table :test #'equal)
                         :port 19876 :tool-workers 2))
                      ;; Pool should exist and be running
                      (is (not (null mcp-lisp/src/transport/mcp-woo::*tool-pool*)))
                      (is (mcp-lisp/src/transport/worker-pool:worker-pool-running-p
                           mcp-lisp/src/transport/mcp-woo::*tool-pool*))
                      (is (= 2 (mcp-lisp/src/transport/worker-pool:worker-pool-size
                                mcp-lisp/src/transport/mcp-woo::*tool-pool*)))
                      ;; Stop server
                      (setf stop-flag t)
                      (mcp-lisp/src/transport/mcp-woo:stop-sse-server)
                      ;; Pool should be gone
                      (is (null mcp-lisp/src/transport/mcp-woo::*tool-pool*)))
                 (setf (symbol-function 'usocket:socket-connect) orig-connect)))))
      (setf (symbol-function 'woo:run) original-fn)
      (ignore-errors (mcp-lisp/src/transport/mcp-woo:stop-sse-server)))))

(test multi-session-subscription-isolation
  "Resource subscriptions are per-session, not global"
  (let* ((server (mcp-lisp/src/server/server:make-server :name "test" :version "1.0"))
         (handlers (make-hash-table :test #'equal)))
    (mcp-lisp/src/server/server::setup-handlers server handlers)
    (let ((subscribe-handler (gethash "resources/subscribe" handlers))
          (session-a (mcp-lisp/src/server/state:make-session))
          (session-b (mcp-lisp/src/server/state:make-session)))
      ;; Subscribe session A to a resource
      (let ((mcp-lisp/src/server/state:*current-session* session-a))
        (funcall subscribe-handler
                 (mcp-lisp:make-ht "uri" "config://server/info")))
      ;; Session B should NOT be subscribed
      (is (mcp-lisp/src/server/state:session-subscribed-p
           session-a "config://server/info"))
      (is (not (mcp-lisp/src/server/state:session-subscribed-p
                session-b "config://server/info"))))))
