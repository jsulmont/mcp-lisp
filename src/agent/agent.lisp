;;;; src/agent/agent.lisp
;;;;
;;;; REPL Agent - Run Claude with tools in your Lisp environment.

(defpackage #:mcp-lisp/src/agent/agent
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht
                #:encode-json
                #:decode-json)
  (:import-from #:mcp-lisp/src/primitives/tools/registry
                #:*global-tool-registry*
                #:get-tool
                #:get-all-tools
                #:tool-entry-name
                #:tool-entry-description
                #:tool-entry-input-schema
                #:tool-entry-handler
                #:tool-entry-annotations)
  (:import-from #:mcp-lisp/src/agent/util
                #:read-key-file)
  (:import-from #:dexador)
  (:export #:*provider*
           #:*api-key*
           #:*model*
           #:*max-tokens*
           #:*verbose*
           #:*confirm-destructive*
           #:*tool-search*
           #:*tool-search-keep-loaded*
           #:*tool-search-defer-only*
           #:*transcript*
           #:*last-api-usage*
           #:*session-tokens*
           #:reset-session-tokens
           #:run-agent
           #:filter-registry
           #:chat))

(in-package #:mcp-lisp/src/agent/agent)

;;; Configuration

(defvar *provider* :groq
  "LLM provider - :groq, :anthropic, or :openai")

(defvar *api-key* (or (uiop:getenv "GROQ_API_KEY")
                      (uiop:getenv "ANTHROPIC_API_KEY")
                      (uiop:getenv "OPENAI_API_KEY")
                      (read-key-file ".groq-key")
                      (read-key-file ".anthropic-key")
                      (read-key-file ".openai-key"))
  "API key. Checked in order: env vars (GROQ_API_KEY, ANTHROPIC_API_KEY,
OPENAI_API_KEY), then key files (~/.groq-key, ~/.anthropic-key, ~/.openai-key).")

(defvar *model* nil
  "Model to use. If nil, uses provider default.")

(defvar *max-tokens* 4096
  "Maximum tokens for response.")

(defvar *verbose* t
  "Print agent activity to *standard-output*.")

(defvar *tool-search* nil
  "Anthropic-only. When non-nil, send the server-side tool search tool and defer
loading of registry tool definitions, so only the search tool and any
*tool-search-keep-loaded* tools enter the model's context up front. Value
selects the variant: :regex (Claude writes regex patterns) or :bm25 (natural
language queries). nil disables tool search.")

(defvar *tool-search-keep-loaded* nil
  "List of tool name strings to keep loaded up front (non-deferred) when
*tool-search* is enabled. All other tools are deferred and discovered on demand
via search. The search tool itself is always non-deferred.")

(defvar *tool-search-defer-only* nil
  "When *tool-search* is enabled and this is a non-empty list of tool name
strings, defer ONLY those tools and load every other tool up front. Takes
precedence over *tool-search-keep-loaded*. nil falls back to keep-loaded
semantics (defer everything except keep-loaded).")

(defvar *transcript* nil
  "When set to an output stream, run-agent writes a structured conversation
transcript to it: the system prompt, each user/assistant turn with its
stop_reason / finish_reason, tool calls (name + input), tool-search queries, and
tool results. nil disables. Independent of *verbose*.")

(defun tlog (fmt &rest args)
  "Write a line to the transcript stream if *transcript* is set."
  (when *transcript*
    (apply #'format *transcript* fmt args)
    (force-output *transcript*)))

;;; API usage tracking

(defvar *last-api-usage* nil
  "Plist with usage info from the last API call.
Keys: :input-tokens, :output-tokens, and when available:
:cache-creation-tokens, :cache-read-tokens,
:rate-limit-tokens-remaining, :rate-limit-tokens-reset,
:rate-limit-requests-remaining.")

(defvar *session-tokens* (list :input 0 :output 0 :requests 0)
  "Accumulated token counts across API calls. Reset with reset-session-tokens.
Not thread-safe — concurrent run-agent calls will clobber each other.")

(defun reset-session-tokens ()
  "Reset accumulated session token counts."
  (setf *session-tokens* (list :input 0 :output 0 :requests 0)))

(defun record-usage (response headers)
  "Extract and record token usage from API response and rate-limit headers."
  (unless (hash-table-p response)
    (return-from record-usage))
  (let ((usage (gethash "usage" response)))
    (when usage
      (let ((in-tok (or (gethash "input_tokens" usage)
                        (gethash "prompt_tokens" usage)
                        0))
            (out-tok (or (gethash "output_tokens" usage)
                         (gethash "completion_tokens" usage)
                         0))
            (cache-create (gethash "cache_creation_input_tokens" usage))
            (cache-read (gethash "cache_read_input_tokens" usage)))
        (setf *last-api-usage*
              (list :input-tokens in-tok :output-tokens out-tok))
        (when cache-create
          (setf (getf *last-api-usage* :cache-creation-tokens) cache-create))
        (when cache-read
          (setf (getf *last-api-usage* :cache-read-tokens) cache-read))
        (incf (getf *session-tokens* :input) in-tok)
        (incf (getf *session-tokens* :output) out-tok)
        (incf (getf *session-tokens* :requests)))))
  ;; Rate-limit headers (Anthropic and OpenAI conventions)
  (when headers
    (flet ((hdr (key) (gethash key headers)))
      (let ((tok-remaining (or (hdr "anthropic-ratelimit-tokens-remaining")
                               (hdr "x-ratelimit-remaining-tokens")))
            (tok-reset (or (hdr "anthropic-ratelimit-tokens-reset")
                           (hdr "x-ratelimit-reset-tokens")))
            (req-remaining (or (hdr "anthropic-ratelimit-requests-remaining")
                               (hdr "x-ratelimit-remaining-requests"))))
        (when tok-remaining
          (setf (getf *last-api-usage* :rate-limit-tokens-remaining)
                (ignore-errors (parse-integer tok-remaining))))
        (when tok-reset
          (setf (getf *last-api-usage* :rate-limit-tokens-reset) tok-reset))
        (when req-remaining
          (setf (getf *last-api-usage* :rate-limit-requests-remaining)
                (ignore-errors (parse-integer req-remaining)))))))
  ;; Verbose output
  (when (and *verbose* *last-api-usage*)
    (let ((cache-read (getf *last-api-usage* :cache-read-tokens))
          (cache-create (getf *last-api-usage* :cache-creation-tokens)))
      (format t "[Tokens: ~:d in, ~:d out~a | Session: ~:d in, ~:d out~a]~%"
              (getf *last-api-usage* :input-tokens 0)
              (getf *last-api-usage* :output-tokens 0)
              (cond ((and cache-read (plusp cache-read))
                     (format nil " (cache hit: ~:d)" cache-read))
                    ((and cache-create (plusp cache-create))
                     (format nil " (cache write: ~:d)" cache-create))
                    (t ""))
              (getf *session-tokens* :input)
              (getf *session-tokens* :output)
              (let ((remaining (getf *last-api-usage* :rate-limit-tokens-remaining)))
                (if remaining
                    (format nil " | ~:d tokens remaining" remaining)
                    ""))))))

;;; Provider configuration

(defun default-model (provider)
  (ecase provider
    (:groq "meta-llama/llama-4-maverick-17b-128e-instruct")
    (:anthropic "claude-sonnet-4-20250514")
    (:openai "gpt-4o")))

(defun api-endpoint (provider)
  (ecase provider
    (:groq "https://api.groq.com/openai/v1/chat/completions")
    (:anthropic "https://api.anthropic.com/v1/messages")
    (:openai "https://api.openai.com/v1/chat/completions")))

;;; Tool conversion (MCP format -> LLM format)

(defun tool-to-openai-format (tool-entry)
  "Convert an MCP tool-entry to OpenAI/Groq function format."
  (make-ht "name" (tool-entry-name tool-entry)
           "description" (tool-entry-description tool-entry)
           "parameters" (or (tool-entry-input-schema tool-entry)
                            (make-ht "type" "object" "properties" (make-ht)))))

(defun tool-to-anthropic-format (tool-entry &optional defer)
  "Convert an MCP tool-entry to Anthropic tool format.
When DEFER is true, mark the tool defer_loading so it stays out of context until
the model discovers it via tool search."
  (let ((ht (make-ht "name" (tool-entry-name tool-entry)
                     "description" (tool-entry-description tool-entry)
                     "input_schema" (or (tool-entry-input-schema tool-entry)
                                        (make-ht "type" "object" "properties" (make-ht))))))
    (when defer
      (setf (gethash "defer_loading" ht) t))
    ht))

(defun tool-search-entry ()
  "The server-side tool search tool definition for the current *tool-search*."
  (ecase *tool-search*
    (:regex (make-ht "type" "tool_search_tool_regex_20251119"
                     "name" "tool_search_tool_regex"))
    (:bm25 (make-ht "type" "tool_search_tool_bm25_20251119"
                    "name" "tool_search_tool_bm25"))))

(defun defer-tool-p (name)
  "Whether tool NAME should be deferred under the current tool-search config.
*tool-search-defer-only*, when set, names exactly the tools to defer; otherwise
everything except *tool-search-keep-loaded* is deferred."
  (if *tool-search-defer-only*
      (and (member name *tool-search-defer-only* :test #'string=) t)
      (not (member name *tool-search-keep-loaded* :test #'string=))))

(defun tools-for-anthropic (registry)
  "Build the Anthropic tools array, honoring *tool-search*.
When tool search is enabled, tools are deferred per DEFER-TOOL-P and the search
tool is appended last (non-deferred, so it satisfies the API's at-least-one-loaded
requirement and is safe to mark cacheable)."
  (let ((entries (get-all-tools registry)))
    (if *tool-search*
        (progn
          (when (and *tool-search-defer-only* *tool-search-keep-loaded*)
            (warn "Both *tool-search-defer-only* and *tool-search-keep-loaded* are ~
set; *tool-search-keep-loaded* is ignored (defer-only takes precedence)."))
          (let ((deferred (map 'list
                               (lambda (e)
                                 (tool-to-anthropic-format
                                  e (defer-tool-p (tool-entry-name e))))
                               entries)))
            (coerce (append deferred (list (tool-search-entry))) 'vector)))
        (map 'vector #'tool-to-anthropic-format entries))))

(defun get-tools-for-provider (&optional (registry *global-tool-registry*))
  "Get all tools in the format expected by current provider."
  (ecase *provider*
    ((:groq :openai)
     (map 'vector #'tool-to-openai-format (get-all-tools registry)))
    (:anthropic (tools-for-anthropic registry))))

;;; LLM API calls

(defun call-with-retry (fn &key (max-retries 3) (initial-delay 2))
  "Call FN, retrying on HTTP 429/529 with exponential backoff.
FN should return (values body status headers) like dex:post.
Handles both status-code returns and dexador condition signals."
  (loop for attempt from 0
        for delay = initial-delay then (* delay 2)
        do (handler-case
               (multiple-value-bind (body status headers)
                   (funcall fn)
                 (if (and (member status '(429 529)) (< attempt max-retries))
                     (let ((retry-after (ignore-errors
                                          (parse-integer
                                           (or (gethash "retry-after" headers) "")))))
                       (when *verbose*
                         (format t "[Rate limited (~a), waiting ~as~@[ (retry-after: ~as)~]]~%"
                                 status (or retry-after delay) retry-after))
                       (sleep (or retry-after delay)))
                     (return (values body status headers))))
             (dexador.error:http-request-failed (e)
               (let ((status (dexador.error:response-status e)))
                 (if (and (member status '(429 529)) (< attempt max-retries))
                     (let ((retry-after (ignore-errors
                                          (parse-integer
                                           (or (gethash "retry-after"
                                                        (dexador.error:response-headers e)) "")))))
                       (when *verbose*
                         (format t "[Rate limited (~a), waiting ~as~@[ (retry-after: ~as)~]]~%"
                                 status (or retry-after delay) retry-after))
                       (sleep (or retry-after delay)))
                     (error e)))))))

(defun tool-choice-for-openai (choice)
  "Convert unified tool-choice to OpenAI/Groq format."
  (etypecase choice
    (null nil)
    (keyword (ecase choice
               (:auto "auto")
               (:any "required")
               (:none "none")))
    (string (make-ht "type" "function"
                     "function" (make-ht "name" choice)))))

(defun tool-choice-for-anthropic (choice)
  "Convert unified tool-choice to Anthropic format."
  (etypecase choice
    (null nil)
    (keyword (ecase choice
               (:auto (make-ht "type" "auto"))
               (:any (make-ht "type" "any"))
               (:none nil)))
    (string (make-ht "type" "tool" "name" choice))))

(defun call-openai-compatible (endpoint messages &key tools system tool-choice)
  "Call OpenAI-compatible API (Groq, OpenAI)."
  (let* ((model (or *model* (default-model *provider*)))
         (body (make-ht "model" model
                        "max_tokens" *max-tokens*
                        "messages" (coerce
                                    (if system
                                        (cons (make-ht "role" "system" "content" system)
                                              messages)
                                        messages)
                                    'vector)))
         (headers `(("Authorization" . ,(format nil "Bearer ~a" *api-key*))
                    ("Content-Type" . "application/json"))))
    (when (and tools (> (length tools) 0))
      (setf (gethash "tools" body)
            (map 'vector (lambda (tool)
                           (make-ht "type" "function"
                                    "function" tool))
                 tools))
      (let ((tc (tool-choice-for-openai tool-choice)))
        (when tc (setf (gethash "tool_choice" body) tc))))
    (let ((json-body (encode-json body)))
      (multiple-value-bind (response-body status response-headers)
          (call-with-retry
           (lambda () (dex:post endpoint
                                :headers headers
                                :content json-body)))
        (unless (= status 200)
          (error "API error (~a): ~a" status response-body))
        (let ((response (decode-json response-body)))
          (record-usage response response-headers)
          response)))))

(defun cacheable-system (system)
  "Wrap a system prompt string in a content block array with cache_control."
  (vector (make-ht "type" "text"
                   "text" system
                   "cache_control" (make-ht "type" "ephemeral"))))

(defun mark-last-tool-cacheable (tools)
  "Add cache_control to the last tool definition. Mutates the tool hash-table."
  (when (> (length tools) 0)
    (setf (gethash "cache_control" (aref tools (1- (length tools))))
          (make-ht "type" "ephemeral")))
  tools)

(defun call-anthropic (messages &key tools system tool-choice thinking-budget)
  "Call Anthropic Claude API with prompt caching and optional extended thinking."
  (let* ((model (or *model* (default-model :anthropic)))
         (body (make-ht "model" model
                        "max_tokens" *max-tokens*
                        "messages" (coerce messages 'vector)))
         (headers `(("x-api-key" . ,*api-key*)
                    ("anthropic-version" . "2023-06-01")
                    ("content-type" . "application/json"))))
    (when thinking-budget
      (setf (gethash "thinking" body)
            (make-ht "type" "enabled" "budget_tokens" thinking-budget))
      (setf (gethash "temperature" body) 1))
    (when system
      (setf (gethash "system" body) (cacheable-system system)))
    (when (and tools (> (length tools) 0))
      (setf (gethash "tools" body) (mark-last-tool-cacheable tools))
      ;; tool_choice is incompatible with extended thinking
      (unless thinking-budget
        (let ((tc (tool-choice-for-anthropic tool-choice)))
          (when tc (setf (gethash "tool_choice" body) tc)))))
    (let ((json-content (encode-json body)))
      (multiple-value-bind (response-body status response-headers)
          (call-with-retry
           (lambda () (dex:post "https://api.anthropic.com/v1/messages"
                                :headers headers
                                :content json-content)))
        (unless (= status 200)
          (error "Claude API error (~a): ~a" status response-body))
        (let ((response (decode-json response-body)))
          (record-usage response response-headers)
          response)))))

(defun call-llm (messages &key tools system tool-choice thinking-budget)
  "Call LLM based on *provider*.
When TOOL-CHOICE is :none, tools are omitted entirely.
THINKING-BUDGET: Anthropic-only, enables extended thinking with this token budget."
  (unless *api-key*
    (error "API key not set. Set *api-key*, env var, or key file (~~/.anthropic-key etc)."))
  (let ((effective-tools (if (eq tool-choice :none) nil tools)))
    (ecase *provider*
      ((:groq :openai)
       (call-openai-compatible (api-endpoint *provider*) messages
                               :tools effective-tools :system system
                               :tool-choice (unless (eq tool-choice :none) tool-choice)))
      (:anthropic
       (call-anthropic messages :tools effective-tools :system system
                                :tool-choice (unless (eq tool-choice :none) tool-choice)
                                :thinking-budget thinking-budget)))))

;;; Tool execution

(defvar *confirm-destructive* nil
  "When non-nil, a function (name arguments) → boolean that gates destructive tool calls.
Return T to allow, NIL to deny.")

(defun tool-read-only-p (tool)
  "Return T if tool has readOnlyHint annotation set to true."
  (let ((annotations (tool-entry-annotations tool)))
    (and annotations (gethash "readOnlyHint" annotations))))

(defun execute-tool (name arguments &optional (registry *global-tool-registry*))
  "Execute tool NAME with ARGUMENTS hash-table. Returns result string.
When *confirm-destructive* is set, non-read-only tools require confirmation."
  (let* ((tool (get-tool name registry))
         (handler (and tool (tool-entry-handler tool))))
    (unless handler
      (return-from execute-tool (format nil "Error: Unknown tool '~a'" name)))
    ;; Gate destructive tools
    (when (and *confirm-destructive*
               (not (tool-read-only-p tool)))
      (unless (funcall *confirm-destructive* name arguments)
        (return-from execute-tool
          (format nil "Denied: user declined to run ~a" name))))
    (handler-case
        (let ((result (funcall handler nil nil arguments)))
          ;; Handler returns content-vector, extract text
          (if (and (vectorp result) (> (length result) 0))
              (let ((first-content (aref result 0)))
                (or (gethash "text" first-content)
                    (encode-json first-content)))
              (princ-to-string result)))
      (error (e)
        (format nil "Error executing ~a: ~a" name e)))))

;;; Agent loop - Response processing

(defun process-openai-response (response messages registry)
  "Process OpenAI/Groq response. Returns (values done-p result updated-messages).
Uses finish_reason as the canonical loop control signal:
  - \"tool_calls\": execute requested tools and continue
  - \"stop\": return final response to user"
  (let* ((choice (aref (gethash "choices" response) 0))
         (message (gethash "message" choice))
         (finish-reason (gethash "finish_reason" choice))
         (content (gethash "content" message))
         (tool-calls (gethash "tool_calls" message)))
    ;; Transcript: assistant turn with its finish_reason and content.
    (when *transcript*
      (tlog "~%[assistant] (finish_reason: ~a)~%" finish-reason)
      (when content (tlog "~a~%" content))
      (loop for tc across (or tool-calls #())
            for func = (gethash "function" tc)
            do (tlog "  -> tool_call ~a ~a~%"
                     (gethash "name" func) (gethash "arguments" func))))
    ;; finish_reason is the canonical signal
    (when (string/= finish-reason "tool_calls")
      (when (equal finish-reason "length")
        (warn "Agent stopped with finish_reason \"length\"; output truncated."))
      (return-from process-openai-response
        (values t (or content "") messages)))
    ;; Print thinking if verbose
    (when (and *verbose* content)
      (format t "~%~a~%" content))
    ;; Execute tools
    (let ((tool-results nil))
      (loop for tool-call across tool-calls
            for tool-id = (gethash "id" tool-call)
            for func = (gethash "function" tool-call)
            for tool-name = (gethash "name" func)
            for args-json = (gethash "arguments" func)
            for tool-input = (decode-json args-json)
            do (when *verbose*
                 (format t "~%~c[36m[Tool: ~a]~c[0m~%" #\Esc tool-name #\Esc)
                 (format t "Input: ~a~%" args-json))
               (let ((result (execute-tool tool-name tool-input registry)))
                 (when *verbose*
                   (format t "Result: ~a~%" result))
                 (tlog "  <- tool_result ~a: ~a~%" tool-name result)
                 (push (make-ht "role" "tool"
                                "tool_call_id" tool-id
                                "content" result)
                       tool-results)))
      ;; Update messages
      (let ((assistant-msg (make-ht "role" "assistant"
                                    "tool_calls" tool-calls)))
        ;; Only add content if present (OpenAI allows null/omitted content with tool_calls)
        (when content
          (setf (gethash "content" assistant-msg) content))
        (let ((new-messages (append messages
                                    (list assistant-msg)
                                    (nreverse tool-results))))
          (values nil nil new-messages))))))

(defun process-anthropic-response (response messages registry)
  "Process Anthropic response. Returns (values done-p result updated-messages).
Uses stop_reason as the canonical loop control signal:
  - \"tool_use\": execute requested tools and continue
  - \"end_turn\": return final response to user"
  (let* ((content (gethash "content" response))
         (stop-reason (gethash "stop_reason" response))
         (tool-uses nil)
         (text-parts nil))
    ;; Transcript header before the blocks, then log each block in its real
    ;; array order (text / tool_search / tool_use interleave as the model emits
    ;; them) — collecting-then-printing would reorder them.
    (tlog "~%[assistant] (stop_reason: ~a)~%" stop-reason)
    ;; Collect text, tool uses, and thinking blocks
    (loop for block across content
          for block-type = (gethash "type" block)
          do (cond
               ((string= block-type "text")
                (push (gethash "text" block) text-parts)
                (tlog "~a~%" (gethash "text" block)))
               ((string= block-type "tool_use")
                (push block tool-uses)
                (tlog "  -> tool_use ~a ~a~%"
                      (gethash "name" block) (encode-json (gethash "input" block))))
               ((string= block-type "server_tool_use")
                (tlog "  ~~ tool_search ~a~%" (encode-json (gethash "input" block)))
                (when *verbose*
                  (format t "~%~c[35m[Tool search: ~a]~c[0m~%"
                          #\Esc (encode-json (gethash "input" block)) #\Esc)))
               ((string= block-type "tool_search_tool_result")
                (let ((c (gethash "content" block)))
                  (when (hash-table-p c)
                    (let ((refs (gethash "tool_references" c)))
                      (when refs
                        (tlog "  ~~ tool_search found: ~{~a~^, ~}~%"
                              (map 'list (lambda (r) (gethash "tool_name" r)) refs)))))))
               ((string= block-type "thinking")
                (when *verbose*
                  (let ((thinking (gethash "thinking" block)))
                    (when thinking
                      (format t "~%~c[90m[Thinking: ~a chars]~c[0m~%"
                              #\Esc (length thinking) #\Esc)))))))
    ;; Dispatch on stop_reason (tool_use falls through to execution below):
    ;;  - pause_turn: a server-side tool loop (e.g. tool search) hit its
    ;;    iteration cap. Resume by re-sending the assistant turn unchanged, with
    ;;    NO new user message — the API detects the trailing server_tool_use and
    ;;    continues. Terminating here would drop the turn with partial/empty text.
    ;;  - max_tokens / refusal: terminal but lossy — surface it instead of
    ;;    silently returning a truncated/empty answer as success.
    ;;  - end_turn / stop_sequence / anything else: terminal, return final text.
    (cond
      ((string= stop-reason "tool_use"))    ; fall through to tool execution
      ((string= stop-reason "pause_turn")
       (when *verbose*
         (format t "~%[pause_turn: resuming server-side tool loop]~%"))
       (tlog "  ~~ pause_turn — resuming~%")
       (return-from process-anthropic-response
         (values nil nil
                 (append messages
                         (list (make-ht "role" "assistant" "content" content))))))
      (t
       (when (member stop-reason '("max_tokens" "refusal") :test #'string=)
         (warn "Agent stopped with stop_reason ~s; output may be incomplete or refused."
               stop-reason)
         (when *verbose*
           (format t "~%[stop_reason: ~a — output may be incomplete]~%" stop-reason)))
       (let ((final-text (format nil "~{~a~^~%~}" (nreverse text-parts))))
         (return-from process-anthropic-response
           (values t final-text messages)))))
    ;; Print text content if verbose
    (when (and *verbose* text-parts)
      (format t "~%~a~%" (format nil "~{~a~^~%~}" (nreverse text-parts))))
    ;; Execute tools and build tool results
    (let ((assistant-msg (make-ht "role" "assistant" "content" content))
          (tool-results nil))
      (dolist (tool-use (nreverse tool-uses))
        (let* ((tool-id (gethash "id" tool-use))
               (tool-name (gethash "name" tool-use))
               (tool-input (gethash "input" tool-use)))
          (when *verbose*
            (format t "~%~c[36m[Tool: ~a]~c[0m~%" #\Esc tool-name #\Esc)
            (format t "Input: ~a~%" (encode-json tool-input)))
          (let ((result (execute-tool tool-name tool-input registry)))
            (when *verbose*
              (format t "Result: ~a~%" result))
            (tlog "  <- tool_result ~a: ~a~%" tool-name result)
            (push (make-ht "type" "tool_result"
                           "tool_use_id" tool-id
                           "content" result)
                  tool-results))))
      ;; Update messages
      (let* ((user-msg (make-ht "role" "user"
                                "content" (coerce (nreverse tool-results) 'vector)))
             (new-messages (append messages (list assistant-msg user-msg))))
        (values nil nil new-messages)))))

(defun process-response (response messages registry)
  "Process LLM response based on provider. Tools are executed against REGISTRY."
  (ecase *provider*
    ((:groq :openai)
     (process-openai-response response messages registry))
    (:anthropic
     (process-anthropic-response response messages registry))))

(defun filter-registry (allowed-tools &optional (source *global-tool-registry*))
  "Create a new registry containing only ALLOWED-TOOLS from SOURCE."
  (let ((filtered (make-hash-table :test #'equal)))
    (dolist (name allowed-tools filtered)
      (let ((entry (gethash name source)))
        (when entry
          (setf (gethash name filtered) entry))))))

(defun session-tokens-used ()
  (+ (getf *session-tokens* :input) (getf *session-tokens* :output)))

(defun run-agent (prompt &key system (max-iterations 10) (registry *global-tool-registry*)
                            allowed-tools tool-choice token-budget call-budget
                            thinking-budget (reset-tokens t))
  "Run agent with PROMPT until completion or MAX-ITERATIONS.
ALLOWED-TOOLS: list of tool name strings to expose.
TOOL-CHOICE: controls tool selection on the first LLM call —
  :auto, :any, :none, or a tool name string. Reverts to :auto after.
TOKEN-BUDGET: max total tokens before forcing synthesis. When 85% consumed,
  tools are stripped and the model must synthesize with what it has.
CALL-BUDGET: max total LLM API calls (across all nested agents). Uses the
  global session request counter, so nested agents count against the same budget.
THINKING-BUDGET: Anthropic-only. When set, enables extended thinking with this
  many tokens of thinking budget per API call.
RESET-TOKENS: if nil, preserves the running token count (for nested agents)."
  (when reset-tokens (reset-session-tokens))
  (let* ((effective-registry (if allowed-tools
                                 (filter-registry allowed-tools registry)
                                 registry))
         (messages (list (make-ht "role" "user" "content" prompt)))
         (tools (get-tools-for-provider effective-registry))
         (current-tool-choice tool-choice))
    (when *verbose*
      (format t "~%User: ~a~%" prompt)
      (format t "~%[Provider: ~a, Model: ~a]~%" *provider* (or *model* (default-model *provider*)))
      (format t "[Tools available: ~{~a~^, ~}]~%"
              (mapcar #'tool-entry-name (get-all-tools effective-registry))))
    (when *transcript*
      (tlog "~&========== AGENT TRANSCRIPT ==========~%")
      (tlog "[meta] provider=~a model=~a tool_search=~a tools=~d~%"
            *provider* (or *model* (default-model *provider*)) *tool-search*
            (length (get-all-tools effective-registry)))
      (when system (tlog "~%[system]~%~a~%" system))
      (tlog "~%[user]~%~a~%" prompt))
    (loop for i from 1 to max-iterations
          for token-exceeded = (and token-budget
                                    (> (session-tokens-used) (* token-budget 0.85)))
          for calls-exceeded = (and call-budget
                                    (>= (getf *session-tokens* :requests)
                                         (1- call-budget)))
          for winding-down = (or token-exceeded
                                 calls-exceeded
                                 (= i (1- max-iterations)))
          do (when *verbose*
               (format t "~%--- Iteration ~a ---~%" i)
               (when winding-down
                 (format t "[Wind-down: ~a]~%"
                         (cond (token-exceeded "token budget")
                               (calls-exceeded "call budget")
                               (t "final iteration")))))
             ;; On wind-down, strip tools and inject synthesis instruction
             (when (and winding-down (not (eq current-tool-choice :none)))
               (setf current-tool-choice :none)
               (tlog "~%[user] (wind-down: ~a) Synthesize your final answer now.~%"
                     (cond (token-exceeded "token budget")
                           (calls-exceeded "call budget")
                           (t "final iteration")))
               (setf messages
                     (append messages
                             (list (make-ht "role" "user"
                                            "content" "Synthesize your final answer now with what you have. Do not request more information.")))))
             (let ((response (call-llm messages :tools tools :system system
                                                :tool-choice current-tool-choice
                                                :thinking-budget thinking-budget)))
               (when (and current-tool-choice (not (eq current-tool-choice :none)))
                 (setf current-tool-choice nil))
               (multiple-value-bind (done-p result new-messages)
                   (process-response response messages effective-registry)
                 (if done-p
                     (progn
                       (when *verbose*
                         (format t "~%Assistant: ~a~%" result))
                       (tlog "~%========== END (~d iteration~:p) ==========~%" i)
                       (return result))
                     (setf messages new-messages))))
          finally (tlog "~%========== END (max iterations) ==========~%")
                  (return "Max iterations reached"))))

;;; Convenience function

(defun chat (prompt &key system)
  "Simple chat without tools."
  (let* ((messages (list (make-ht "role" "user" "content" prompt)))
         (response (call-llm messages :system system)))
    (ecase *provider*
      ((:groq :openai)
       (let* ((choice (aref (gethash "choices" response) 0))
              (message (gethash "message" choice)))
         (gethash "content" message)))
      (:anthropic
       (let ((content (gethash "content" response)))
         (when (and content (> (length content) 0))
           (gethash "text" (aref content 0))))))))
