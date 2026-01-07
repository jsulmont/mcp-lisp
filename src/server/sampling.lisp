;;;; src/server/sampling.lisp
;;;;
;;;; Server-initiated LLM sampling (completion requests to client).

(defpackage #:mcp-lisp/src/server/sampling
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/content
                #:text-content)
  (:export #:create-message
           #:make-sampling-message
           #:make-model-preferences))

(in-package #:mcp-lisp/src/server/sampling)

(defun make-sampling-message (role content-text)
  "Create a sampling message hash-table.
ROLE is \"user\" or \"assistant\".
CONTENT-TEXT is the message text."
  (make-ht "role" role
           "content" (text-content content-text)))

(defun make-model-preferences (&key hints cost-priority speed-priority intelligence-priority)
  "Create model preferences hash-table.
HINTS is a list of model name hints (strings).
COST-PRIORITY, SPEED-PRIORITY, INTELLIGENCE-PRIORITY are 0-1 floats."
  (let ((prefs (make-ht)))
    (when hints
      (setf (gethash "hints" prefs)
            (coerce (mapcar (lambda (name) (make-ht "name" name)) hints)
                    'vector)))
    (when cost-priority
      (setf (gethash "costPriority" prefs) cost-priority))
    (when speed-priority
      (setf (gethash "speedPriority" prefs) speed-priority))
    (when intelligence-priority
      (setf (gethash "intelligencePriority" prefs) intelligence-priority))
    prefs))

(defun create-message (call-fn messages &key system-prompt max-tokens
                                              model-preferences include-context
                                              stop-sequences temperature)
  "Request an LLM completion from the client.
CALL-FN is a function that accepts (method params) and returns the result.
MESSAGES is a list of message hash-tables (use make-sampling-message).
Returns the completion result or signals an error.

Optional parameters:
  SYSTEM-PROMPT - System prompt string
  MAX-TOKENS - Maximum tokens to generate
  MODEL-PREFERENCES - Model preferences (use make-model-preferences)
  INCLUDE-CONTEXT - Context inclusion setting (\"none\", \"thisServer\", \"allServers\")
  STOP-SEQUENCES - List of stop sequences
  TEMPERATURE - Sampling temperature (0-1)"
  (unless call-fn
    (error "No call function available for sampling"))
  (let ((params (make-ht "messages" (coerce messages 'vector))))
    (when system-prompt
      (setf (gethash "systemPrompt" params) system-prompt))
    (when max-tokens
      (setf (gethash "maxTokens" params) max-tokens))
    (when model-preferences
      (setf (gethash "modelPreferences" params) model-preferences))
    (when include-context
      (setf (gethash "includeContext" params) include-context))
    (when stop-sequences
      (setf (gethash "stopSequences" params) (coerce stop-sequences 'vector)))
    (when temperature
      (setf (gethash "temperature" params) temperature))
    (funcall call-fn "sampling/createMessage" params)))
