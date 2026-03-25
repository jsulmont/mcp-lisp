;;;; tests/analysis-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite analysis-tests
  :description "Tests for spec analysis tools"
  :in mcp-lisp-tests)

(in-suite analysis-tests)

(defmacro with-fresh-analysis-specs (&body body)
  `(let ((mcp-lisp/src/spec/spec::*entities* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*rules* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*invariants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*variants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenarios* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenario-generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*compiled-fn-cache* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*config* nil)
         (mcp-lisp/src/spec/spec::*current-config* nil))
     ,@body))

;;; ---------------------------------------------------------------------------
;;; invariant-coverage-summary
;;; ---------------------------------------------------------------------------

(test coverage-summary-empty-spec
  "No entities yields empty summary"
  (with-fresh-analysis-specs
    (is (null (mcp-lisp:invariant-coverage-summary)))))

(test coverage-summary-single-entity-no-invariants
  "Entity with no invariants has zero coverage"
  (with-fresh-analysis-specs
    (mcp-lisp:defentity widget ()
      (id string :required t)
      (name string :required t)
      (weight number))
    (let* ((summary (mcp-lisp:invariant-coverage-summary))
           (entry (first summary)))
      (is (= 1 (length summary)))
      (is (string= "widget" (getf entry :entity)))
      (is (= 3 (getf entry :fields)))
      (is (= 0 (getf entry :covered)))
      (is (= 3 (getf entry :uncovered)))
      (is (< (getf entry :ratio) 0.01))
      (is (= 3 (length (getf entry :uncovered-fields)))))))

(test coverage-summary-full-coverage
  "Entity where all fields are covered has ratio 1.0"
  (with-fresh-analysis-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t))
    (mcp-lisp:definvariant pos-balance
      :on account
      :check (>= (account-balance account) 0))
    (mcp-lisp:definvariant has-id
      :on account
      :check (account-id account))
    (let* ((summary (mcp-lisp:invariant-coverage-summary))
           (entry (first summary)))
      (is (= 1 (length summary)))
      (is (= 2 (getf entry :fields)))
      (is (= 2 (getf entry :covered)))
      (is (= 0 (getf entry :uncovered)))
      (is (> (getf entry :ratio) 0.99)))))

(test coverage-summary-partial-coverage
  "Partial coverage reports correct counts and uncovered fields"
  (with-fresh-analysis-specs
    (mcp-lisp:defentity sensor ()
      (id string :required t)
      (reading number :required t)
      (name string :required t))
    (mcp-lisp:definvariant positive-reading
      :on sensor
      :check (>= (sensor-reading sensor) 0))
    (let* ((summary (mcp-lisp:invariant-coverage-summary))
           (entry (first summary)))
      (is (= 3 (getf entry :fields)))
      (is (= 1 (getf entry :covered)))
      (is (= 2 (getf entry :uncovered)))
      (is (member :id (getf entry :uncovered-fields)))
      (is (member :name (getf entry :uncovered-fields)))
      (is (not (member :reading (getf entry :uncovered-fields)))))))

(test coverage-summary-sorted-worst-first
  "Summary is sorted by ratio ascending (worst coverage first)"
  (with-fresh-analysis-specs
    (mcp-lisp:defentity alpha ()
      (id string :required t)
      (x number :required t))
    (mcp-lisp:definvariant alpha-x
      :on alpha
      :check (>= (alpha-x alpha) 0))
    (mcp-lisp:defentity beta ()
      (id string :required t)
      (y number :required t)
      (z number :required t))
    ;; beta has 0 invariants → worst coverage
    (let* ((summary (mcp-lisp:invariant-coverage-summary))
           (first-entry (first summary))
           (second-entry (second summary)))
      (is (= 2 (length summary)))
      (is (<= (getf first-entry :ratio)
              (getf second-entry :ratio)))
      ;; beta (0/3 = 0.0) should come before alpha (1/2 = 0.5)
      (is (string= "beta" (getf first-entry :entity))))))

(test coverage-summary-multiple-invariants-per-field
  "A field covered by multiple invariants still counts as one covered field"
  (with-fresh-analysis-specs
    (mcp-lisp:defentity tank ()
      (id string :required t)
      (level number :required t))
    (mcp-lisp:definvariant level-min
      :on tank
      :check (>= (tank-level tank) 0))
    (mcp-lisp:definvariant level-max
      :on tank
      :check (<= (tank-level tank) 100))
    (let* ((summary (mcp-lisp:invariant-coverage-summary))
           (entry (first summary)))
      (is (= 1 (getf entry :covered)))
      (is (= 1 (getf entry :uncovered))))))
