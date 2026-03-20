;;;; tests/pbt-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite pbt-tests
  :description "Tests for spec property-based testing"
  :in mcp-lisp-tests)

(in-suite pbt-tests)

(defmacro with-fresh-specs (&body body)
  `(let ((mcp-lisp/src/spec/spec::*entities* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*rules* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*invariants* (make-hash-table :test #'equal)))
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
    (mcp-lisp:defentity account ()
      (balance number :required t))
    ;; This will fail for negative balances (which generate-value produces)
    (mcp-lisp:definvariant non-negative
      :on account
      :check (>= (account-balance account) 0))
    (let ((results (mcp-lisp:run-pbt :trials 200)))
      (is (= 1 (length results)))
      ;; With range [-1000, 1000], roughly half should fail
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
