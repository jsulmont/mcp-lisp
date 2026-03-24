;;;; tests/transition-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite transition-tests
  :description "Tests for state machine extraction from rules"
  :in mcp-lisp-tests)

(in-suite transition-tests)

(defmacro with-fresh-specs (&body body)
  `(let ((mcp-lisp/src/spec/spec::*entities* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*rules* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*invariants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*compiled-fn-cache* (make-hash-table :test #'equal)))
     ,@body))

;;; ---------------------------------------------------------------------------
;;; Trading-ledger order setup — canonical test fixture
;;; ---------------------------------------------------------------------------

(defmacro with-order-specs (&body body)
  "Set up the trading-ledger order entity with its 5 rules."
  `(with-fresh-specs
     (mcp-lisp:defentity order ()
       (id string :required t)
       (instrument string :required t)
       (side (member :buy :sell))
       (quantity number :required t)
       (price number :required t)
       (state (member :pending :validated :filled :rejected :cancelled) :default :pending)
       (fill-price number :default 0)
       (slippage number :default 0))

     (mcp-lisp:defrule validate-order
       :when (order :state :pending)
       :requires ((not (trader-suspended trader))
                  (> (order-quantity order) 0)
                  (> (order-price order) 0))
       :ensures ((eq (order-state order) :validated)))

     (mcp-lisp:defrule fill-order
       :when (order :state :validated)
       :requires ((> fill-price 0))
       :ensures ((eq (order-state order) :filled)))

     (mcp-lisp:defrule reject-order
       :when (order :state :pending)
       :requires ((or (trader-suspended trader)
                      (<= (order-quantity order) 0)
                      (<= (order-price order) 0)))
       :ensures ((eq (order-state order) :rejected)))

     (mcp-lisp:defrule cancel-order-pending
       :when (order :state :pending)
       :ensures ((eq (order-state order) :cancelled)))

     (mcp-lisp:defrule cancel-order-validated
       :when (order :state :validated)
       :ensures ((eq (order-state order) :cancelled)))

     ,@body))

;;; ---------------------------------------------------------------------------
;;; detect-state-fields
;;; ---------------------------------------------------------------------------

(test detect-state-fields-finds-state
  "detect-state-fields identifies :state as a state field on order"
  (with-order-specs
    (let ((fields (mcp-lisp:detect-state-fields "order")))
      (is (= 1 (length fields)))
      (is (eq :state (first fields))))))

(test detect-state-fields-ignores-non-state-members
  "detect-state-fields skips member fields not used in rules"
  (with-order-specs
    (let ((fields (mcp-lisp:detect-state-fields "order")))
      ;; :side is a member field but not used in :when/:ensures
      (is (not (member :side fields))))))

(test detect-state-fields-no-rules
  "detect-state-fields returns NIL when entity has no rules"
  (with-fresh-specs
    (mcp-lisp:defentity color ()
      (name (member :red :green :blue)))
    (is (null (mcp-lisp:detect-state-fields "color")))))

(test detect-state-fields-when-only
  "detect-state-fields requires both :when and :ensures references"
  (with-fresh-specs
    (mcp-lisp:defentity light ()
      (mode (member :on :off) :default :off)
      (brightness number))
    ;; Rule has :when but no :ensures that sets mode
    (mcp-lisp:defrule dim-light
      :when (light :mode :on)
      :ensures ((> (light-brightness light) 0)))
    (is (null (mcp-lisp:detect-state-fields "light")))))

;;; ---------------------------------------------------------------------------
;;; extract-transitions
;;; ---------------------------------------------------------------------------

(test extract-transitions-order
  "extract-transitions produces correct graph for trading-ledger order"
  (with-order-specs
    (let ((transitions (mcp-lisp:extract-transitions "order")))
      ;; 5 rules → 5 transitions
      (is (= 5 (length transitions)))
      ;; Check validate-order: :pending -> :validated
      (let ((validate (find-if (lambda (tr)
                                 (string-equal "VALIDATE-ORDER"
                                               (symbol-name (getf tr :via))))
                               transitions)))
        (is (not (null validate)))
        (is (eq :pending (getf validate :from)))
        (is (eq :validated (getf validate :to)))
        (is (= 3 (length (getf validate :guards)))))
      ;; Check fill-order: :validated -> :filled
      (let ((fill (find-if (lambda (tr)
                             (string-equal "FILL-ORDER"
                                           (symbol-name (getf tr :via))))
                           transitions)))
        (is (not (null fill)))
        (is (eq :validated (getf fill :from)))
        (is (eq :filled (getf fill :to)))))))

(test extract-transitions-with-explicit-field
  "extract-transitions accepts an explicit field keyword"
  (with-order-specs
    (let ((transitions (mcp-lisp:extract-transitions "order" :state)))
      (is (= 5 (length transitions))))))

(test extract-transitions-no-state-field
  "extract-transitions returns NIL when no state field exists"
  (with-fresh-specs
    (mcp-lisp:defentity item ()
      (name string)
      (count integer))
    (is (null (mcp-lisp:extract-transitions "item")))))

(test extract-transitions-member-when
  "extract-transitions handles (member ...) in :when"
  (with-fresh-specs
    (mcp-lisp:defentity job ()
      (status (member :queued :running :done :failed) :default :queued))
    (mcp-lisp:defrule start-job
      :when (job :status :queued)
      :ensures ((eq (job-status job) :running)))
    (mcp-lisp:defrule finish-job
      :when (job :status :running)
      :ensures ((eq (job-status job) :done)))
    (mcp-lisp:defrule fail-job
      :when (job :status (member :queued :running))
      :ensures ((eq (job-status job) :failed)))
    (let ((transitions (mcp-lisp:extract-transitions "job")))
      ;; start + finish + fail(queued) + fail(running) = 4
      (is (= 4 (length transitions)))
      ;; fail-job should produce two transitions
      (let ((fails (remove-if-not
                    (lambda (tr)
                      (string-equal "FAIL-JOB" (symbol-name (getf tr :via))))
                    transitions)))
        (is (= 2 (length fails)))
        (is (member :queued (mapcar (lambda (tr) (getf tr :from)) fails)))
        (is (member :running (mapcar (lambda (tr) (getf tr :from)) fails)))))))

(test extract-transitions-getf-pattern
  "extract-transitions recognizes (eq (getf entity :field) :target) in :ensures"
  (with-fresh-specs
    (mcp-lisp:defentity door ()
      (state (member :open :closed :locked) :default :closed))
    (mcp-lisp:defrule open-door
      :when (door :state :closed)
      :ensures ((eq (getf door :state) :open)))
    (mcp-lisp:defrule close-door
      :when (door :state :open)
      :ensures ((eq (getf door :state) :closed)))
    (let ((transitions (mcp-lisp:extract-transitions "door")))
      (is (= 2 (length transitions)))
      (let ((open-tr (find :open transitions :key (lambda (tr) (getf tr :to)))))
        (is (not (null open-tr)))
        (is (eq :closed (getf open-tr :from)))))))

;;; ---------------------------------------------------------------------------
;;; terminal-states
;;; ---------------------------------------------------------------------------

(test terminal-states-order
  "terminal-states identifies filled, rejected, cancelled as terminal"
  (with-order-specs
    (let ((terms (mcp-lisp:terminal-states "order")))
      (is (= 3 (length terms)))
      (is (null (set-difference '(:filled :rejected :cancelled) terms))))))

;;; ---------------------------------------------------------------------------
;;; unreachable-states
;;; ---------------------------------------------------------------------------

(test unreachable-states-order-clean
  "unreachable-states returns empty for well-formed order graph"
  (with-order-specs
    ;; :pending is initial (default), all others have incoming edges
    (is (null (mcp-lisp:unreachable-states "order")))))

(test unreachable-states-detects-orphan
  "unreachable-states catches a state with no incoming edge"
  (with-fresh-specs
    (mcp-lisp:defentity ticket ()
      (state (member :open :in-progress :blocked :resolved) :default :open))
    (mcp-lisp:defrule start-ticket
      :when (ticket :state :open)
      :ensures ((eq (ticket-state ticket) :in-progress)))
    (mcp-lisp:defrule resolve-ticket
      :when (ticket :state :in-progress)
      :ensures ((eq (ticket-state ticket) :resolved)))
    ;; :blocked has no incoming edge and is not the default
    (let ((unreachable (mcp-lisp:unreachable-states "ticket")))
      (is (= 1 (length unreachable)))
      (is (eq :blocked (first unreachable))))))

;;; ---------------------------------------------------------------------------
;;; dead-end-states
;;; ---------------------------------------------------------------------------

(test dead-end-states-order-clean
  "dead-end-states returns empty for well-formed order graph"
  (with-order-specs
    (is (null (mcp-lisp:dead-end-states "order")))))

(test dead-end-states-detects-cycle
  "dead-end-states catches states stuck in a cycle"
  (with-fresh-specs
    (mcp-lisp:defentity process ()
      (state (member :init :loop-a :loop-b :done) :default :init))
    (mcp-lisp:defrule start-process
      :when (process :state :init)
      :ensures ((eq (process-state process) :loop-a)))
    (mcp-lisp:defrule cycle-a
      :when (process :state :loop-a)
      :ensures ((eq (process-state process) :loop-b)))
    (mcp-lisp:defrule cycle-b
      :when (process :state :loop-b)
      :ensures ((eq (process-state process) :loop-a)))
    ;; :init, :loop-a, and :loop-b can never reach :done
    (let ((dead (mcp-lisp:dead-end-states "process")))
      (is (= 3 (length dead)))
      (is (null (set-difference '(:init :loop-a :loop-b) dead))))))

;;; ---------------------------------------------------------------------------
;;; analyze-state-machine
;;; ---------------------------------------------------------------------------

(test analyze-state-machine-order
  "analyze-state-machine returns full analysis for order"
  (with-order-specs
    (let ((analysis (mcp-lisp:analyze-state-machine "order")))
      (is (not (null analysis)))
      (is (eq :state (getf analysis :field)))
      (is (= 5 (length (getf analysis :states))))
      (is (eq :pending (getf analysis :initial)))
      (is (= 3 (length (getf analysis :terminal))))
      (is (null (getf analysis :unreachable)))
      (is (null (getf analysis :dead-ends)))
      (is (= 5 (length (getf analysis :transitions)))))))

(test analyze-state-machine-no-state-field
  "analyze-state-machine returns NIL for entity without state fields"
  (with-fresh-specs
    (mcp-lisp:defentity widget ()
      (name string)
      (weight number))
    (is (null (mcp-lisp:analyze-state-machine "widget")))))

;;; ---------------------------------------------------------------------------
;;; validate-transitions
;;; ---------------------------------------------------------------------------

(test validate-transitions-clean
  "validate-transitions returns empty for well-formed order graph"
  (with-order-specs
    (is (null (mcp-lisp:validate-transitions)))))

(test validate-transitions-unreachable
  "validate-transitions warns about unreachable states"
  (with-fresh-specs
    (mcp-lisp:defentity ticket ()
      (state (member :open :in-progress :blocked :resolved) :default :open))
    (mcp-lisp:defrule start-ticket
      :when (ticket :state :open)
      :ensures ((eq (ticket-state ticket) :in-progress)))
    (mcp-lisp:defrule resolve-ticket
      :when (ticket :state :in-progress)
      :ensures ((eq (ticket-state ticket) :resolved)))
    (let ((warnings (mcp-lisp:validate-transitions)))
      (is (= 1 (length warnings)))
      (is (search "unreachable" (first warnings)))
      (is (search "BLOCKED" (first warnings))))))

(test validate-transitions-dead-end
  "validate-transitions warns about dead-end states"
  (with-fresh-specs
    (mcp-lisp:defentity process ()
      (state (member :init :loop-a :loop-b :done) :default :init))
    (mcp-lisp:defrule start-process
      :when (process :state :init)
      :ensures ((eq (process-state process) :loop-a)))
    (mcp-lisp:defrule cycle-a
      :when (process :state :loop-a)
      :ensures ((eq (process-state process) :loop-b)))
    (mcp-lisp:defrule cycle-b
      :when (process :state :loop-b)
      :ensures ((eq (process-state process) :loop-a)))
    (let ((warnings (mcp-lisp:validate-transitions)))
      ;; :done is unreachable, :init/:loop-a/:loop-b are dead ends
      (is (= 4 (length warnings)))
      (is (some (lambda (w) (search "unreachable" w)) warnings))
      (is (some (lambda (w) (search "dead end" w)) warnings)))))

(test validate-transitions-both-issues
  "validate-transitions reports both unreachable and dead-end states"
  (with-fresh-specs
    (mcp-lisp:defentity workflow ()
      (state (member :new :active :stuck :orphan :complete) :default :new))
    (mcp-lisp:defrule activate
      :when (workflow :state :new)
      :ensures ((eq (workflow-state workflow) :active)))
    ;; :active -> :stuck -> :active (cycle, dead end)
    (mcp-lisp:defrule get-stuck
      :when (workflow :state :active)
      :ensures ((eq (workflow-state workflow) :stuck)))
    (mcp-lisp:defrule unstick
      :when (workflow :state :stuck)
      :ensures ((eq (workflow-state workflow) :active)))
    ;; :orphan has no incoming edge, :complete has no transitions at all
    (let ((warnings (mcp-lisp:validate-transitions)))
      ;; :orphan → unreachable
      ;; :new, :active, :stuck → dead ends (can't reach :complete)
      (is (some (lambda (w) (search "unreachable" w)) warnings))
      (is (some (lambda (w) (search "dead end" w)) warnings)))))

(test validate-transitions-no-state-machines
  "validate-transitions returns empty when no entities have state fields"
  (with-fresh-specs
    (mcp-lisp:defentity widget ()
      (name string)
      (weight number))
    (is (null (mcp-lisp:validate-transitions)))))

;;; ---------------------------------------------------------------------------
;;; Rule execution fixture — self-contained guards (no cross-entity refs)
;;; ---------------------------------------------------------------------------

(defmacro with-executable-order-specs (&body body)
  "Order entity with rules whose guards only reference the entity's own fields."
  `(with-fresh-specs
     (mcp-lisp:defentity order ()
       (id string :required t)
       (instrument string :required t)
       (quantity number :required t)
       (price number :required t)
       (state (member :pending :validated :filled :rejected :cancelled) :default :pending)
       (fill-price number :default 0))

     (mcp-lisp:defrule validate-order
       :when (order :state :pending)
       :requires ((> (order-quantity order) 0)
                  (> (order-price order) 0))
       :ensures ((eq (order-state order) :validated)))

     (mcp-lisp:defrule fill-order
       :when (order :state :validated)
       :ensures ((eq (order-state order) :filled)))

     (mcp-lisp:defrule reject-order
       :when (order :state :pending)
       :requires ((<= (order-quantity order) 0))
       :ensures ((eq (order-state order) :rejected)))

     (mcp-lisp:defrule cancel-pending
       :when (order :state :pending)
       :ensures ((eq (order-state order) :cancelled)))

     (mcp-lisp:defrule cancel-validated
       :when (order :state :validated)
       :ensures ((eq (order-state order) :cancelled)))

     ,@body))

;;; ---------------------------------------------------------------------------
;;; apply-rule
;;; ---------------------------------------------------------------------------

(test apply-rule-state-transition
  "apply-rule transitions state on success"
  (with-executable-order-specs
    (let ((order (list :id "o1" :instrument "AAPL" :quantity 10 :price 50.0
                       :state :pending :fill-price 0)))
      (multiple-value-bind (new applied reason)
          (mcp-lisp:apply-rule "order" order "validate-order")
        (is (eq t applied))
        (is (null reason))
        (is (eq :validated (getf new :state)))))))

(test apply-rule-when-mismatch
  "apply-rule rejects when state doesn't match :when"
  (with-executable-order-specs
    (let ((order (list :id "o1" :instrument "AAPL" :quantity 10 :price 50.0
                       :state :pending :fill-price 0)))
      (multiple-value-bind (new applied reason)
          (mcp-lisp:apply-rule "order" order "fill-order")
        (is (null applied))
        (is (eq :when-mismatch reason))
        (is (eq :pending (getf new :state)))))))

(test apply-rule-guard-failed
  "apply-rule rejects when :requires guard fails"
  (with-executable-order-specs
    (let ((order (list :id "o1" :instrument "AAPL" :quantity -5 :price 50.0
                       :state :pending :fill-price 0)))
      (multiple-value-bind (new applied reason)
          (mcp-lisp:apply-rule "order" order "validate-order")
        (is (null applied))
        (is (consp reason))
        (is (eq :guard-failed (first reason)))
        (is (eq :pending (getf new :state)))))))

(test apply-rule-preserves-fields
  "apply-rule only changes state field, not other fields"
  (with-executable-order-specs
    (let ((order (list :id "o1" :instrument "AAPL" :quantity 10 :price 50.0
                       :state :pending :fill-price 0)))
      (multiple-value-bind (new applied _reason)
          (mcp-lisp:apply-rule "order" order "validate-order")
        (declare (ignore _reason))
        (is (eq t applied))
        (is (equal "o1" (getf new :id)))
        (is (= 10 (getf new :quantity)))
        (is (= 50.0 (getf new :price)))
        (is (= 0 (getf new :fill-price)))))))

(test apply-rule-chain
  "apply-rule can chain: pending → validated → filled"
  (with-executable-order-specs
    (let ((order (list :id "o1" :instrument "AAPL" :quantity 10 :price 50.0
                       :state :pending :fill-price 0)))
      (multiple-value-bind (new1 ok1 _r1)
          (mcp-lisp:apply-rule "order" order "validate-order")
        (declare (ignore _r1))
        (is (eq t ok1))
        (multiple-value-bind (new2 ok2 _r2)
            (mcp-lisp:apply-rule "order" new1 "fill-order")
          (declare (ignore _r2))
          (is (eq t ok2))
          (is (eq :filled (getf new2 :state))))))))

(test apply-rule-unknown-rule
  "apply-rule returns :unknown-rule for nonexistent rule"
  (with-executable-order-specs
    (let ((order (list :id "o1" :state :pending)))
      (multiple-value-bind (_new applied reason)
          (mcp-lisp:apply-rule "order" order "nonexistent-rule")
        (declare (ignore _new))
        (is (null applied))
        (is (eq :unknown-rule reason))))))

(test apply-rule-does-not-mutate-original
  "apply-rule returns a new list, original is unchanged"
  (with-executable-order-specs
    (let ((order (list :id "o1" :instrument "AAPL" :quantity 10 :price 50.0
                       :state :pending :fill-price 0)))
      (mcp-lisp:apply-rule "order" order "validate-order")
      (is (eq :pending (getf order :state))))))

;;; ---------------------------------------------------------------------------
;;; applicable-rules
;;; ---------------------------------------------------------------------------

(test applicable-rules-pending
  "applicable-rules returns correct rules for :pending state"
  (with-executable-order-specs
    (let* ((order (list :id "o1" :state :pending :quantity 10 :price 50.0))
           (rules (mcp-lisp:applicable-rules "order" order)))
      (is (= 3 (length rules)))
      (is (member "validate-order" rules :test #'string=))
      (is (member "reject-order" rules :test #'string=))
      (is (member "cancel-pending" rules :test #'string=)))))

(test applicable-rules-validated
  "applicable-rules returns correct rules for :validated state"
  (with-executable-order-specs
    (let* ((order (list :id "o1" :state :validated :quantity 10 :price 50.0))
           (rules (mcp-lisp:applicable-rules "order" order)))
      (is (= 2 (length rules)))
      (is (member "fill-order" rules :test #'string=))
      (is (member "cancel-validated" rules :test #'string=)))))

(test applicable-rules-terminal
  "applicable-rules returns empty for terminal state"
  (with-executable-order-specs
    (let ((order (list :id "o1" :state :filled)))
      (is (null (mcp-lisp:applicable-rules "order" order))))))

;;; ---------------------------------------------------------------------------
;;; random-walk
;;; ---------------------------------------------------------------------------

(test random-walk-basic
  "random-walk completes without error"
  (with-executable-order-specs
    (let ((result (mcp-lisp:random-walk "order" :steps 10 :trials 20 :verbose nil)))
      (is (not (null result)))
      (is (equal "order" (getf result :entity)))
      (is (= 20 (getf result :trials)))
      (is (= 10 (getf result :steps)))
      (is (= 20 (+ (getf result :passed) (getf result :failed)))))))

(test random-walk-catches-violation
  "random-walk detects invariant violations caused by state transitions"
  (with-fresh-specs
    (mcp-lisp:defentity ticket ()
      (id string :required t)
      (state (member :open :assigned :resolved) :default :open)
      (priority integer :required t :min 0 :max 10))

    (mcp-lisp:defrule assign-ticket
      :when (ticket :state :open)
      :ensures ((eq (ticket-state ticket) :assigned)))

    (mcp-lisp:defrule resolve-ticket
      :when (ticket :state :assigned)
      :ensures ((eq (ticket-state ticket) :resolved)))

    ;; Invariant: resolved tickets must have priority 0.
    ;; Since apply-rule only changes state (not priority), this WILL fire
    ;; when a ticket with priority > 0 gets resolved.
    (mcp-lisp:definvariant resolved-priority-zero
      :on ticket
      :check (if (eq (ticket-state ticket) :resolved)
                 (= (ticket-priority ticket) 0)
                 t))

    (let ((result (mcp-lisp:random-walk "ticket" :steps 5 :trials 30 :verbose nil)))
      ;; Should have failures since priority stays > 0 after resolve
      (is (> (getf result :failed) 0)))))
