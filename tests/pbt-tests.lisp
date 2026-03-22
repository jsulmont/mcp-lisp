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
         (mcp-lisp/src/spec/spec::*generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*variants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenarios* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenario-generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*config* nil)
         (mcp-lisp/src/spec/spec::*current-config* nil))
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
    ;; (+ result a) = (* b b) — neither side is a single field access,
    ;; so the extractor can't assign a target field to constrain.
    (mcp-lisp:defentity triple ()
      (result number :required t)
      (a number :required t)
      (b number :required t))
    (mcp-lisp:definvariant cross-field-sum
      :on triple
      :check (= (+ (triple-result triple) (triple-a triple))
                (* (triple-b triple) (triple-b triple))))
    (let ((results (mcp-lisp:run-pbt :trials 200)))
      (is (= 1 (length results)))
      ;; Three independent random numbers almost never satisfy result + a = b²
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

;;; ---------------------------------------------------------------------------
;;; Variant generation
;;; ---------------------------------------------------------------------------

(test generate-instance-picks-variant
  "generate-instance for entity with variants sets discriminator and adds variant fields"
  (with-fresh-specs
    (mcp-lisp:defentity node ()
      (id string :required t)
      (kind (member :branch :leaf)))
    (mcp-lisp:defvariant branch (node :kind :branch)
      (children list :required t))
    (mcp-lisp:defvariant leaf (node :kind :leaf)
      (data list :required t))
    (mcp-lisp:ensure-entity-accessors "node")
    (mcp-lisp:ensure-variant-accessors "branch")
    (mcp-lisp:ensure-variant-accessors "leaf")
    (dotimes (i 50)
      (let ((inst (mcp-lisp:generate-instance "node")))
        ;; Must have base fields
        (is (stringp (getf inst :id)))
        (is (member (getf inst :kind) '(:branch :leaf)))
        ;; Must have variant-specific fields
        (cond
          ((eq (getf inst :kind) :branch)
           (is (not (null (member :children inst)))))
          ((eq (getf inst :kind) :leaf)
           (is (not (null (member :data inst))))))))))

(test variant-invariant-checking
  "check-invariants applies variant-specific invariants"
  (with-fresh-specs
    (mcp-lisp:defentity node ()
      (id string :required t)
      (kind (member :branch :leaf)))
    (mcp-lisp:defvariant branch (node :kind :branch)
      (count integer :required t))
    (mcp-lisp:definvariant branch-positive-count
      :on branch
      :check (> (branch-count branch) 0))
    (mcp-lisp:ensure-entity-accessors "node")
    (mcp-lisp:ensure-variant-accessors "branch")
    ;; Branch with positive count — should pass
    (is (null (mcp-lisp:check-invariants "node"
               '(:id "x" :kind :branch :count 5))))
    ;; Branch with zero count — should fail
    (let ((violations (mcp-lisp:check-invariants "node"
                        '(:id "x" :kind :branch :count 0))))
      (is (= 1 (length violations)))
      (is (string= "branch-positive-count" (first violations))))
    ;; Leaf — variant invariant should not apply
    (is (null (mcp-lisp:check-invariants "node"
               '(:id "x" :kind :leaf))))))

(test variant-pbt-all-pass
  "PBT with variants and variant invariants passes when generation is correct"
  (with-fresh-specs
    (mcp-lisp:defentity node ()
      (id string :required t)
      (kind (member :branch :leaf)))
    (mcp-lisp:defvariant branch (node :kind :branch)
      (depth integer :required t :min 0 :max 10))
    (mcp-lisp:defvariant leaf (node :kind :leaf)
      (value number :required t :min 0.0 :max 100.0))
    ;; Base invariant: id is non-empty
    (mcp-lisp:definvariant node-has-id
      :on node
      :check (> (length (node-id node)) 0))
    ;; Variant invariant: branch depth >= 0
    (mcp-lisp:definvariant branch-depth-valid
      :on branch
      :check (>= (branch-depth branch) 0))
    ;; Variant invariant: leaf value >= 0
    (mcp-lisp:definvariant leaf-value-valid
      :on leaf
      :check (>= (leaf-value leaf) 0))
    (let ((results (mcp-lisp:run-pbt :trials 200)))
      (is (= 1 (length results)))
      (is (= 0 (getf (first results) :failed))))))

;;; ---------------------------------------------------------------------------
;;; Config generation
;;; ---------------------------------------------------------------------------

(test generate-config-produces-plist
  "generate-config returns a plist with all config fields"
  (with-fresh-specs
    (mcp-lisp:defconfig
      (max-leverage number :min 1.0 :max 100.0)
      (max-positions integer :min 1 :max 1000)
      (allow-short boolean))
    (dotimes (i 20)
      (let ((cfg (mcp-lisp:generate-config)))
        (is (numberp (getf cfg :max-leverage)))
        (is (>= (getf cfg :max-leverage) 1.0))
        (is (< (getf cfg :max-leverage) 100.0))
        (is (integerp (getf cfg :max-positions)))
        (is (>= (getf cfg :max-positions) 1))
        (is (<= (getf cfg :max-positions) 1000))))))

(test config-accessor-reads-current-config
  "config function reads from *current-config*"
  (with-fresh-specs
    (let ((mcp-lisp/src/spec/spec::*current-config*
            '(:max-leverage 25.0 :margin 0.5)))
      (is (= 25.0 (mcp-lisp:config :max-leverage)))
      (is (= 0.5 (mcp-lisp:config :margin)))
      (is (null (mcp-lisp:config :nonexistent))))))

(test config-aware-pbt-all-pass
  "PBT with config generates random configs and checks invariants across config space"
  (with-fresh-specs
    (mcp-lisp:defentity position ()
      (leverage number :required t :min 0.0 :max 200.0))
    (mcp-lisp:defconfig
      (max-leverage number :default 10.0 :min 1.0 :max 100.0))
    (mcp-lisp:definvariant leverage-bounded
      :on position
      :check (<= (position-leverage position) (mcp-lisp:config :max-leverage)))
    (let ((results (mcp-lisp:run-pbt :trials 50 :config-trials 5)))
      (is (= 1 (length results)))
      (is (= 0 (getf (first results) :failed))))))

(test config-aware-pbt-no-config-still-works
  "run-pbt with :config-trials works normally when no config is defined"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t :min 0.0 :max 1000.0))
    (mcp-lisp:definvariant non-negative
      :on account
      :check (>= (account-balance account) 0))
    (let ((results (mcp-lisp:run-pbt :trials 50 :config-trials 3)))
      (is (= 1 (length results)))
      ;; Without config, only one round of trials
      (is (= 50 (getf (first results) :trials)))
      (is (= 0 (getf (first results) :failed))))))

;;; ---------------------------------------------------------------------------
;;; Scenario PBT
;;; ---------------------------------------------------------------------------

(test scenario-default-generation
  "default-generate-scenario produces instances for all bindings"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t :min 0 :max 1000))
    (mcp-lisp:defentity txn ()
      (id string :required t)
      (amount number :required t :min 1 :max 100)
      (:belongs-to account))
    (mcp-lisp:defscenario ledger
      :entities ((accounts (2 3) account)
                 (txns (1 2) txn :per accounts)))
    (mcp-lisp:ensure-entity-accessors "account")
    (mcp-lisp:ensure-entity-accessors "txn")
    (let ((instance (mcp-lisp:default-generate-scenario "ledger")))
      ;; Has both bindings
      (is (not (null (getf instance :accounts))))
      (is (not (null (getf instance :txns))))
      ;; Accounts is a list of 2-3
      (is (listp (getf instance :accounts)))
      (is (<= 2 (length (getf instance :accounts)) 3))
      ;; Each account is a plist with :id and :balance
      (dolist (a (getf instance :accounts))
        (is (stringp (getf a :id)))
        (is (numberp (getf a :balance))))
      ;; Txns generated per-account
      (is (listp (getf instance :txns)))
      (is (>= (length (getf instance :txns)) 2)))))

(test scenario-exact-cardinality-one
  "cardinality=1 produces a single instance, not a list"
  (with-fresh-specs
    (mcp-lisp:defentity config-entity ()
      (name string :required t))
    (mcp-lisp:defscenario singleton
      :entities ((cfg 1 config-entity)))
    (mcp-lisp:ensure-entity-accessors "config-entity")
    (let ((instance (mcp-lisp:default-generate-scenario "singleton")))
      ;; Single instance, not a list
      (is (stringp (getf (getf instance :cfg) :name))))))

(test scenario-invariant-passing
  "scenario invariant that passes"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t :min 0 :max 1000))
    (mcp-lisp:defscenario bank
      :entities ((accounts (2 5) account)))
    (mcp-lisp:definvariant at-least-two-accounts
      :on bank
      :check (>= (length accounts) 2))
    (mcp-lisp:ensure-entity-accessors "account")
    (let ((violations (mcp-lisp:check-scenario-invariants
                       "bank"
                       (mcp-lisp:generate-scenario "bank"))))
      (is (null violations)))))

(test scenario-invariant-failing
  "scenario invariant that fails"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t :min 0 :max 1000))
    (mcp-lisp:defscenario bank
      :entities ((accounts (2 5) account)))
    ;; Impossible invariant: no way to have 100 accounts with max 5
    (mcp-lisp:definvariant too-many-accounts
      :on bank
      :check (>= (length accounts) 100))
    (mcp-lisp:ensure-entity-accessors "account")
    (let ((violations (mcp-lisp:check-scenario-invariants
                       "bank"
                       (mcp-lisp:generate-scenario "bank"))))
      (is (= 1 (length violations)))
      (is (string= "too-many-accounts" (first violations))))))

(test scenario-custom-generator
  "defscenario-generator overrides default generation"
  (with-fresh-specs
    (mcp-lisp:defentity item ()
      (id string :required t)
      (value number :required t))
    (mcp-lisp:defscenario custom-test
      :entities ((items (2 4) item)))
    ;; Custom generator always produces exactly 3 items with value=42
    (mcp-lisp:defscenario-generator custom-test (overrides)
      (declare (ignore overrides))
      (list :items (list (list :id "a" :value 42)
                         (list :id "b" :value 42)
                         (list :id "c" :value 42))))
    (mcp-lisp:definvariant all-42
      :on custom-test
      :check (every (lambda (i) (= 42 (getf i :value))) items))
    (mcp-lisp:ensure-entity-accessors "item")
    (let ((instance (mcp-lisp:generate-scenario "custom-test")))
      (is (= 3 (length (getf instance :items))))
      (is (null (mcp-lisp:check-scenario-invariants "custom-test" instance))))))

(test scenario-run-pbt
  "run-pbt with :scenario runs scenario trials"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t :min 0 :max 1000))
    (mcp-lisp:defscenario bank
      :entities ((accounts (2 5) account)))
    (mcp-lisp:definvariant at-least-two
      :on bank
      :check (>= (length accounts) 2))
    (let ((results (mcp-lisp:run-pbt :scenario "bank" :trials 20)))
      (is (= 1 (length results)))
      (is (string= "scenario:bank" (getf (first results) :entity)))
      (is (= 0 (getf (first results) :failed))))))

(test scenario-run-pbt-entity-invariants-checked
  "scenario PBT also checks per-entity invariants on generated instances"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t :min 0 :max 1000))
    (mcp-lisp:definvariant non-negative
      :on account
      :check (>= (account-balance account) 0))
    (mcp-lisp:defscenario bank
      :entities ((accounts (2 3) account)))
    ;; Trivial scenario invariant
    (mcp-lisp:definvariant has-accounts
      :on bank
      :check (> (length accounts) 0))
    ;; This should pass since generated accounts have balance >= 0
    (let ((results (mcp-lisp:run-pbt :scenario "bank" :trials 30)))
      (is (= 1 (length results)))
      (is (= 0 (getf (first results) :failed))))))

(test scenario-cross-entity-invariant
  "scenario invariant that checks relationships across entities"
  (with-fresh-specs
    (mcp-lisp:defentity warehouse ()
      (id string :required t)
      (capacity number :required t :min 100 :max 500))
    (mcp-lisp:defentity product ()
      (id string :required t)
      (stock number :required t :min 0 :max 50))
    (mcp-lisp:defscenario inventory
      :entities ((warehouses (1 2) warehouse)
                 (products (3 6) product :per warehouses)))
    ;; Invariant: each warehouse has at least 3 products
    (mcp-lisp:definvariant min-products-per-warehouse
      :on inventory
      :check (>= (length products) (* 3 (length warehouses))))
    (mcp-lisp:ensure-entity-accessors "warehouse")
    (mcp-lisp:ensure-entity-accessors "product")
    (let ((results (mcp-lisp:run-pbt :scenario "inventory" :trials 30)))
      (is (= 1 (length results)))
      (is (= 0 (getf (first results) :failed))))))
