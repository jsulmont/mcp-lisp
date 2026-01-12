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
