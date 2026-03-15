;;;; src/server/elicitation.lisp
;;;;
;;;; Server-initiated elicitation (requesting information from users via client).
;;;; MCP 2025-11-25 feature.

(defpackage #:mcp-lisp/src/server/elicitation
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:export #:elicit-form
           #:elicit-url))

(in-package #:mcp-lisp/src/server/elicitation)

(defun elicit-form (call-fn message requested-schema)
  "Request structured data from the user via the client.
CALL-FN is a function that accepts (method params) and returns the result.
MESSAGE is a human-readable string explaining why the interaction is needed.
REQUESTED-SCHEMA is a JSON Schema hash-table defining the expected response.
Returns (values action content) where ACTION is \"accept\", \"decline\", or \"cancel\"."
  (unless call-fn
    (error "No call function available for elicitation"))
  (let* ((params (make-ht "mode" "form"
                          "message" message
                          "requestedSchema" requested-schema))
         (result (funcall call-fn "elicitation/create" params)))
    (values (gethash "action" result)
            (gethash "content" result))))

(defun elicit-url (call-fn message url elicitation-id)
  "Direct the user to an external URL for out-of-band interaction.
CALL-FN is a function that accepts (method params) and returns the result.
MESSAGE is a human-readable string explaining why.
URL is the URL the user should navigate to.
ELICITATION-ID is a unique identifier for this elicitation.
Returns the action string (\"accept\", \"decline\", or \"cancel\")."
  (unless call-fn
    (error "No call function available for elicitation"))
  (let* ((params (make-ht "mode" "url"
                          "message" message
                          "url" url
                          "elicitationId" elicitation-id))
         (result (funcall call-fn "elicitation/create" params)))
    (gethash "action" result)))
