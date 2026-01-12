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
                #:tool-entry-handler)
  (:import-from #:dexador)
  (:export #:*provider*
           #:*api-key*
           #:*model*
           #:*max-tokens*
           #:*verbose*
           #:run-agent
           #:chat))

(in-package #:mcp-lisp/src/agent/agent)

;;; Configuration

(defvar *provider* :groq
  "LLM provider - :groq, :anthropic, or :openai")

(defvar *api-key* (or (uiop:getenv "GROQ_API_KEY")
                      (uiop:getenv "ANTHROPIC_API_KEY")
                      (uiop:getenv "OPENAI_API_KEY"))
  "API key. Set via environment or directly.")

(defvar *model* nil
  "Model to use. If nil, uses provider default.")

(defvar *max-tokens* 4096
  "Maximum tokens for response.")

(defvar *verbose* t
  "Print agent activity to *standard-output*.")

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

(defun tool-to-anthropic-format (tool-entry)
  "Convert an MCP tool-entry to Anthropic tool format."
  (make-ht "name" (tool-entry-name tool-entry)
           "description" (tool-entry-description tool-entry)
           "input_schema" (or (tool-entry-input-schema tool-entry)
                              (make-ht "type" "object" "properties" (make-ht)))))

(defun get-tools-for-provider (&optional (registry *global-tool-registry*))
  "Get all tools in the format expected by current provider."
  (let ((converter (ecase *provider*
                     ((:groq :openai) #'tool-to-openai-format)
                     (:anthropic #'tool-to-anthropic-format))))
    (coerce (mapcar converter (get-all-tools registry))
            'vector)))

;;; LLM API calls

(defun call-openai-compatible (endpoint messages &key tools system)
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
                 tools)))
    (let ((json-body (encode-json body)))
      (multiple-value-bind (response-body status)
          (dex:post endpoint
                    :headers headers
                    :content json-body)
        (unless (= status 200)
          (format *error-output* "~%=== DEBUG: Request that failed ===~%")
          (format *error-output* "Endpoint: ~a~%" endpoint)
          (format *error-output* "Status: ~a~%" status)
          (format *error-output* "Body sent:~%~a~%" json-body)
          (format *error-output* "Response:~%~a~%" response-body)
          (format *error-output* "=================================~%")
          (error "API error (~a): ~a" status response-body))
        (decode-json response-body)))))

(defun call-anthropic (messages &key tools system)
  "Call Anthropic Claude API."
  (let* ((model (or *model* (default-model :anthropic)))
         (body (make-ht "model" model
                        "max_tokens" *max-tokens*
                        "messages" (coerce messages 'vector)))
         (headers `(("x-api-key" . ,*api-key*)
                    ("anthropic-version" . "2023-06-01")
                    ("content-type" . "application/json"))))
    (when system
      (setf (gethash "system" body) system))
    (when (and tools (> (length tools) 0))
      (setf (gethash "tools" body) tools))
    (multiple-value-bind (response-body status)
        (dex:post "https://api.anthropic.com/v1/messages"
                  :headers headers
                  :content (encode-json body))
      (unless (= status 200)
        (error "Claude API error (~a): ~a" status response-body))
      (decode-json response-body))))

(defun call-llm (messages &key tools system)
  "Call LLM based on *provider*."
  (unless *api-key*
    (error "API key not set. Set *api-key* or appropriate environment variable."))
  (ecase *provider*
    ((:groq :openai)
     (call-openai-compatible (api-endpoint *provider*) messages
                             :tools tools :system system))
    (:anthropic
     (call-anthropic messages :tools tools :system system))))

;;; Tool execution

(defun execute-tool (name arguments &optional (registry *global-tool-registry*))
  "Execute tool NAME with ARGUMENTS hash-table. Returns result string."
  (let* ((tool (get-tool name registry))
         (handler (and tool (tool-entry-handler tool))))
    (unless handler
      (return-from execute-tool (format nil "Error: Unknown tool '~a'" name)))
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

(defun process-openai-response (response messages)
  "Process OpenAI/Groq response. Returns (values done-p result updated-messages)."
  (let* ((choice (aref (gethash "choices" response) 0))
         (message (gethash "message" choice))
         (finish-reason (gethash "finish_reason" choice))
         (content (gethash "content" message))
         (tool-calls (gethash "tool_calls" message)))
    ;; If no tool calls or stopped, we're done
    (when (or (null tool-calls) (string= finish-reason "stop"))
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
                 (format t "~%[Tool: ~a]~%" tool-name)
                 (format t "Input: ~a~%" args-json))
               (let ((result (execute-tool tool-name tool-input)))
                 (when *verbose*
                   (format t "Result: ~a~%" result))
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

(defun process-anthropic-response (response messages)
  "Process Anthropic response. Returns (values done-p result updated-messages)."
  (let* ((content (gethash "content" response))
         (stop-reason (gethash "stop_reason" response))
         (tool-uses nil)
         (text-parts nil))
    ;; Collect text and tool uses
    (loop for block across content
          for block-type = (gethash "type" block)
          do (cond
               ((string= block-type "text")
                (push (gethash "text" block) text-parts))
               ((string= block-type "tool_use")
                (push block tool-uses))))
    ;; If no tool use, we're done
    (when (or (null tool-uses) (string= stop-reason "end_turn"))
      (let ((final-text (format nil "~{~a~^~%~}" (nreverse text-parts))))
        (return-from process-anthropic-response
          (values t final-text messages))))
    ;; Print thinking if verbose
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
            (format t "~%[Tool: ~a]~%" tool-name)
            (format t "Input: ~a~%" (encode-json tool-input)))
          (let ((result (execute-tool tool-name tool-input)))
            (when *verbose*
              (format t "Result: ~a~%" result))
            (push (make-ht "type" "tool_result"
                           "tool_use_id" tool-id
                           "content" result)
                  tool-results))))
      ;; Update messages
      (let* ((user-msg (make-ht "role" "user"
                                "content" (coerce (nreverse tool-results) 'vector)))
             (new-messages (append messages (list assistant-msg user-msg))))
        (values nil nil new-messages)))))

(defun process-response (response messages)
  "Process LLM response based on provider."
  (ecase *provider*
    ((:groq :openai)
     (process-openai-response response messages))
    (:anthropic
     (process-anthropic-response response messages))))

(defun run-agent (prompt &key system (max-iterations 10) (registry *global-tool-registry*))
  "Run agent with PROMPT until completion or MAX-ITERATIONS.
Returns the final response text."
  (let ((messages (list (make-ht "role" "user" "content" prompt)))
        (tools (get-tools-for-provider registry)))
    (when *verbose*
      (format t "~%User: ~a~%" prompt)
      (format t "~%[Provider: ~a, Model: ~a]~%" *provider* (or *model* (default-model *provider*)))
      (format t "[Tools available: ~{~a~^, ~}]~%"
              (mapcar #'tool-entry-name (get-all-tools registry))))
    (loop for i from 1 to max-iterations
          do (when *verbose*
               (format t "~%--- Iteration ~a ---~%" i))
             (let ((response (call-llm messages :tools tools :system system)))
               (multiple-value-bind (done-p result new-messages)
                   (process-response response messages)
                 (if done-p
                     (progn
                       (when *verbose*
                         (format t "~%Assistant: ~a~%" result))
                       (return result))
                     (setf messages new-messages))))
          finally (return "Max iterations reached"))))

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
