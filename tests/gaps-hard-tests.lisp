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
