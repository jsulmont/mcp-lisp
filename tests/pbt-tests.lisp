;;;; tests/pbt-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite pbt-tests
  :description "Tests for spec property-based testing"
  :in mcp-lisp-tests)

(in-suite pbt-tests)

(defmacro with-fresh-specs (&body body)
  `(let ((mcp-lisp/src/spec/spec::*entities* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*rules* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*invariants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*generators* (make-hash-table :test #'equal)))
     ,@body))

;;; ---------------------------------------------------------------------------
;;; Value generation
;;; ---------------------------------------------------------------------------

(test generate-value-string
  "generate-value for string produces a string"
  (let ((v (mcp-lisp:generate-value 'string)))
    (is (stringp v))))

(test generate-value-number
  "generate-value for number produces a number"
  (let ((v (mcp-lisp:generate-value 'number)))
    (is (numberp v))))

(test generate-value-integer
  "generate-value for integer produces an integer"
  (let ((v (mcp-lisp:generate-value 'integer)))
    (is (integerp v))))

(test generate-value-member
  "generate-value for member type picks from the choices"
  (let ((v (mcp-lisp:generate-value '(member :a :b :c))))
    (is (member v '(:a :b :c)))))

;;; ---------------------------------------------------------------------------
;;; Instance generation
;;; ---------------------------------------------------------------------------

(test generate-instance-has-all-fields
  "generate-instance produces a plist with all entity fields"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t)
      (status (member :active :closed) :default :active))
    (let ((inst (mcp-lisp:generate-instance "account")))
      (is (stringp (getf inst :id)))
      (is (numberp (getf inst :balance)))
      (is (member (getf inst :status) '(:active :closed))))))

(test generate-instance-with-overrides
  "generate-instance respects field overrides"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t))
    (let ((inst (mcp-lisp:generate-instance "account" '((:balance . 42)))))
      (is (= 42 (getf inst :balance)))
      (is (stringp (getf inst :id))))))

;;; ---------------------------------------------------------------------------
;;; Accessor generation
;;; ---------------------------------------------------------------------------

(test ensure-entity-accessors-defines-functions
  "ensure-entity-accessors creates callable accessor functions"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:ensure-entity-accessors "account")
    (let ((accessor (intern "ACCOUNT-BALANCE")))
      (is (fboundp accessor))
      (is (= 50 (funcall accessor '(:balance 50)))))))

;;; ---------------------------------------------------------------------------
;;; Invariant checking
;;; ---------------------------------------------------------------------------

(test check-invariants-passes
  "check-invariants returns empty list when invariants hold"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant non-negative
      :on account
      :check (>= (account-balance account) 0))
    (mcp-lisp:ensure-entity-accessors "account")
    (is (null (mcp-lisp:check-invariants "account" '(:balance 50))))))

(test check-invariants-catches-violation
  "check-invariants returns violated invariant names"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant non-negative
      :on account
      :check (>= (account-balance account) 0))
    (mcp-lisp:ensure-entity-accessors "account")
    (let ((violations (mcp-lisp:check-invariants "account" '(:balance -5))))
      (is (= 1 (length violations)))
      (is (string= "non-negative" (first violations))))))

;;; ---------------------------------------------------------------------------
;;; PBT runner
;;; ---------------------------------------------------------------------------

(test run-pbt-all-pass
  "run-pbt reports all pass when invariant is always satisfiable"
  (with-fresh-specs
    (mcp-lisp:defentity color ()
      (name (member :red :green :blue)))
    ;; Trivially true invariant
    (mcp-lisp:definvariant has-name
      :on color
      :check (not (null (color-name color))))
    (let ((results (mcp-lisp:run-pbt :trials 50)))
      (is (= 1 (length results)))
      (is (= 50 (getf (first results) :passed)))
      (is (= 0 (getf (first results) :failed))))))

(test run-pbt-detects-failures
  "run-pbt finds counterexamples for violable invariants"
  (with-fresh-specs
    ;; Use a cross-field invariant the constraint extractor can't solve:
    ;; balance must equal quantity * price (a derived equality the extractor skips)
    (mcp-lisp:defentity position ()
      (balance number :required t)
      (quantity number :required t)
      (price number :required t))
    (mcp-lisp:definvariant balance-matches
      :on position
      :check (= (position-balance position)
                (* (position-quantity position) (position-price position))))
    (let ((results (mcp-lisp:run-pbt :trials 200)))
      (is (= 1 (length results)))
      ;; Three independent random numbers almost never satisfy a = b * c
      (is (plusp (getf (first results) :failed)))
      (is (plusp (length (getf (first results) :failures)))))))

(test run-pbt-skips-entities-without-invariants
  "run-pbt only tests entities that have invariants"
  (with-fresh-specs
    (mcp-lisp:defentity user ()
      (name string))
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant non-negative
      :on account
      :check (>= (account-balance account) 0))
    (let ((results (mcp-lisp:run-pbt :trials 10)))
      ;; Only account should appear in results (user has no invariants)
      (is (= 1 (length results)))
      (is (string= "account" (getf (first results) :entity))))))

;;; ---------------------------------------------------------------------------
;;; Generator constraints
;;; ---------------------------------------------------------------------------

(test generate-value-respects-min-max-number
  "generate-value with :min/:max constrains numeric range"
  (dotimes (i 100)
    (let ((v (mcp-lisp:generate-value 'number :min 0.0 :max 10.0)))
      (is (>= v 0.0))
      (is (< v 10.0)))))

(test generate-value-respects-min-max-integer
  "generate-value with :min/:max constrains integer range"
  (dotimes (i 100)
    (let ((v (mcp-lisp:generate-value 'integer :min 5 :max 20)))
      (is (integerp v))
      (is (>= v 5))
      (is (<= v 20)))))

(test generate-instance-uses-field-constraints
  "generate-instance respects :min/:max on fields"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t :min 0.0 :max 1000.0))
    (dotimes (i 50)
      (let ((inst (mcp-lisp:generate-instance "account")))
        (is (>= (getf inst :balance) 0.0))
        (is (< (getf inst :balance) 1000.0))))))

(test generate-instance-computes-derived-from
  "generate-instance evaluates :derived-from to compute field values"
  (with-fresh-specs
    (mcp-lisp:defentity position ()
      (quantity number :required t :min 1.0 :max 100.0)
      (price number :required t :min 1.0 :max 100.0)
      (notional number :derived-from (* (getf instance :quantity) (getf instance :price))))
    (dotimes (i 50)
      (let ((inst (mcp-lisp:generate-instance "position")))
        (is (= (getf inst :notional)
                (* (getf inst :quantity) (getf inst :price))))))))

(test constrained-pbt-all-pass
  "PBT passes when constraints make invariants satisfiable"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t :min 0.0 :max 1000.0))
    (mcp-lisp:definvariant non-negative
      :on account
      :check (>= (account-balance account) 0))
    (let ((results (mcp-lisp:run-pbt :trials 200)))
      (is (= 0 (getf (first results) :failed))))))

;;; ---------------------------------------------------------------------------
;;; Custom generators
;;; ---------------------------------------------------------------------------

(test defgenerator-replaces-default
  "defgenerator replaces the default generator for an entity"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t))
    (mcp-lisp:defgenerator account (overrides)
      (declare (ignore overrides))
      (list :id "fixed-id" :balance 42))
    (let ((inst (mcp-lisp:generate-instance "account")))
      (is (string= "fixed-id" (getf inst :id)))
      (is (= 42 (getf inst :balance))))))

(test defgenerator-with-default-fixup
  "defgenerator can call default-generate-instance and fix up cross-field deps"
  (with-fresh-specs
    (mcp-lisp:defentity trader ()
      (id string :required t)
      (margin-ratio number :required t :min 0.0 :max 100.0)
      (suspended boolean))
    (mcp-lisp:definvariant suspended-margin
      :on trader
      :check (if (trader-suspended trader)
                 (< (trader-margin-ratio trader) 0.5)
                 t))
    (mcp-lisp:defgenerator trader (overrides)
      (let ((inst (mcp-lisp:default-generate-instance "trader" overrides)))
        (when (getf inst :suspended)
          (setf (getf inst :margin-ratio)
                (mcp-lisp:generate-value 'number :min 0.0 :max 0.5)))
        inst))
    (let ((results (mcp-lisp:run-pbt :trials 200)))
      (is (= 0 (getf (first results) :failed))))))

(test defgenerator-receives-overrides
  "custom generator receives overrides from generate-instance"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t))
    (mcp-lisp:defgenerator account (overrides)
      (let ((inst (mcp-lisp:default-generate-instance "account" overrides)))
        inst))
    (let ((inst (mcp-lisp:generate-instance "account" '((:balance . 99)))))
      (is (= 99 (getf inst :balance))))))

(test defgenerator-cleared-by-clear-specs
  "clear-specs removes custom generators"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:defgenerator account (overrides)
      (declare (ignore overrides))
      (list :balance 42))
    (is (= 42 (getf (mcp-lisp:generate-instance "account") :balance)))
    (mcp-lisp:clear-specs)
    ;; After clear, defentity again — should use default generator
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (let ((inst (mcp-lisp:generate-instance "account")))
      ;; Should be random, not 42 every time
      (is (numberp (getf inst :balance))))))

;;; ---------------------------------------------------------------------------
;;; Constraint extraction
;;; ---------------------------------------------------------------------------

(test extract-constraints-simple-bound
  "Extracts lower bound from (>= field 0)"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant non-negative
      :on account
      :check (>= (account-balance account) 0))
    (mcp-lisp:ensure-entity-accessors "account")
    (let ((constraints (mcp-lisp:extract-generation-constraints "account")))
      (is (not (null (gethash :balance constraints))))
      (let ((c (first (gethash :balance constraints))))
        (is (= 0 (getf c :min)))))))

(test extract-constraints-field-ordering
  "Extracts field upper bound from (< field-a field-b)"
  (with-fresh-specs
    (mcp-lisp:defentity range ()
      (lo number :required t)
      (hi number :required t))
    (mcp-lisp:definvariant lo-lt-hi
      :on range
      :check (< (range-lo range) (range-hi range)))
    (mcp-lisp:ensure-entity-accessors "range")
    (let* ((constraints (mcp-lisp:extract-generation-constraints "range"))
           (lo-cs (gethash :lo constraints)))
      (is (not (null lo-cs)))
      (is (eq :hi (getf (first lo-cs) :max-field))))))

(test extract-constraints-conditional
  "Extracts conditional constraints from (if (eq state :x) constraint t)"
  (with-fresh-specs
    (mcp-lisp:defentity machine ()
      (state (member :on :off) :default :off)
      (output number :default 0))
    (mcp-lisp:definvariant off-means-zero
      :on machine
      :check (if (not (eq (getf machine :state) :on))
                 (= (getf machine :output) 0)
                 t))
    (let* ((constraints (mcp-lisp:extract-generation-constraints "machine"))
           (out-cs (gethash :output constraints)))
      (is (not (null out-cs)))
      ;; Should have an :eq 0 with a :when condition
      (let ((c (first out-cs)))
        (is (= 0 (getf c :eq)))
        (is (not (null (getf c :when))))))))

(test extract-constraints-disjunction
  "Extracts conditional constraints from or-of-and pattern"
  (with-fresh-specs
    (mcp-lisp:defentity valve ()
      (state (member :open :closed) :default :closed)
      (flow number :default 0))
    (mcp-lisp:definvariant flow-matches-state
      :on valve
      :check (or (and (eq (getf valve :state) :open)
                      (> (getf valve :flow) 0))
                 (and (eq (getf valve :state) :closed)
                      (= (getf valve :flow) 0))))
    (let* ((constraints (mcp-lisp:extract-generation-constraints "valve"))
           (flow-cs (gethash :flow constraints)))
      ;; Should have two constraints: one for open (> 0), one for closed (= 0)
      (is (= 2 (length flow-cs))))))

(test constraint-aware-generation-simple
  "Default generator uses invariant constraints — no custom generator needed"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant non-negative
      :on account
      :check (>= (account-balance account) 0))
    ;; Without constraint extraction, ~50% would fail.
    ;; With extraction, all should pass.
    (let ((results (mcp-lisp:run-pbt :trials 200)))
      (is (= 0 (getf (first results) :failed))))))

(test constraint-aware-generation-state-dependent
  "Default generator handles state-dependent constraints"
  (with-fresh-specs
    (mcp-lisp:defentity machine ()
      (state (member :on :off) :default :off)
      (output number :default 0)
      (min-output number :required t)
      (max-output number :required t))
    (mcp-lisp:definvariant off-means-zero
      :on machine
      :check (if (not (eq (getf machine :state) :on))
                 (= (getf machine :output) 0)
                 t))
    (mcp-lisp:definvariant on-bounded
      :on machine
      :check (if (eq (getf machine :state) :on)
                 (and (>= (getf machine :output) (getf machine :min-output))
                      (<= (getf machine :output) (getf machine :max-output)))
                 t))
    (mcp-lisp:definvariant capacity-valid
      :on machine
      :check (and (> (getf machine :max-output) 0)
                  (>= (getf machine :min-output) 0)
                  (< (getf machine :min-output) (getf machine :max-output))))
    (let ((results (mcp-lisp:run-pbt :trials 200)))
      (is (= 0 (getf (first results) :failed))))))

(test constraint-aware-generation-member-conditional
  "Default generator handles member-conditional constraints"
  (with-fresh-specs
    (mcp-lisp:defentity vehicle ()
      (fuel (member :electric :gas :diesel))
      (emissions number :required t))
    (mcp-lisp:definvariant emissions-by-fuel
      :on vehicle
      :check (if (member (getf vehicle :fuel) '(:electric))
                 (= (getf vehicle :emissions) 0)
                 (> (getf vehicle :emissions) 0)))
    (let ((results (mcp-lisp:run-pbt :trials 200)))
      (is (= 0 (getf (first results) :failed))))))
