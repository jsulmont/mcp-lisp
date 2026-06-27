;;;; examples/escalation-agent/client.lisp
;;;;
;;;; Claude Architect — Exercise 1, client/host half.
;;;;
;;;; Connects to the escalation-agent MCP server over Streamable HTTP and:
;;;;   * discovers the tools via tools/list and exposes them to Claude;
;;;;   * runs the agentic loop itself, branching on stop_reason (step 2);
;;;;   * applies a client-side PRE-TOOL HOOK that blocks card refunds over a
;;;;     limit and redirects them to escalation (step 4);
;;;;   * calls the MCP tools (step 1) and prints the server's logging/progress
;;;;     notifications LIVE as each tool runs;
;;;;   * handles the structured tool errors (step 3) — retrying transient ones,
;;;;     explaining the rest — and synthesizes one answer to a multi-concern
;;;;     request (step 5).
;;;;
;;;; The SDK is used only as a library; this loop is hand-written on purpose.
;;;;
;;;;   sbcl --script examples/escalation-agent/client.lisp "your message"

;;; --- Bootstrap ---
(let ((*standard-output* (make-broadcast-stream))
      (*trace-output* (make-broadcast-stream))
      (*error-output* *error-output*)
      (this-file (or *load-truename* *default-pathname-defaults*)))
  (let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
    (when (probe-file ql-setup) (load ql-setup)))
  (require :asdf)
  (let* ((here (make-pathname :directory (pathname-directory this-file)))
         (project-dir (truename (merge-pathnames "../../" here))))
    (eval `(pushnew ,project-dir ,(find-symbol "*CENTRAL-REGISTRY*" "ASDF") :test #'equal))
    ;; Muffle the library's compile-time warnings/notes. Real errors still throw.
    (handler-bind ((warning #'muffle-warning)
                   #+sbcl (sb-ext:compiler-note #'muffle-warning))
      (funcall (find-symbol "LOAD-SYSTEM" "ASDF") :mcp-lisp :verbose nil :print nil))))

(defpackage #:escalation-agent-client
  (:use #:cl #:mcp-lisp/main))
(in-package #:escalation-agent-client)

;;; --- .env loading ---

(defun project-root ()
  (truename (merge-pathnames "../../"
                             (make-pathname :directory
                                            (pathname-directory
                                             (or *load-truename* *default-pathname-defaults*))))))

(defun load-dotenv (path)
  (let ((table (make-hash-table :test #'equal)))
    (when (probe-file path)
      (with-open-file (s path :if-does-not-exist nil)
        (when s
          (loop for line = (read-line s nil nil) while line
                do (let ((line (string-trim '(#\Space #\Tab #\Return) line)))
                     (unless (or (zerop (length line)) (char= (char line 0) #\#))
                       (let ((eq (position #\= line)))
                         (when eq
                           (setf (gethash (string-trim " " (subseq line 0 eq)) table)
                                 (string-trim " " (subseq line (1+ eq))))))))))))
    table))

(defparameter *env* (load-dotenv (merge-pathnames ".env" (project-root))))
(defun env (key) (or (uiop:getenv key) (gethash key *env*)))

;;; --- Configuration ---

(defparameter *model* "claude-opus-4-8")
(defparameter *max-tokens* 4096)
(defparameter *refund-limit* 500
  "Card refunds above this dollar amount are escalated to a human supervisor.")

(defparameter *system-prompt*
  "You are a customer-support refund agent for an online store.
Work the customer's request to completion using the available tools.

Rules:
- Always lookup_order before issuing any refund or credit — it is the only
  source of an order's amount and original payment method.
- Tool results are JSON. A result with \"ok\": false is an error carrying
  \"errorCategory\", \"isRetryable\", and \"message\".
    * If isRetryable is true (transient failures), retry the SAME tool call.
    * If isRetryable is false (validation / permission), do NOT retry — explain
      the situation to the customer in plain language and move on.
- If a refund is escalated to a supervisor, tell the customer it is under review
  and give them the ticket number; do not attempt the refund again.
- When the customer raises multiple issues, handle each one, then end with a
  single clear summary covering every issue and its outcome.")

(defparameter *default-prompt*
  "I have two problems with my recent orders.
First, order A100 arrived damaged and I'd like that one refunded back to my card.
Second, order B200 was charged twice — please refund the duplicate $980 charge to my card as well.")

;;; --- Live notification printing (logging + progress) ---

(defun on-notification (method params)
  (cond
    ((string= method "notifications/progress")
     (format t "    · progress ~@[~a~]~@[/~a~]  ~@[~a~]~%"
             (gethash "progress" params) (gethash "total" params) (gethash "message" params))
     (force-output))
    ((string= method "notifications/message")
     (format t "    · log [~a] ~a~%" (gethash "level" params) (gethash "data" params))
     (force-output))
    (t (format t "    · notif ~a~%" method) (force-output))))

;;; --- Client-side pre-tool hook + escalation (step 4) ---

(defun err-envelope (category retryable message &rest extra)
  (let ((ht (make-ht "ok" nil "errorCategory" category
                     "isRetryable" retryable "message" message)))
    (loop for (k v) on extra by #'cddr do (setf (gethash k ht) v))
    (encode-json ht)))

(defun escalation-hook (name input)
  "Intercept card refunds over *REFUND-LIMIT* BEFORE the MCP tool runs.
Returns NIL to allow the call, or a replacement result envelope to block it."
  (when (string= name "issue_card_refund")
    (let ((amount (gethash "amount" input)))
      (when (and (numberp amount) (> amount *refund-limit*))
        (err-envelope "permission" nil
                      (format nil "Refund of $~,2f exceeds the $~d per-agent auto-approval ~
limit. Escalated to a human supervisor — do not retry. Tell the customer a ~
supervisor will review within 1 business day."
                              amount *refund-limit*)
                      "escalated" t
                      "ticket" "ESC-7782")))))

;;; --- Tool discovery: MCP tools/list -> Anthropic tool schemas ---
;;; Loading mcp-lisp registers the agent's built-in tools (shell, eval_lisp, …)
;;; globally too, so the host curates the set down to just this exercise's four.

(defparameter *exposed-tools*
  '("lookup_order" "check_refund_eligibility" "issue_card_refund" "apply_account_credit"))

(defun mcp-tools->anthropic (mcp-tools)
  (let ((wanted '()))
    (loop for tool across mcp-tools
          when (member (gethash "name" tool) *exposed-tools* :test #'string=)
            do (push (make-ht "name" (gethash "name" tool)
                              "description" (gethash "description" tool)
                              "input_schema" (gethash "inputSchema" tool))
                     wanted))
    (coerce (nreverse wanted) 'vector)))

;;; --- Anthropic Messages API call ---

(defun call-claude (messages tools)
  (let ((key (env "ANTHROPIC_API_KEY"))
        (body (make-ht "model" *model*
                       "max_tokens" *max-tokens*
                       "system" *system-prompt*
                       "messages" (coerce messages 'vector)
                       "tools" tools)))
    (handler-case
        (decode-json
         (dex:post "https://api.anthropic.com/v1/messages"
                   :headers `(("x-api-key" . ,key)
                              ("anthropic-version" . "2023-06-01")
                              ("content-type" . "application/json"))
                   :content (encode-json body)
                   :read-timeout 120))
      (dexador.error:http-request-failed (e)
        (error "Anthropic API ~a: ~a"
               (dexador.error:response-status e)
               (dexador.error:response-body e))))))

;;; --- Transcript helpers ---

(defun content-text (content)
  (with-output-to-string (s)
    (loop for block across content
          when (string= (gethash "type" block) "text")
            do (write-string (gethash "text" block) s))))

(defun print-assistant-turn (content)
  (let ((text (content-text content)))
    (when (plusp (length text))
      (format t "~&Assistant: ~a~%" text)))
  (loop for block across content
        when (string= (gethash "type" block) "tool_use")
          do (format t "~&  -> tool_use ~a ~a~%"
                     (gethash "name" block)
                     (encode-json (gethash "input" block)))))

;;; --- Tool execution: hook, then MCP call ---

(defvar *call-counter* 0)

(defun call-mcp-tool (client name input)
  "Invoke an MCP tool, passing a fresh progressToken so the server's
tool-report-progress notifications are actually delivered. Returns the text."
  (let* ((token (format nil "call-~a" (incf *call-counter*)))
         (params (make-ht "name" name
                          "arguments" input
                          "_meta" (make-ht "progressToken" token)))
         (result (client-call client "tools/call" params :timeout 60))
         (content (gethash "content" result)))
    (gethash "text" (aref content 0))))

(defun execute-tools (client content)
  "Run every tool_use block: hook first, else dispatch to the MCP server.
Returns a vector of tool_result blocks."
  (let ((results '()))
    (loop for block across content
          when (string= (gethash "type" block) "tool_use")
            do (let* ((id (gethash "id" block))
                      (name (gethash "name" block))
                      (input (gethash "input" block))
                      (intercepted (escalation-hook name input))
                      (text (cond
                              (intercepted
                               (format t "    · [hook] blocked ~a — escalating~%" name)
                               (force-output)
                               intercepted)
                              (t (call-mcp-tool client name input)))))
                 (format t "    = result ~a~%" text)
                 (push (make-ht "type" "tool_result"
                                "tool_use_id" id
                                "content" text)
                       results)))
    (coerce (nreverse results) 'vector)))

;;; --- Agentic loop (step 2) ---

(defun run-loop (client tools user-prompt &key (max-iterations 10))
  (let ((messages (list (make-ht "role" "user" "content" user-prompt))))
    (loop for i from 1 to max-iterations
          do (let* ((response (call-claude messages tools))
                    (stop (gethash "stop_reason" response))
                    (content (gethash "content" response)))
               (format t "~&--- turn ~a (stop_reason: ~a) ---~%" i stop)
               (print-assistant-turn content)
               (cond
                 ((string= stop "tool_use")
                  (let ((tool-results (execute-tools client content)))
                    (setf messages
                          (append messages
                                  (list (make-ht "role" "assistant" "content" content))
                                  (list (make-ht "role" "user" "content" tool-results))))))
                 ((string= stop "end_turn")
                  (return-from run-loop (content-text content)))
                 ((string= stop "max_tokens")
                  (return-from run-loop
                    (format nil "[stopped: hit max_tokens]~%~a" (content-text content))))
                 ((string= stop "refusal")
                  (return-from run-loop "[the model refused this request]"))
                 (t
                  (return-from run-loop (format nil "[unexpected stop_reason: ~a]" stop)))))
          finally (return "[stopped: max iterations reached]"))))

;;; --- Run ---

(defparameter *prompt*
  (or (find-if (lambda (a) (and (plusp (length a))
                                (not (char= (char a 0) #\-))
                                (not (search ".lisp" a))))
               (cdr sb-ext:*posix-argv*))
      *default-prompt*))

(defun run-client (prompt)
  "Connect to the MCP server, drive the agent loop on PROMPT, print the result."
  (let ((client (make-http-client "http://localhost:8765/mcp")))
    (client-connect client)
    (client-initialize client)
    (setf (client-notification-handler client) #'on-notification)
    (client-call client "logging/setLevel" (make-ht "level" "debug"))
    (unwind-protect
         (let* ((listing (client-call client "tools/list" (make-ht)))
                (tools (mcp-tools->anthropic (gethash "tools" listing))))
           (format t "~&========== Escalation Agent (Exercise 1) ==========~%")
           (format t "MCP tools exposed: ~{~a~^, ~}~%"
                   (map 'list (lambda (tl) (gethash "name" tl)) tools))
           (format t "User: ~a~%~%" prompt)
           (let ((final (run-loop client tools prompt)))
             (format t "~%========== Final synthesized response ==========~%~a~%" final)))
      (client-disconnect client))))

;; Auto-run only as a script. Under SLY/Slynk, loading the file just defines
;; everything (no connect, no exit) so you can call (run-client …) by hand.
(unless (find-package '#:slynk)
  (unless (env "ANTHROPIC_API_KEY")
    (format t "~&[escalation-agent] ANTHROPIC_API_KEY is not set.~%~
The client drives the agent loop by calling Claude. Add~%~
  ANTHROPIC_API_KEY=...~%~
to the project-root .env (or export it), then run again. Skipping.~%")
    (sb-ext:exit :code 0))
  (run-client *prompt*)
  (sb-ext:exit))
