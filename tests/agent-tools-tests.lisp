;;;; tests/agent-tools-tests.lisp
;;;;
;;;; Tests for agent tools.

(in-package #:mcp-lisp/tests)

(def-suite agent-tools-tests :in mcp-lisp-tests)
(in-suite agent-tools-tests)

;;; Helper to call tool by name
(defun call-agent-tool (name args)
  "Call tool NAME with ARGS hash-table, return text result."
  (let* ((tool (mcp-lisp/src/primitives/tools/registry:get-tool name))
         (handler (mcp-lisp/src/primitives/tools/registry:tool-entry-handler tool))
         (result (funcall handler nil nil args))
         (first-content (aref result 0)))
    (gethash "text" first-content)))

;;; eval_lisp tests

(test eval-lisp-simple-form
  "eval_lisp evaluates simple forms correctly."
  (let ((result (call-agent-tool "eval_lisp" (mcp-lisp:make-ht "code" "(+ 1 2 3)"))))
    (is (search "=> 6" result))))

(test eval-lisp-captures-warnings
  "eval_lisp captures and returns compiler warnings."
  (let ((result (call-agent-tool "eval_lisp"
                           (mcp-lisp:make-ht "code" "(defun test-fn (x) (let ((x 1)) x))"))))
    (is (search "Warnings:" result))
    (is (search "=>" result))))

(test eval-lisp-captures-errors
  "eval_lisp captures and returns errors."
  (let ((result (call-agent-tool "eval_lisp"
                           (mcp-lisp:make-ht "code" "(error \"test error\")"))))
    (is (search "Error:" result))
    (is (search "test error" result))))

(test eval-lisp-read-error
  "eval_lisp handles read errors gracefully."
  (let ((result (call-agent-tool "eval_lisp"
                           (mcp-lisp:make-ht "code" "(defun incomplete"))))
    (is (search "Error:" result))))

;;; shell tests

(test shell-simple-command
  "shell executes simple commands."
  (let ((result (call-agent-tool "shell" (mcp-lisp:make-ht "command" "echo hello"))))
    (is (search "hello" result))))

(test shell-exit-code
  "shell reports non-zero exit codes."
  (let ((result (call-agent-tool "shell" (mcp-lisp:make-ht "command" "exit 42"))))
    (is (search "Exit code: 42" result))))

;;; Per-session sandbox isolation

(test sandbox-isolation-between-sessions
  "Definitions in one session's sandbox are not visible in another."
  (let ((session-a (mcp-lisp/src/server/state:make-session))
        (session-b (mcp-lisp/src/server/state:make-session))
        (tool (mcp-lisp/src/primitives/tools/registry:get-tool "eval_lisp")))
    (let ((handler (mcp-lisp/src/primitives/tools/registry:tool-entry-handler tool)))
      (unwind-protect
           (progn
             ;; Session A defines a function
             (funcall handler nil session-a
                      (mcp-lisp:make-ht "code" "(defun my-fn () 42)"))
             (let ((result-a (gethash "text" (aref (funcall handler nil session-a
                                                            (mcp-lisp:make-ht "code" "(my-fn)")) 0))))
               (is (search "42" result-a)))
             ;; Session B should NOT see it
             (let ((result-b (gethash "text" (aref (funcall handler nil session-b
                                                            (mcp-lisp:make-ht "code" "(my-fn)")) 0))))
               (is (search "Error" result-b))))
        (mcp-lisp/src/agent/tools:cleanup-session-sandbox session-a)
        (mcp-lisp/src/agent/tools:cleanup-session-sandbox session-b)))))

(test sandbox-cleanup-on-session-removal
  "Sandbox package is deleted when session is cleaned up."
  (let* ((session (mcp-lisp/src/server/state:make-session))
         (tool (mcp-lisp/src/primitives/tools/registry:get-tool "eval_lisp"))
         (handler (mcp-lisp/src/primitives/tools/registry:tool-entry-handler tool)))
    ;; Create the sandbox by using eval_lisp
    (funcall handler nil session (mcp-lisp:make-ht "code" "42"))
    (let ((pkg (gethash session mcp-lisp/src/agent/tools::*session-sandboxes*)))
      (is (not (null pkg)))
      ;; Cleanup
      (mcp-lisp/src/agent/tools:cleanup-session-sandbox session)
      ;; Package should be gone
      (is (null (gethash session mcp-lisp/src/agent/tools::*session-sandboxes*))))))

;;; read_file tests

(test read-file-nonexistent
  "read_file reports errors for missing files."
  (let ((result (call-agent-tool "read_file"
                           (mcp-lisp:make-ht "path" "/nonexistent/file.txt"))))
    (is (search "Error" result))))
