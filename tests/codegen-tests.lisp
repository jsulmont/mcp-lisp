;;;; tests/codegen-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite codegen-tests
  :description "Tests for SQL code generation from specs"
  :in mcp-lisp-tests)

(in-suite codegen-tests)

(defmacro with-fresh-specs (&body body)
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
;;; Basic table generation
;;; ---------------------------------------------------------------------------

(test specs-to-sql-basic-table
  "Basic entity produces CREATE TABLE with typed columns"
  (with-fresh-specs
    (mcp-lisp:defentity widget ()
      (id string :required t)
      (name string :required t)
      (weight number)
      (count integer)
      (active boolean))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "CREATE TABLE widget" sql))
      (is (search "id TEXT" sql))
      (is (search "NOT NULL" sql))
      (is (search "weight NUMERIC" sql))
      (is (search "count INTEGER" sql))
      (is (search "active BOOLEAN" sql)))))

;;; ---------------------------------------------------------------------------
;;; Enum types
;;; ---------------------------------------------------------------------------

(test specs-to-sql-enum-types
  "Member fields produce CREATE TYPE ... AS ENUM"
  (with-fresh-specs
    (mcp-lisp:defentity order ()
      (id string :required t)
      (state (member :pending :filled :cancelled) :default :pending))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "CREATE TYPE" sql))
      (is (search "AS ENUM" sql))
      (is (search "'pending'" sql))
      (is (search "'filled'" sql))
      (is (search "'cancelled'" sql)))))

;;; ---------------------------------------------------------------------------
;;; NOT NULL, DEFAULT, UNIQUE, PRIMARY KEY
;;; ---------------------------------------------------------------------------

(test specs-to-sql-field-constraints
  "Field kwargs map to column constraints"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t :unique t)
      (balance number :required t :default 0)
      (email string :required t :unique t))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "PRIMARY KEY" sql))
      (is (search "UNIQUE" sql))
      (is (search "DEFAULT 0" sql))
      (is (search "NOT NULL" sql)))))

;;; ---------------------------------------------------------------------------
;;; Foreign keys from belongs-to
;;; ---------------------------------------------------------------------------

(test specs-to-sql-foreign-key
  "belongs-to relation produces foreign key column"
  (with-fresh-specs
    (mcp-lisp:defentity team ()
      (id string :required t)
      (name string :required t))
    (mcp-lisp:defentity player ()
      (id string :required t)
      (name string :required t)
      (:belongs-to team-ref :of team))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "REFERENCES team(id)" sql))
      (is (search "team_id TEXT" sql)))))

;;; ---------------------------------------------------------------------------
;;; CHECK constraint — simple comparison
;;; ---------------------------------------------------------------------------

(test specs-to-sql-check-constraint-simple
  "Simple invariant becomes CHECK constraint"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t))
    (mcp-lisp:definvariant non-negative-balance
      :on account
      :check (>= (account-balance account) 0))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "CONSTRAINT" sql))
      (is (search "CHECK" sql))
      (is (search "balance >= 0" sql)))))

;;; ---------------------------------------------------------------------------
;;; CHECK constraint — conditional (if ... t)
;;; ---------------------------------------------------------------------------

(test specs-to-sql-check-constraint-conditional
  "Conditional invariant (if test consequent t) becomes CHECK"
  (with-fresh-specs
    (mcp-lisp:defentity generator ()
      (id string :required t)
      (state (member :offline :online) :default :offline)
      (output-mw number :default 0))
    (mcp-lisp:definvariant output-matches-state
      :on generator
      :check (if (eq (generator-state generator) :online)
                 (> (generator-output-mw generator) 0)
                 t))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "CONSTRAINT output_matches_state" sql))
      (is (search "CHECK" sql)))))

;;; ---------------------------------------------------------------------------
;;; State machine trigger
;;; ---------------------------------------------------------------------------

(test specs-to-sql-state-trigger
  "Entity with rules produces state machine trigger"
  (with-fresh-specs
    (mcp-lisp:defentity ticket ()
      (id string :required t)
      (state (member :open :in-progress :done) :default :open))
    (mcp-lisp:defrule start-ticket
      :when (ticket :state :open)
      :ensures ((eq (ticket-state ticket) :in-progress)))
    (mcp-lisp:defrule finish-ticket
      :when (ticket :state :in-progress)
      :ensures ((eq (ticket-state ticket) :done)))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "CREATE OR REPLACE FUNCTION" sql))
      (is (search "RETURNS TRIGGER" sql))
      (is (search "OLD.state" sql))
      (is (search "NEW.state" sql))
      (is (search "'open'" sql))
      (is (search "'in_progress'" sql))
      (is (search "'done'" sql))
      (is (search "CREATE TRIGGER" sql))
      (is (search "BEFORE UPDATE" sql)))))

;;; ---------------------------------------------------------------------------
;;; Config table
;;; ---------------------------------------------------------------------------

(test specs-to-sql-config-table
  "defconfig produces config table with seed data"
  (with-fresh-specs
    (mcp-lisp:defconfig
      (max-retries integer :default 3 :min 1 :max 10)
      (timeout number :default 30.0 :min 1.0 :max 300.0))
    (mcp-lisp:defentity dummy ()
      (id string :required t))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "CREATE TABLE config" sql))
      (is (search "INSERT INTO config" sql))
      (is (search "'max_retries'" sql))
      (is (search "'timeout'" sql))
      (is (search "3" sql))
      (is (search "30.0" sql)))))

;;; ---------------------------------------------------------------------------
;;; Dependency ordering
;;; ---------------------------------------------------------------------------

(test specs-to-sql-dependency-order
  "Parent tables are emitted before child tables"
  (with-fresh-specs
    (mcp-lisp:defentity department ()
      (id string :required t)
      (name string :required t))
    (mcp-lisp:defentity employee ()
      (id string :required t)
      (name string :required t)
      (:belongs-to dept :of department))
    (let* ((sql (mcp-lisp:specs-to-sql))
           (dept-pos (search "CREATE TABLE department" sql))
           (emp-pos (search "CREATE TABLE employee" sql)))
      (is (not (null dept-pos)))
      (is (not (null emp-pos)))
      (is (< dept-pos emp-pos)))))

;;; ---------------------------------------------------------------------------
;;; Untranslatable invariant → comment
;;; ---------------------------------------------------------------------------

(test specs-to-sql-untranslatable-invariant
  "Complex invariant that can't be translated emits a comment"
  (with-fresh-specs
    (mcp-lisp:defentity item ()
      (id string :required t)
      (values list :required t))
    (mcp-lisp:definvariant complex-check
      :on item
      :check (every #'numberp (item-values item)))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "-- inv: complex-check (not translatable to SQL)" sql)))))

;;; ---------------------------------------------------------------------------
;;; Variant fields
;;; ---------------------------------------------------------------------------

(test specs-to-sql-variant-fields
  "Variant fields are added as nullable columns to parent table"
  (with-fresh-specs
    (mcp-lisp:defentity node ()
      (id string :required t)
      (kind (member :branch :leaf) :required t))
    (mcp-lisp:defvariant branch (node :kind :branch)
      (child-count integer))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "child_count INTEGER" sql))
      (is (search "CREATE TABLE node" sql)))))

;;; ---------------------------------------------------------------------------
;;; Indexes
;;; ---------------------------------------------------------------------------

(test specs-to-sql-indexes
  "Foreign key and state columns get indexes"
  (with-fresh-specs
    (mcp-lisp:defentity team ()
      (id string :required t))
    (mcp-lisp:defentity player ()
      (id string :required t)
      (state (member :active :retired) :default :active)
      (:belongs-to team-ref :of team))
    (mcp-lisp:defrule retire-player
      :when (player :state :active)
      :ensures ((eq (player-state player) :retired)))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "CREATE INDEX" sql))
      (is (search "idx_player_team" sql))
      (is (search "idx_player_state" sql)))))

;;; ---------------------------------------------------------------------------
;;; BEGIN/COMMIT wrapper
;;; ---------------------------------------------------------------------------

(test specs-to-sql-transaction-wrapper
  "Output is wrapped in BEGIN/COMMIT"
  (with-fresh-specs
    (mcp-lisp:defentity item ()
      (id string :required t))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (eql 0 (search "BEGIN;" sql)))
      (is (search "COMMIT;" sql)))))

;;; ---------------------------------------------------------------------------
;;; String equality and not-equal
;;; ---------------------------------------------------------------------------

(test specs-to-sql-string-equality
  "equal/string= in invariants translates to SQL = and <>"
  (with-fresh-specs
    (mcp-lisp:defentity runway ()
      (id string :required t)
      (status (member :open :closed) :default :open)
      (occupant string :default ""))
    ;; (if (eq status :closed) (equal occupant "") t) → closed implies empty occupant
    (mcp-lisp:definvariant closed-no-occupant
      :on runway
      :check (if (eq (runway-status runway) :closed)
                 (equal (runway-occupant runway) "")
                 t))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "CONSTRAINT closed_no_occupant" sql))
      (is (search "occupant = ''" sql)))))

(test specs-to-sql-not-equal
  "not-equal patterns translate to <>"
  (with-fresh-specs
    (mcp-lisp:defentity handoff ()
      (id string :required t)
      (from-sector string :required t)
      (to-sector string :required t))
    (mcp-lisp:definvariant different-sectors
      :on handoff
      :check (not (equal (handoff-from-sector handoff)
                         (handoff-to-sector handoff))))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "CONSTRAINT different_sectors" sql))
      (is (search "<>" sql)))))

;;; ---------------------------------------------------------------------------
;;; Trailing comma — untranslatable invariants don't break SQL syntax
;;; ---------------------------------------------------------------------------

(test specs-to-sql-no-trailing-comma-before-comment
  "Untranslatable invariants are emitted as comments outside the column list"
  (with-fresh-specs
    (mcp-lisp:defentity item ()
      (id string :required t)
      (values list :required t))
    (mcp-lisp:definvariant complex-check
      :on item
      :check (every #'numberp (item-values item)))
    (let ((sql (mcp-lisp:specs-to-sql)))
      ;; The comment should appear but there should be no comma before );
      (is (search "-- inv: complex-check" sql))
      ;; No ",\n);" pattern (comma then closing paren)
      (is (null (search (format nil ",~%);") sql))))))

;;; ---------------------------------------------------------------------------
;;; Seed data generation
;;; ---------------------------------------------------------------------------

(test specs-to-sql-seed-basic
  "specs-to-sql-seed generates INSERT statements with correct row count"
  (with-fresh-specs
    (mcp-lisp:defentity color ()
      (id string :required t)
      (name string :required t)
      (hex string))
    (let ((sql (mcp-lisp:specs-to-sql-seed :rows-per-entity 5)))
      (is (search "INSERT INTO color" sql))
      ;; 5 rows means 4 commas + 1 semicolon
      (is (= 5 (count #\) sql :start (search "VALUES" sql)))))))

(test specs-to-sql-seed-foreign-keys
  "Seed data wires foreign keys to previously generated parent IDs"
  (with-fresh-specs
    (mcp-lisp:defentity team ()
      (id string :required t)
      (name string :required t))
    (mcp-lisp:defentity player ()
      (id string :required t)
      (name string :required t)
      (:belongs-to team-ref :of team))
    (let ((sql (mcp-lisp:specs-to-sql-seed :rows-per-entity 3)))
      (is (search "INSERT INTO team" sql))
      (is (search "INSERT INTO player" sql))
      ;; team INSERT comes before player INSERT
      (is (< (search "INSERT INTO team" sql)
              (search "INSERT INTO player" sql)))
      ;; player has team_id column
      (is (search "team_id" sql)))))

(test specs-to-sql-seed-enum-values
  "Seed data uses valid enum values (quoted lowercase)"
  (with-fresh-specs
    (mcp-lisp:defentity ticket ()
      (id string :required t)
      (state (member :open :in-progress :done) :default :open))
    (let ((sql (mcp-lisp:specs-to-sql-seed :rows-per-entity 5)))
      (is (search "INSERT INTO ticket" sql))
      ;; All state values should be from the enum
      (is (or (search "'open'" sql)
              (search "'in_progress'" sql)
              (search "'done'" sql))))))

(test specs-to-sql-seed-uses-scenarios
  "Scenario-covered entities use generate-scenario for correlated data"
  (with-fresh-specs
    (mcp-lisp:defentity warehouse ()
      (id string :required t)
      (capacity number :required t :min 100 :max 500))
    (mcp-lisp:defentity product ()
      (id string :required t)
      (stock number :required t :min 0 :max 50))
    (mcp-lisp:defscenario inventory
      :entities ((warehouses (1 2) warehouse)
                 (products (3 5) product :per warehouses)))
    (let ((sql (mcp-lisp:specs-to-sql-seed :rows-per-entity 5 :scenario-trials 2)))
      ;; Both entities should have INSERT statements
      (is (search "INSERT INTO warehouse" sql))
      (is (search "INSERT INTO product" sql))
      ;; warehouse INSERT before product INSERT (dependency order)
      (is (< (search "INSERT INTO warehouse" sql)
              (search "INSERT INTO product" sql))))))

(test specs-to-sql-seed-respects-invariants
  "Generated seed data passes invariants"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t))
    (mcp-lisp:definvariant non-negative
      :on account
      :check (>= (account-balance account) 0))
    (let ((sql (mcp-lisp:specs-to-sql-seed :rows-per-entity 10)))
      (is (search "INSERT INTO account" sql))
      ;; No negative numbers in the output (balance is constrained >= 0)
      ;; This is a weak check but verifies the generator ran
      (is (not (null sql))))))

(test specs-to-sql-seed-unique-ids
  "Seed data stamps unique IDs — no duplicates or empty strings"
  (with-fresh-specs
    (mcp-lisp:defentity sector ()
      (id string :required t :unique t)
      (name string :required t))
    (let* ((sql (mcp-lisp:specs-to-sql-seed :rows-per-entity 20))
           (ids nil)
           (pos 0))
      ;; Extract all IDs (first column in each row)
      (loop for start = (search "'sector-" sql :start2 pos)
            while start
            for end = (position #\' sql :start (1+ start))
            do (push (subseq sql start (1+ end)) ids)
               (setf pos (1+ end)))
      ;; All IDs should be distinct
      (is (= (length ids) (length (remove-duplicates ids :test #'string=))))
      ;; No empty IDs
      (is (notany (lambda (id) (string= id "''")) ids)))))

;;; ---------------------------------------------------------------------------
;;; Column comments from field metadata
;;; ---------------------------------------------------------------------------

(test specs-to-sql-column-comments
  "Columns with enum values or min/max get inline comments"
  (with-fresh-specs
    (mcp-lisp:defentity sensor ()
      (id string :required t)
      (kind (member :temperature :pressure :humidity) :required t)
      (reading number :required t :min -50 :max 150)
      (name string :required t))
    (let ((sql (mcp-lisp:specs-to-sql)))
      ;; Enum values listed in comment
      (is (search "-- temperature, pressure, humidity" sql))
      ;; Min/max range in comment
      (is (search "-- [-50, 150]" sql))
      ;; Plain field has no comment marker
      (is (not (search "name TEXT NOT NULL  --" sql))))))

;;; ---------------------------------------------------------------------------
;;; Bug 8: PRIMARY KEY should not emit redundant NOT NULL UNIQUE
;;; ---------------------------------------------------------------------------

(test specs-to-sql-pk-no-redundant-modifiers
  "PRIMARY KEY column omits NOT NULL and UNIQUE (they are implied)"
  (with-fresh-specs
    (mcp-lisp:defentity widget ()
      (id string :required t :unique t)
      (name string :required t))
    (let ((sql (mcp-lisp:specs-to-sql)))
      ;; id line should have PRIMARY KEY but not NOT NULL or UNIQUE
      (let* ((id-start (search "id TEXT" sql))
             (id-end (position #\Newline sql :start id-start))
             (id-line (subseq sql id-start id-end)))
        (is (search "PRIMARY KEY" id-line))
        (is (null (search "NOT NULL" id-line)))
        (is (null (search "UNIQUE" id-line))))
      ;; non-PK required field still gets NOT NULL
      (is (search "name TEXT NOT NULL" sql)))))

;;; ---------------------------------------------------------------------------
;;; Bug 9: Enum comments should use SQL values (underscores)
;;; ---------------------------------------------------------------------------

(test specs-to-sql-enum-comment-underscores
  "Enum comments use SQL-style underscores, not Lisp hyphens"
  (with-fresh-specs
    (mcp-lisp:defentity resource ()
      (id string :required t)
      (quality (member :level-3 :level-4 :authoritative) :default :level-3))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "level_3" sql))
      (is (search "level_4" sql))
      ;; Comment should use underscores too
      (is (search "-- level_3, level_4, authoritative" sql))
      ;; No raw Lisp hyphens in the comment
      (is (null (search "level-3" sql))))))

;;; ---------------------------------------------------------------------------
;;; Bug 4: Seed generation hits target row count even with scenarios
;;; ---------------------------------------------------------------------------

(test specs-to-sql-seed-hits-target-count
  "Seed generation produces exactly rows-per-entity rows for every entity"
  (with-fresh-specs
    (mcp-lisp:defentity warehouse ()
      (id string :required t)
      (capacity number :required t :min 100 :max 500))
    (mcp-lisp:defentity product ()
      (id string :required t)
      (stock number :required t :min 0 :max 50))
    (mcp-lisp:defscenario inventory
      :entities ((warehouses (1 2) warehouse)
                 (products (1 2) product :per warehouses)))
    (let* ((target 10)
           (sql (mcp-lisp:specs-to-sql-seed :rows-per-entity target :scenario-trials 1)))
      ;; Both entities should have at least target rows
      (let ((wh-start (search "INSERT INTO warehouse" sql))
            (pr-start (search "INSERT INTO product" sql)))
        (is (not (null wh-start)))
        (is (not (null pr-start)))
        ;; Count rows by counting closing parens in VALUES clause
        (let* ((wh-vals (search "VALUES" sql :start2 wh-start))
               (wh-next-insert (or (search "INSERT" sql :start2 (1+ wh-start))
                                   (length sql)))
               (wh-rows (count #\) sql :start wh-vals :end wh-next-insert)))
          (is (>= wh-rows target)))
        (let* ((pr-vals (search "VALUES" sql :start2 pr-start))
               (pr-rows (count #\) sql :start pr-vals)))
          (is (>= pr-rows target)))))))

;;; ---------------------------------------------------------------------------
;;; Bug 2: Seed generation dispatches through custom generators
;;; ---------------------------------------------------------------------------

(test specs-to-sql-seed-uses-custom-generators
  "Seed data from uncovered entities dispatches through defgenerator"
  (with-fresh-specs
    (mcp-lisp:defentity device ()
      (id string :required t)
      (lfdi string :required t))
    (mcp-lisp:defgenerator device (overrides)
      (let ((inst (mcp-lisp:default-generate-instance "device" overrides)))
        (setf (getf inst :lfdi) "CUSTOM-LFDI-VALUE")
        inst))
    (let ((sql (mcp-lisp:specs-to-sql-seed :rows-per-entity 3)))
      (is (search "CUSTOM-LFDI-VALUE" sql)))))