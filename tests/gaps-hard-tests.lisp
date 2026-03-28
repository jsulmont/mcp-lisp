;;;; tests/gaps-hard-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite gaps-hard-tests
  :description "Tests for hard-tier DSL gap fixes: :after, :creates, :deletes on defrule"
  :in mcp-lisp-tests)

(in-suite gaps-hard-tests)

(defmacro with-rule-specs (&body body)
  `(let ((mcp-lisp/src/spec/spec::*entities* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*rules* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*invariants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*generator-sources* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*variants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*mixins* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*compounds* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenarios* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenario-generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenario-generator-sources* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenario-negative-generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenario-negative-generator-sources* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*compiled-fn-cache* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*helpers* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*helper-sources* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*config* nil)
         (mcp-lisp/src/spec/spec::*current-config* nil))
     ,@body))

;;; ===========================================================================
;;; :after — temporal guards
;;; ===========================================================================

(test after-clause-stored
  "defrule stores :after clause in rule plist"
  (with-rule-specs
    (mcp-lisp:defentity lease ()
      (id string :required t)
      (state (member :active :expired) :default :active)
      (granted-at number :required t)
      (duration number :required t))
    (mcp-lisp:defrule expire-lease
      :when (lease :state :active)
      :after (>= (- now (lease-granted-at lease)) (lease-duration lease))
      :ensures ((eq (lease-state lease) :expired)))
    (let ((rule (mcp-lisp:describe-rule "expire-lease")))
      (is (not (null (getf rule :after)))))))

(test after-clause-blocks-apply-rule-when-time-insufficient
  "apply-rule rejects when :after predicate fails (time not elapsed)"
  (with-rule-specs
    (mcp-lisp:defentity lease ()
      (id string :required t)
      (state (member :active :expired) :default :active)
      (granted-at number :required t)
      (duration number :required t))
    (mcp-lisp:defrule expire-lease
      :when (lease :state :active)
      :after (>= (- now (lease-granted-at lease)) (lease-duration lease))
      :ensures ((eq (lease-state lease) :expired)))
    (mcp-lisp:ensure-entity-accessors "lease")
    (let ((inst '(:id "l1" :state :active :granted-at 0 :duration 100)))
      (multiple-value-bind (new applied reason)
          (mcp-lisp:apply-rule "lease" inst "expire-lease" :now 50)
        (declare (ignore new))
        (is (null applied))
        (is (eq :after-failed (first reason)))))))

(test after-clause-allows-apply-rule-when-time-sufficient
  "apply-rule fires when :after predicate passes (time elapsed)"
  (with-rule-specs
    (mcp-lisp:defentity lease ()
      (id string :required t)
      (state (member :active :expired) :default :active)
      (granted-at number :required t)
      (duration number :required t))
    (mcp-lisp:defrule expire-lease
      :when (lease :state :active)
      :after (>= (- now (lease-granted-at lease)) (lease-duration lease))
      :ensures ((eq (lease-state lease) :expired)))
    (mcp-lisp:ensure-entity-accessors "lease")
    (let ((inst '(:id "l1" :state :active :granted-at 0 :duration 100)))
      (multiple-value-bind (new applied)
          (mcp-lisp:apply-rule "lease" inst "expire-lease" :now 150)
        (is (not (null applied)))
        (is (eq :expired (getf new :state)))))))

(test random-walk-advances-clock-for-after-rules
  "random-walk uses simulated clock for :after rules"
  (with-rule-specs
    (mcp-lisp:defentity lease ()
      (id string :required t)
      (state (member :active :expired) :default :active)
      (granted-at number :required t :min 0 :max 10)
      (duration number :required t :min 1 :max 20))
    (mcp-lisp:defrule expire-lease
      :when (lease :state :active)
      :after (>= (- now (lease-granted-at lease)) (lease-duration lease))
      :ensures ((eq (lease-state lease) :expired)))
    (mcp-lisp:definvariant expired-is-terminal
      :on lease
      :check t)
    (let ((result (mcp-lisp:random-walk "lease"
                    :steps 50 :trials 20 :verbose nil
                    :clock-step 20)))
      (is (= 0 (getf result :failed))))))

;;; ===========================================================================
;;; :creates / :deletes — structural mutations
;;; ===========================================================================

(test creates-clause-stored
  "defrule stores :creates clause"
  (with-rule-specs
    (mcp-lisp:defentity user ()
      (id string :required t)
      (state (member :active :suspended) :default :active))
    (mcp-lisp:defrule suspend-user
      :when (user :state :active)
      :ensures ((eq (user-state user) :suspended))
      :creates ((audit-entry :action :suspend :user-id (user-id user))))
    (let ((rule (mcp-lisp:describe-rule "suspend-user")))
      (is (not (null (getf rule :creates)))))))

(test deletes-clause-stored
  "defrule stores :deletes clause"
  (with-rule-specs
    (mcp-lisp:defentity session ()
      (id string :required t)
      (state (member :active :expired) :default :active))
    (mcp-lisp:defrule expire-session
      :when (session :state :active)
      :ensures ((eq (session-state session) :expired))
      :deletes (session))
    (let ((rule (mcp-lisp:describe-rule "expire-session")))
      (is (not (null (getf rule :deletes)))))))

(test after-creates-deletes-survive-lisp-serialization
  "specs-to-lisp emits :after, :creates, :deletes clauses"
  (with-rule-specs
    (mcp-lisp:defentity lease ()
      (id string :required t)
      (state (member :active :expired) :default :active)
      (granted-at number :required t)
      (duration number :required t))
    (mcp-lisp:defrule expire-lease
      :when (lease :state :active)
      :after (>= (- now (lease-granted-at lease)) (lease-duration lease))
      :ensures ((eq (lease-state lease) :expired))
      :creates ((audit-log :event :expired))
      :deletes (lease))
    (let ((lisp-src (mcp-lisp:specs-to-lisp)))
      (is (search ":after" lisp-src))
      (is (search ":creates" lisp-src))
      (is (search ":deletes" lisp-src)))))

;;; ===========================================================================
;;; set-of type
;;; ===========================================================================

(test set-of-generates-subset
  "generate-value for (set-of ...) produces a subset of the choices"
  (dotimes (i 50)
    (let ((v (mcp-lisp:generate-value '(set-of :a :b :c :d))))
      (is (listp v))
      (is (every (lambda (x) (member x '(:a :b :c :d))) v)))))

(test set-of-in-entity
  "Entity with (set-of ...) field generates valid subsets"
  (with-rule-specs
    (mcp-lisp:defentity device ()
      (id string :required t)
      (modes-supported (set-of :heat :cool :auto :fan))
      (modes-enabled (set-of :heat :cool :auto :fan)))
    (dotimes (i 20)
      (let ((inst (mcp-lisp:generate-instance "device")))
        (is (listp (getf inst :modes-supported)))
        (is (listp (getf inst :modes-enabled)))
        (is (every (lambda (m) (member m '(:heat :cool :auto :fan)))
                   (getf inst :modes-supported)))))))

;;; ===========================================================================
;;; diff-specs — completeness verification
;;; ===========================================================================

(test diff-specs-reports-missing-and-extra
  "diff-specs compares registered entities against expected list"
  (with-rule-specs
    (mcp-lisp:defentity alpha () (id string :required t))
    (mcp-lisp:defentity beta () (id string :required t))
    (let ((result (mcp-lisp:diff-specs '("alpha" "beta" "gamma"))))
      (is (equal '("gamma") (getf result :missing)))
      (is (null (getf result :extra)))
      (is (= 2 (length (getf result :matched))))
      (is (< (getf result :coverage) 0.7)))))

;;; ===========================================================================
;;; distribute-values / partition-into — generation helpers
;;; ===========================================================================

(test distribute-values-sums-within-total
  "distribute-values produces N values summing to at most total"
  (dotimes (i 50)
    (let ((vals (mcp-lisp:distribute-values 5 100)))
      (is (= 5 (length vals)))
      (is (<= (reduce #'+ vals) 100))
      (is (every #'numberp vals)))))

(test partition-into-distributes-all-items
  "partition-into puts every item into exactly one group"
  (let* ((items '(1 2 3 4 5 6 7 8))
         (groups (mcp-lisp:partition-into items 3)))
    (is (= 3 (length groups)))
    (is (= 8 (reduce #'+ groups :key #'length)))
    (is (null (set-difference items (apply #'append groups))))))

;;; ===========================================================================
;;; Cross-entity invariant :path stored
;;; ===========================================================================

(test invariant-path-stored
  "definvariant stores :path clause"
  (with-rule-specs
    (mcp-lisp:defentity der ()
      (id string :required t))
    (mcp-lisp:definvariant settings-bounded
      :on der
      :path ((settings der-settings :via :has-one))
      :check (<= (der-settings-set-max-w settings) 1000))
    (let ((inv (mcp-lisp:describe-invariant "settings-bounded")))
      (is (not (null (getf inv :path)))))))

;;; ===========================================================================
;;; Scenario-aware random walk
;;; ===========================================================================

(test random-walk-scenario-runs
  "random-walk-scenario generates and walks a scenario"
  (with-rule-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t :min 0.0 :max 1000.0)
      (status (member :active :frozen) :default :active))
    (mcp-lisp:defrule freeze-account
      :when (account :status :active)
      :requires ((< (account-balance account) 10))
      :ensures ((eq (account-status account) :frozen)))
    (mcp-lisp:definvariant balance-non-negative
      :on account
      :check (>= (account-balance account) 0))
    (mcp-lisp:defscenario multi-account
      :entities ((accounts (2 5) account)))
    (let ((result (mcp-lisp:random-walk-scenario "multi-account"
                    :steps 10 :trials 10 :verbose nil)))
      (is (not (null result)))
      (is (= 0 (getf result :failed))))))

(test random-walk-scenario-cross-entity-let
  "random-walk-scenario passes scenario bindings so :let can see other entities"
  (with-rule-specs
    (mcp-lisp:defentity warehouse ()
      (id string :required t)
      (capacity number :required t :min 100 :max 500)
      (status (member :open :closed) :default :open))
    (mcp-lisp:defentity shipment ()
      (id string :required t)
      (size number :required t :min 1 :max 50)
      (state (member :pending :delivered) :default :pending)
      (:belongs-to warehouse))
    (mcp-lisp:defrule deliver-shipment
      :when (shipment :state :pending)
      :let ((wh (find (getf shipment :warehouse-id)
                      warehouses
                      :key (lambda (w) (getf w :id))
                      :test #'equal)))
      :requires ((and wh (eq (getf wh :status) :open)))
      :ensures ((eq (shipment-state shipment) :delivered)))
    (mcp-lisp:definvariant size-positive
      :on shipment
      :check (> (shipment-size shipment) 0))
    (mcp-lisp:defscenario delivery
      :entities ((warehouses 2 warehouse)
                 (shipments (3 6) shipment)))
    (mcp-lisp:defscenario-generator delivery (overrides)
      (declare (ignore overrides))
      (let* ((wh1 (mcp-lisp:generate-instance "warehouse"))
             (wh2 (mcp-lisp:generate-instance "warehouse"))
             (whs (list wh1 wh2)))
        (list :warehouses whs
              :shipments (loop repeat (+ 3 (random 4))
                               collect (mcp-lisp:generate-instance "shipment"
                                         (list :warehouse-id
                                               (getf (nth (random 2) whs) :id)))))))
    (let ((result (mcp-lisp:random-walk-scenario "delivery"
                    :steps 15 :trials 20 :verbose nil)))
      (is (not (null result)))
      (is (= 0 (getf result :failed))))))
