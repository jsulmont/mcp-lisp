;;;; src/server/tool-context.lisp
;;;;
;;;; Tool execution context — gives tool handlers a transport-agnostic way to
;;;; report progress and make server->client requests (sampling, elicitation).
;;;;
;;;; The transport binds *stream-notify-fn* / *stream-call-fn* (how to talk back
;;;; to the client); the dispatcher composes them with the request's progress
;;;; token into *tool-context* around each tool handler call. Handlers call the
;;;; exported helpers, which read *tool-context* — no transport coupling.

(defpackage #:mcp-lisp/src/server/tool-context
  (:use #:cl)
  (:import-from #:mcp-lisp/src/server/progress
                #:send-progress)
  (:import-from #:mcp-lisp/src/server/sampling
                #:create-message)
  (:import-from #:mcp-lisp/src/server/elicitation
                #:elicit-form
                #:elicit-url)
  (:export #:*tool-context*
           #:*stream-notify-fn*
           #:*stream-call-fn*
           #:make-tool-context
           #:tool-context
           #:tool-context-notify-fn
           #:tool-context-call-fn
           #:tool-context-progress-token
           #:tool-streaming-available-p
           #:tool-report-progress
           #:tool-sample
           #:tool-elicit-form
           #:tool-elicit-url))

(in-package #:mcp-lisp/src/server/tool-context)

;;; Channel back to the client, bound by the transport for the current request.
;;; Both NIL on transports/paths that can't carry server->client messaging
;;; (stdio, the Woo non-streaming path).
(defvar *stream-notify-fn* nil
  "Function (method params) that delivers a notification to the client, or NIL.")
(defvar *stream-call-fn* nil
  "Function (method params &key timeout) that issues a server->client request
and returns its result, or NIL.")

(defstruct tool-context
  "Per-tool-call context: how to reach the client plus the request's progress token."
  (notify-fn nil)
  (call-fn nil)
  (progress-token nil))

(defvar *tool-context* nil
  "Bound by the dispatcher to a TOOL-CONTEXT for the duration of a tool handler.")

(defun tool-streaming-available-p ()
  "Return T if the current transport can carry server->client requests
(sampling / elicitation) for this tool call."
  (and *tool-context* (tool-context-call-fn *tool-context*) t))

(defun tool-report-progress (progress &key total message)
  "Report progress for the current tool call. No-op if the client supplied no
progress token or the transport can't deliver notifications."
  (when *tool-context*
    (send-progress (tool-context-notify-fn *tool-context*)
                   (tool-context-progress-token *tool-context*)
                   progress
                   :total total
                   :message message)))

(defun require-call-fn (what)
  "Return the current server->client call function, or signal if unavailable."
  (or (and *tool-context* (tool-context-call-fn *tool-context*))
      (error "~a requires a streaming transport; the current transport cannot ~
make server->client requests." what)))

(defun tool-sample (messages &rest args
                    &key system-prompt max-tokens model-preferences
                         include-context stop-sequences temperature)
  "Request an LLM completion from the client (sampling/createMessage).
MESSAGES is a list of sampling messages (see MAKE-SAMPLING-MESSAGE)."
  (declare (ignore system-prompt max-tokens model-preferences
                   include-context stop-sequences temperature))
  (apply #'create-message (require-call-fn "tool-sample") messages args))

(defun tool-elicit-form (message requested-schema)
  "Request structured data from the user (elicitation/create, form mode).
Returns (values action content)."
  (elicit-form (require-call-fn "tool-elicit-form") message requested-schema))

(defun tool-elicit-url (message url elicitation-id)
  "Direct the user to URL for out-of-band interaction (elicitation/create, url mode).
Returns the action string."
  (elicit-url (require-call-fn "tool-elicit-url") message url elicitation-id))
