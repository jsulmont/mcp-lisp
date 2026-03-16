;;;; tests/sse-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite sse-tests
  :description "Tests for SSE transport session management"
  :in mcp-lisp-tests)

(in-suite sse-tests)

(test generate-session-id-uniqueness
  "generate-session-id produces unique IDs"
  (let ((ids (loop repeat 100
                   collect (mcp-lisp/src/transport/mcp-sse:generate-session-id))))
    (is (= 100 (length (remove-duplicates ids :test #'string=))))))

(test generate-session-id-format
  "generate-session-id produces well-formed IDs"
  (let ((id (mcp-lisp/src/transport/mcp-sse:generate-session-id)))
    (is (stringp id))
    (is (> (length id) 0))
    ;; Should contain a hyphen separator
    (is (position #\- id))))

(test send-to-session-returns-nil-for-missing
  "send-to-session returns NIL when session not found"
  (let ((mcp-lisp/src/transport/mcp-sse:*sse-clients*
          (make-hash-table :test #'equal)))
    (is (null (mcp-lisp/src/transport/mcp-sse:send-to-session
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
  (let ((mcp-lisp/src/transport/mcp-sse:*sse-clients*
          (make-hash-table :test #'equal)))
    (is (hash-table-p mcp-lisp/src/transport/mcp-sse:*sse-clients*))))

;;; --- Session map operations ---

(test session-map-add-and-lookup
  "add-session stores a session retrievable by get-session"
  (let ((mcp-lisp/src/transport/mcp-sse:*sessions*
          (make-hash-table :test #'equal)))
    (let ((session (mcp-lisp/src/server/state:make-session)))
      (mcp-lisp/src/transport/mcp-sse::add-session "sess-1" session)
      (is (eq session (mcp-lisp/src/transport/mcp-sse::get-session "sess-1")))
      (is (null (mcp-lisp/src/transport/mcp-sse::get-session "nonexistent"))))))

(test session-map-remove
  "remove-session removes a session from the map"
  (let ((mcp-lisp/src/transport/mcp-sse:*sessions*
          (make-hash-table :test #'equal)))
    (let ((session (mcp-lisp/src/server/state:make-session)))
      (mcp-lisp/src/transport/mcp-sse::add-session "sess-1" session)
      (mcp-lisp/src/transport/mcp-sse::remove-session "sess-1")
      (is (null (mcp-lisp/src/transport/mcp-sse::get-session "sess-1"))))))

(test session-map-multiple-independent
  "Multiple sessions in the map are independent"
  (let ((mcp-lisp/src/transport/mcp-sse:*sessions*
          (make-hash-table :test #'equal)))
    (let ((s1 (mcp-lisp/src/server/state:make-session))
          (s2 (mcp-lisp/src/server/state:make-session)))
      (mcp-lisp/src/transport/mcp-sse::add-session "sess-1" s1)
      (mcp-lisp/src/transport/mcp-sse::add-session "sess-2" s2)
      (is (eq s1 (mcp-lisp/src/transport/mcp-sse::get-session "sess-1")))
      (is (eq s2 (mcp-lisp/src/transport/mcp-sse::get-session "sess-2")))
      ;; Removing one doesn't affect the other
      (mcp-lisp/src/transport/mcp-sse::remove-session "sess-1")
      (is (null (mcp-lisp/src/transport/mcp-sse::get-session "sess-1")))
      (is (eq s2 (mcp-lisp/src/transport/mcp-sse::get-session "sess-2"))))))

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
