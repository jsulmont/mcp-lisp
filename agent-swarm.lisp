;;;; agent-swarm.lisp
;;;;
;;;; Multi-agent coordinator that decomposes complex tasks and routes
;;;; to specialist sub-agents, each with a restricted toolset.
;;;;
;;;; Architecture:
;;;;   Coordinator (delegation tools + test_tool)
;;;;     ├─ ask_researcher  →  Researcher (web_search, read_file)
;;;;     ├─ ask_coder       →  Coder (eval_lisp, clear_repl, test_tool)
;;;;     ├─ ask_analyst     →  Analyst (shell, read_file)
;;;;     └─ test_tool       →  Test agent (any registered tool)
;;;;
;;;; The coordinator delegates to specialists or uses test_tool to call
;;;; session-created tools. Each specialist runs its own agent loop with
;;;; bounded iterations.
;;;;
;;;; Usage:
;;;;   sbcl --load agent-swarm.lisp
;;;;
;;;; Requires an LLM API key. Configure via:
;;;;   (setf mcp-lisp:*provider* :anthropic)   ; or :groq, :openai
;;;;   (setf mcp-lisp:*api-key* "sk-...")
;;;; Or env vars: ANTHROPIC_API_KEY, GROQ_API_KEY, OPENAI_API_KEY

(ql:quickload '(:mcp-lisp :cl-readline) :silent t)

(defpackage #:agent-swarm
  (:use #:cl)
  (:import-from #:mcp-lisp
                #:*provider* #:*api-key* #:*model* #:*max-tokens* #:*verbose*
                #:run-agent #:*global-tool-registry*
                #:define-tool #:make-ht))

(in-package #:agent-swarm)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(setf *provider* :anthropic)
(setf *max-tokens* 16000)

(defparameter *specialist-max-iterations* 8
  "Maximum LLM round-trips per specialist invocation.")

(defparameter *coordinator-max-iterations* 15
  "Maximum LLM round-trips for the coordinator.")

(defparameter *token-budget* 100000
  "Total token budget across the entire swarm (coordinator + all specialists).
Wind-down triggers at 85%.")

(defparameter *call-budget* 30
  "Maximum LLM API calls across the entire swarm. Covers coordinator +
all specialist calls combined.")

(defparameter *thinking-budget* 10000
  "When set to an integer, enables Anthropic extended thinking with this
many tokens of budget per API call. Nil disables thinking.")

;;; ---------------------------------------------------------------------------
;;; System prompts
;;; ---------------------------------------------------------------------------

(defparameter *researcher-prompt*
  "You are a research specialist. Gather information using web search and file
reading. Be concise. Combine multiple queries when possible. When you have
enough to answer, stop immediately and return a clear summary. Do not
speculate — only report what you found.")

(defparameter *coder-prompt*
  "You are a coding specialist working in a Common Lisp REPL (SBCL).
The sandbox has mcp-lisp loaded. All exported symbols work without prefix.

RULES:
- Do NOT create packages. Everything goes in the sandbox.
- Use kebab-case: convert-units NOT convert_units.
- Multiple forms in one eval_lisp call is preferred.
- If something fails, read the error and fix it — don't just report it.
- Implement AND test in the same session. Do not split across calls.
- Always use (pp obj) to print values — it renders everything as readable JSON.

DEFINING MCP TOOLS (complete working example — define-tool auto-registers):

  (define-tool my-tool
      ((arg string \"description\" :required t)
       (nums array \"list of numbers\" :required t)
       (opt integer \"optional\" :default 10))
    \"Tool docstring shown to the LLM.\"
    (:annotations :read-only t)
    (format nil \"result: ~a ~a ~a\" arg (coerce nums 'list) opt))

  - That's it. No register-tool call needed.
  - Name converts kebab→snake: my-tool → my_tool
  - Body returns a string, hash-table, or content vector.
  - Args become lexical variables automatically.
  - Valid types: string, integer, number, boolean, array, object.
    NOT list — use array. Array params arrive as CL vectors.

TESTING TOOLS YOU DEFINED:
  Use test_tool ONCE as a smoke test — it runs a full LLM agent:
    test_tool tools=\"my_tool\" task=\"do something that requires my_tool\"
  Do NOT call test_tool repeatedly for each test case — that wastes API calls.
  For multiple tests, call the handler directly in eval_lisp:
    (pp (my-tool-handler nil nil (make-ht \"arg\" \"hello\" \"nums\" #(1 2 3))))

SIGNALING ERRORS:
  (error 'tool-error :message \"msg\" :category :validation :retryable nil)
  Reader: (mcp-error-message e)  — works on all MCP error types

UTILITIES:
  (make-ht \"k\" v ...)   (encode-json obj)   (decode-json str)
  (pp obj)               ; print any object as JSON (hash-tables, vectors, etc.)
  (ht-keys ht)           ; list of keys
  (ht-values ht)         ; list of values
  (text-content \"t\")    (content-vector items...)")

(defparameter *analyst-prompt*
  "You are a systems analyst. Use shell commands and file reading to inspect,
measure, and analyze. Combine multiple commands in a single shell call using
&& or ; to minimize round-trips. Return structured findings with data.")

(defparameter *test-agent-prompt*
  "You are a test agent. Use the available tools to complete the task. Be concise — return just the result.")

(defparameter *coordinator-prompt*
  "You are a coordinator agent. You delegate complex tasks to specialists.

Specialists:
  ask_analyst     — shell commands + file reading. Use for anything LOCAL:
                    codebase analysis, file inspection, system metrics, git history.
  ask_coder       — Lisp REPL. Use for computation, prototyping, writing code.
  ask_researcher  — web search + file reading. Use ONLY for external/internet
                    information. Do NOT use for local codebase questions.

You also have test_tool to call any registered tool (including tools created
during this session). Use it when the user asks to call a specific tool:
  test_tool tools=\"add_n\" task=\"Add 1, 2 and 3\"

Rules:
1. For local codebase questions, ALWAYS use ask_analyst, never ask_researcher.
2. Do NOT forward the user's full request verbatim. Distill each delegation
   to ONE clear objective with specific constraints.
3. For coding tasks: ask_coder should implement AND test in a single call.
   The coder has test_tool for integration testing. Do NOT send a second
   coder call just to re-test — the second call has no memory of the first.
4. To call a session-created tool, use test_tool — do NOT call it directly.
5. When you have enough information, synthesize and present your final answer.
   1-2 specialist calls usually suffice. Do not over-delegate.")

;;; ---------------------------------------------------------------------------
;;; ANSI color helpers
;;; ---------------------------------------------------------------------------

(defun ansi (code text)
  (format nil "~c[~am~a~c[0m" #\Esc code text #\Esc))

(defun delegate-banner (name task)
  (format t "~%~a ~a~%" (ansi 33 (format nil ">> ~a:" name)) task))

(defun return-banner (name len)
  (format t "~%~a~%" (ansi 32 (format nil "<< ~a returned (~a chars)" name len))))

;;; ---------------------------------------------------------------------------
;;; Delegation tools (registered globally, available to the coordinator)
;;; ---------------------------------------------------------------------------

(define-tool ask-researcher
    ((task string "The research question or information-gathering task" :required t))
  "Delegate a research task to the researcher specialist.
The researcher can search the web and read files. Returns the researcher's findings."
  (:annotations :read-only t)
  (delegate-banner "RESEARCHER" task)
  (let ((result (run-agent task
                           :system *researcher-prompt*
                           :max-iterations *specialist-max-iterations*
                           :allowed-tools '("web_search" "read_file")
                           :thinking-budget *thinking-budget*
                           :reset-tokens nil)))
    (return-banner "RESEARCHER" (length result))
    result))

(define-tool ask-coder
    ((task string "The coding task to solve" :required t))
  "Delegate a coding task to the coder specialist.
The coder has a Lisp REPL (eval_lisp) and can write, test, and debug code.
Returns the solution code and its output."
  (:annotations :destructive t)
  (delegate-banner "CODER" task)
  (let ((result (run-agent task
                           :system *coder-prompt*
                           :max-iterations *specialist-max-iterations*
                           :allowed-tools '("eval_lisp" "clear_repl" "test_tool")
                           :thinking-budget *thinking-budget*
                           :reset-tokens nil)))
    (return-banner "CODER" (length result))
    result))

(define-tool ask-analyst
    ((task string "The analysis or inspection task" :required t))
  "Delegate an analysis task to the analyst specialist.
The analyst can run shell commands and read files. Returns structured findings."
  (:annotations :read-only t)
  (delegate-banner "ANALYST" task)
  (let ((result (run-agent task
                           :system *analyst-prompt*
                           :max-iterations *specialist-max-iterations*
                           :allowed-tools '("shell" "read_file")
                           :thinking-budget *thinking-budget*
                           :reset-tokens nil)))
    (return-banner "ANALYST" (length result))
    result))

(define-tool test-tool
    ((task string "Task that requires using the tool (e.g. \"Add 7, 8 and 9\")" :required t)
     (tools string "Space-separated registered tool names (snake_case)" :required t))
  "Run a test agent with access ONLY to the specified tools. The agent will
attempt to use them based solely on their schema and description — testing the
full MCP contract end-to-end. Returns the agent's final answer."
  (:annotations :destructive t)
  (delegate-banner "TEST-AGENT" task)
  (let* ((tool-names (remove-if (lambda (s) (zerop (length s)))
                                (uiop:split-string tools :separator '(#\Space))))
         (result (run-agent task
                            :system *test-agent-prompt*
                            :allowed-tools tool-names
                            :tool-choice :any
                            :max-iterations 3
                            :reset-tokens nil)))
    (return-banner "TEST-AGENT" (length result))
    result))

;;; ---------------------------------------------------------------------------
;;; Coordinator
;;; ---------------------------------------------------------------------------

(defvar *base-tool-names* nil
  "Tool names present at startup. Tools registered after this are session-created.")

(defun session-tools ()
  "Return names of tools created during this session (not present at startup)."
  (loop for name being the hash-keys of *global-tool-registry*
        unless (member name *base-tool-names* :test #'string=)
          collect name))

(defun run-swarm (task)
  "Run the coordinator agent on TASK. Returns the final synthesized answer."
  (let ((st (session-tools)))
    (format t "~%===== AGENT SWARM =====~%")
    (format t "Task: ~a~%" task)
    (format t "Provider: ~a | Model: ~a~%"
            *provider* (or *model* "default"))
    (format t "Coordinator: ~a iterations max~%"
            *coordinator-max-iterations*)
    (format t "Specialists: ~a iterations max each~%"
            *specialist-max-iterations*)
    (when st
      (format t "Session tools: ~{~a~^, ~}~%" st))
    (format t "========================~%~%")
    (let ((system (if st
                      (format nil "~a~%~%Session tools available via test_tool: ~{~a~^, ~}"
                              *coordinator-prompt* st)
                      *coordinator-prompt*)))
      (run-agent task
                 :system system
                 :max-iterations *coordinator-max-iterations*
                 :allowed-tools '("ask_researcher" "ask_coder" "ask_analyst" "test_tool")
                 :thinking-budget *thinking-budget*
                 :token-budget *token-budget*
                 :call-budget *call-budget*))))

;;; ---------------------------------------------------------------------------
;;; Interactive entry point
;;; ---------------------------------------------------------------------------

(defun sanitize-filename (s)
  "Replace path-unsafe characters for use as a log filename slug."
  (let ((clean (string-downcase (string-trim '(#\Space) (subseq s 0 (min 40 (length s)))))))
    (map 'string (lambda (c)
                   (if (or (alphanumericp c) (char= c #\-))
                       c #\-))
         clean)))

(defvar *history-file*
  (namestring (merge-pathnames ".agent-swarm-history" (user-homedir-pathname))))

(defun main ()
  (unless *api-key*
    (format t "No API key found. Set one of:~%")
    (format t "  ANTHROPIC_API_KEY, GROQ_API_KEY, or OPENAI_API_KEY~%")
    (format t "  Or: (setf mcp-lisp:*api-key* \"...\")~%")
    (sb-ext:exit :code 1))

  ;; Load history from previous sessions
  (rl:read-history *history-file*)

  (format t "~%Agent Swarm ready. Provider: ~a~%" *provider*)
  (format t "Enter a task (or Ctrl-D / Ctrl-C to quit):~%")
  (handler-case
      (loop for line = (rl:readline :prompt (format nil "~a " (ansi 1 "swarm>"))
                                    :add-history t)
            while line
            when (plusp (length (string-trim '(#\Space #\Tab) line)))
              do (rl:write-history *history-file*)
                 (let* ((log-path (format nil "swarm-~a.log" (sanitize-filename line)))
                        (result nil))
                   (handler-case
                       (progn
                         (with-open-file (log-file log-path :direction :output
                                                             :if-exists :supersede
                                                             :external-format :utf-8)
                           (let ((*standard-output* (make-broadcast-stream *standard-output* log-file)))
                             (setf result (run-swarm line))))
                         (format t "~%~%~a~%~a~%~a~%"
                                 (ansi 1 "===== FINAL ANSWER =====")
                                 result
                                 (ansi 1 "========================"))
                         (let ((tok mcp-lisp:*session-tokens*))
                           (format t "~%~a~%"
                                   (ansi 90 (format nil "[Total: ~:d input + ~:d output = ~:d tokens, ~d API calls]"
                                                    (getf tok :input) (getf tok :output)
                                                    (+ (getf tok :input) (getf tok :output))
                                                    (getf tok :requests)))))
                         (format t "(transcript saved to ~a)~%" log-path))
                     (#+sbcl sb-sys:interactive-interrupt #-sbcl condition ()
                       (format t "~%~%~a~%" (ansi 33 "[Interrupted]"))
                       (let ((tok mcp-lisp:*session-tokens*))
                         (format t "~a~%"
                                 (ansi 90 (format nil "[Consumed before interrupt: ~:d tokens, ~d API calls]"
                                                  (+ (getf tok :input) (getf tok :output))
                                                  (getf tok :requests))))))
                     (error (e)
                       (format t "~%~%~a~%" (ansi 31 (format nil "[Error: ~a]" e)))))))
    (#+sbcl sb-sys:interactive-interrupt #-sbcl condition ()
      (format t "~%~%Bye.~%")
      (sb-ext:exit :code 0))))

;; Snapshot tool names before the REPL starts.
;; Anything registered after this point is a session-created tool.
(setf *base-tool-names*
      (loop for name being the hash-keys of *global-tool-registry* collect name))

(main)
