;;;; examples/escalation-agent/server.lisp
;;;;
;;;; Claude Architect — Exercise 1, server half.
;;;;
;;;; A real mcp-lisp MCP server that defines four refund tools with `define-tool`
;;;; and, as each one works, emits:
;;;;   * logging  — `tool-log`            -> notifications/message
;;;;   * progress — `tool-report-progress` -> notifications/progress
;;;;
;;;; Those server->client notifications only flow over a transport that can carry
;;;; them, so this runs on Streamable HTTP (Woo). The client (client.lisp) drives
;;;; the agentic loop and prints the log/progress notifications live.
;;;;
;;;; The escalation business rule is NOT enforced here — it lives in the client's
;;;; pre-tool hook, so these tools are plain capabilities. (A $980 card refund
;;;; would happily go through here; the client is what stops it.)
;;;;
;;;;   sbcl --load examples/escalation-agent/server.lisp

;;; --- Bootstrap: load Quicklisp + the mcp-lisp system, keep stdout clean ---
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
    (funcall (find-symbol "LOAD-SYSTEM" "ASDF") :mcp-lisp :verbose nil :print nil)))

(defpackage #:escalation-agent-server
  (:use #:cl #:mcp-lisp/main))
(in-package #:escalation-agent-server)

;;; --- Structured result envelopes (step 3) ---

(defun ok-result (&rest kv)
  "Encode a success envelope: {\"ok\": true, ...kv}."
  (let ((ht (make-ht "ok" t)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k ht) v))
    (encode-json ht)))

(defun err-result (category retryable message &rest extra)
  "Encode a structured error envelope.
CATEGORY is one of \"transient\", \"validation\", \"permission\"."
  (let ((ht (make-ht "ok" nil
                     "errorCategory" category
                     "isRetryable" retryable
                     "message" message)))
    (loop for (k v) on extra by #'cddr do (setf (gethash k ht) v))
    (encode-json ht)))

;;; --- Fake back-office data ---

(defparameter *orders*
  (let ((h (make-hash-table :test #'equal)))
    (setf (gethash "A100" h) (list :status "delivered" :amount 240.0
                                   :payment "visa-4242" :issue "arrived damaged"))
    (setf (gethash "B200" h) (list :status "delivered" :amount 980.0
                                   :payment "amex-1001" :issue "charged twice"))
    h)
  "Known orders. Anything else is an unrecoverable validation error.")

(defvar *gateway-flaked* nil
  "One-shot flag: the first lookup_order simulates a transient gateway timeout,
so the agent must notice isRetryable and retry.")

;;; --- Tools (step 1). Tool names are derived from the symbol:
;;;     lookup-order -> lookup_order, order-id -> order_id, etc. ---

(define-tool lookup-order ((order-id string "The order identifier, e.g. \"A100\"." :required t))
  "Retrieve the current status, total amount, and ORIGINAL payment method for one order by its ID. Call this FIRST for any order before deciding on a refund or credit — it is the only source of the order's amount and payment method. Read-only; safe to retry."
  (:annotations :read-only t)
  (tool-log "info" (format nil "lookup_order ~a" order-id))
  (tool-report-progress 0 :total 2 :message "Contacting order service")
  (cond
    ((not *gateway-flaked*)
     (setf *gateway-flaked* t)
     (tool-log "warning" "Order service timed out (transient) — advise retry")
     (tool-report-progress 2 :total 2 :message "Gateway timeout")
     (err-result "transient" t
                 "Payment gateway timed out while fetching the order. Retry the same call."))
    ((gethash order-id *orders*)
     (let ((o (gethash order-id *orders*)))
       (tool-report-progress 1 :total 2 :message "Order located")
       (tool-log "info" (format nil "Order ~a: ~a, $~,2f via ~a"
                                order-id (getf o :status) (getf o :amount) (getf o :payment)))
       (tool-report-progress 2 :total 2 :message "Done")
       (ok-result "order_id" order-id
                  "status" (getf o :status)
                  "amount" (getf o :amount)
                  "payment_method" (getf o :payment)
                  "reported_issue" (getf o :issue))))
    (t
     (tool-log "error" (format nil "Order ~a not found" order-id))
     (tool-report-progress 2 :total 2 :message "Not found")
     (err-result "validation" nil
                 (format nil "Order ~a not found. Ask the customer to verify the order number."
                         order-id)))))

(define-tool check-refund-eligibility
    ((order-id string "The order identifier." :required t))
  "Check whether an order qualifies for a refund and the maximum refundable amount. Use after lookup_order when you are unsure an order is refundable. Read-only."
  (:annotations :read-only t)
  (tool-log "info" (format nil "check_refund_eligibility ~a" order-id))
  (tool-report-progress 0 :total 1 :message "Checking policy")
  (let ((o (gethash order-id *orders*)))
    (tool-report-progress 1 :total 1 :message "Done")
    (if o
        (ok-result "order_id" order-id
                   "eligible" t
                   "max_refund" (getf o :amount)
                   "reason" (format nil "Order ~a is within the 30-day return window." order-id))
        (err-result "validation" nil
                    (format nil "Cannot check eligibility: order ~a not found." order-id)))))

(define-tool issue-card-refund
    ((order-id string "The order identifier." :required t)
     (amount number "Dollar amount to refund to the card." :required t))
  "Return money to the customer's ORIGINAL payment method (the credit/debit card used at checkout). Real funds LEAVE the company and arrive in the customer's bank account — this is irreversible. Use this ONLY when the customer wants their money back on their card / original payment method, or asks for a plain \"refund\" with no other qualification. Do NOT use this to grant store credit; use apply_account_credit for that."
  (tool-log "notice" (format nil "issue_card_refund ~a $~,2f" order-id amount))
  (tool-report-progress 0 :total 2 :message "Authorizing card refund")
  (cond
    ((not (gethash order-id *orders*))
     (tool-report-progress 2 :total 2 :message "Order not found")
     (err-result "validation" nil (format nil "Order ~a not found." order-id)))
    (t
     (tool-report-progress 1 :total 2 :message "Posting refund to card")
     (let ((o (gethash order-id *orders*)))
       (tool-log "info" (format nil "Refunded $~,2f to ~a" amount (getf o :payment)))
       (tool-report-progress 2 :total 2 :message "Done")
       (ok-result "order_id" order-id
                  "refunded_amount" amount
                  "destination" (getf o :payment)
                  "confirmation" (format nil "RFND-~a" order-id)
                  "message" (format nil "$~,2f refunded to the card on file." amount))))))

(define-tool apply-account-credit
    ((order-id string "The order identifier." :required t)
     (amount number "Dollar amount of store credit to grant." :required t))
  "Add STORE CREDIT to the customer's account balance for use on future purchases. No real money leaves the company and nothing reaches the customer's card or bank. Use this ONLY when the customer agrees to take store credit instead of cash, or as a goodwill gesture. Do NOT use this when the customer asked for their money back on their card — use issue_card_refund for that."
  (tool-log "notice" (format nil "apply_account_credit ~a $~,2f" order-id amount))
  (tool-report-progress 0 :total 2 :message "Crediting account balance")
  (cond
    ((not (gethash order-id *orders*))
     (tool-report-progress 2 :total 2 :message "Order not found")
     (err-result "validation" nil (format nil "Order ~a not found." order-id)))
    (t
     (tool-report-progress 1 :total 2 :message "Applying store credit")
     (tool-log "info" (format nil "Granted $~,2f store credit on ~a" amount order-id))
     (tool-report-progress 2 :total 2 :message "Done")
     (ok-result "order_id" order-id
                "credited_amount" amount
                "destination" "store-account-balance"
                "confirmation" (format nil "CRED-~a" order-id)
                "message" (format nil "$~,2f added to the account balance as store credit."
                                  amount)))))

;;; --- Start the server ---

(defparameter *port* 8765)
(format t "~&Escalation-agent MCP server on http://localhost:~a/mcp~%" *port*)
(format t "Run the client:  sbcl --script examples/escalation-agent/client.lisp \"your message\"~%~%")
(run-server :name "escalation-agent" :version "1.0.0" :transport :sse :port *port*)
(loop (sleep 3600))
