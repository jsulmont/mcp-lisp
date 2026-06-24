;;;; tests/logging-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite logging-tests
  :description "Per-session log level and notifications/message emission"
  :in mcp-lisp-tests)

(in-suite logging-tests)

(test set-level-is-per-session
  "logging/setLevel updates only the target session"
  (let ((a (mcp-lisp/src/server/state:make-session))
        (b (mcp-lisp/src/server/state:make-session)))
    (mcp-lisp/src/server/logging:handle-logging-set-level
     a (mcp-lisp:make-ht "level" "warning"))
    (is (string= "warning" (mcp-lisp/src/server/state:session-log-level a)))
    (is (string= "info" (mcp-lisp/src/server/state:session-log-level b)))))

(test set-level-validation
  "logging/setLevel rejects missing and invalid levels"
  (let ((s (mcp-lisp/src/server/state:make-session)))
    (signals mcp-lisp/src/conditions:invalid-params-error
      (mcp-lisp/src/server/logging:handle-logging-set-level s (mcp-lisp:make-ht)))
    (signals mcp-lisp/src/conditions:invalid-params-error
      (mcp-lisp/src/server/logging:handle-logging-set-level
       s (mcp-lisp:make-ht "level" "bogus")))))

(test log-enabled-respects-session-level
  "log-enabled-p gates by the session minimum level"
  (let ((s (mcp-lisp/src/server/state:make-session)))
    (setf (mcp-lisp/src/server/state:session-log-level s) "warning")
    (is (mcp-lisp/src/server/logging:log-enabled-p s "error"))
    (is (mcp-lisp/src/server/logging:log-enabled-p s "warning"))
    (is (not (mcp-lisp/src/server/logging:log-enabled-p s "info")))
    (is (not (mcp-lisp/src/server/logging:log-enabled-p s "debug")))))

(test send-log-filters-and-emits
  "send-log drops below-level messages and emits qualifying ones with proper params"
  (let ((s (mcp-lisp/src/server/state:make-session))
        (sent nil))
    (setf (mcp-lisp/src/server/state:session-log-level s) "warning")
    (let ((notify (lambda (m p) (push (cons m p) sent))))
      ;; below level -> dropped
      (is (null (mcp-lisp/src/server/logging:send-log notify s "info" "ignored")))
      (is (null sent))
      ;; at/above level -> emitted
      (is (mcp-lisp/src/server/logging:send-log notify s "error" "boom" :logger "db"))
      (is (= 1 (length sent)))
      (let ((method (car (first sent)))
            (params (cdr (first sent))))
        (is (string= "notifications/message" method))
        (is (string= "error" (gethash "level" params)))
        (is (string= "boom" (gethash "data" params)))
        (is (string= "db" (gethash "logger" params)))))))

(test tool-log-emits-through-context
  "tool-log sends notifications/message via the bound tool-context channel"
  (let ((sent nil)
        (session (mcp-lisp/src/server/state:make-session)))
    (let ((mcp-lisp/src/server/state:*current-session* session)
          (mcp-lisp/src/server/tool-context:*tool-context*
            (mcp-lisp/src/server/tool-context:make-tool-context
             :notify-fn (lambda (m p) (push (cons m p) sent)))))
      (mcp-lisp:tool-log "error" "disk full" :logger "storage")
      (is (= 1 (length sent)))
      (is (string= "notifications/message" (car (first sent))))
      (is (string= "disk full" (gethash "data" (cdr (first sent)))))
      (is (string= "storage" (gethash "logger" (cdr (first sent))))))))
