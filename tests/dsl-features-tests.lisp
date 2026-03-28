;;;; tests/dsl-features-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite dsl-features-tests
  :description "Tests for DSL features: immutable fields, temporal helpers, refs, cardinality, reqs"
  :in mcp-lisp-tests)

(in-suite dsl-features-tests)

(defmacro with-fresh-specs (&body body)
  `(let ((mcp-lisp/src/spec/spec::*entities* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*rules* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*invariants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*generator-sources* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*variants* (make-hash-table :test #'equal))
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
;;; Feature 1: Immutable fields
;;; ===========================================================================

(test immutable-field-stored
  "defentity stores :immutable metadata on fields"
  (with-fresh-specs
    (mcp-lisp:defentity event ()
      (id string :required t)
      (creation-time number :required t :immutable t)
      (label string))
    (let* ((fields (mcp-lisp:entity-fields "event"))
           (ct-field (find 'creation-time fields :key #'first)))
      (is (not (null ct-field)))
      (is (eq t (getf (cddr ct-field) :immutable))))))

(test immutable-field-apply-rule-rejects
  "apply-rule rejects :sets on an immutable field when value already set"
  (with-fresh-specs
    (mcp-lisp:defentity event ()
      (id string :required t)
      (state (member :pending :active) :default :pending)
      (creation-time number :required t :immutable t))
    (mcp-lisp:defrule activate-event
      :when (event :state :pending)
      :sets ((event-creation-time event) 999)
      :ensures ((eq (event-state event) :active)))
    (mcp-lisp:ensure-entity-accessors "event")
    (let ((inst '(:id "e1" :state :pending :creation-time 100)))
      (multiple-value-bind (new applied reason)
          (mcp-lisp:apply-rule "event" inst "activate-event")
        (declare (ignore new))
        (is (null applied))
        (is (eq :immutable-violation (first reason)))
        (is (eq :creation-time (second reason)))))))

(test immutable-field-apply-rule-allows-initial
  "apply-rule allows :sets on an immutable field when value is nil (initial)"
  (with-fresh-specs
    (mcp-lisp:defentity event ()
      (id string :required t)
      (state (member :pending :active) :default :pending)
      (creation-time number :immutable t))
    (mcp-lisp:defrule activate-event
      :when (event :state :pending)
      :sets ((event-creation-time event) 42)
      :ensures ((eq (event-state event) :active)))
    (mcp-lisp:ensure-entity-accessors "event")
    (let ((inst '(:id "e1" :state :pending :creation-time nil)))
      (multiple-value-bind (_new applied _reason)
          (mcp-lisp:apply-rule "event" inst "activate-event")
        (is (not (null applied)))))))

(test immutable-field-validate-specs-warns
  "validate-specs warns when a rule :sets an immutable field"
  (with-fresh-specs
    (mcp-lisp:defentity event ()
      (id string :required t)
      (state (member :pending :active) :default :pending)
      (creation-time number :required t :immutable t))
    (mcp-lisp:defrule modify-time
      :when (event :state :active)
      :sets ((event-creation-time event) 999)
      :ensures ((eq (event-state event) :active)))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (some (lambda (w) (search "immutable" w)) warnings)))))

(test immutable-field-codegen-trigger
  "specs-to-sql emits an immutability trigger for :immutable fields"
  (with-fresh-specs
    (mcp-lisp:defentity event ()
      (id string :required t)
      (creation-time number :required t :immutable t)
      (name string))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "check_event_immutable" sql))
      (is (search "creation_time IS DISTINCT FROM" sql))
      (is (search "field creation_time is immutable" sql)))))

;;; ===========================================================================
;;; Feature 2: Temporal interval helpers
;;; ===========================================================================

(test intervals-overlap-p-basic
  "intervals-overlap-p detects overlapping intervals"
  (is (mcp-lisp:intervals-overlap-p 0 10 5 10))
  (is (mcp-lisp:intervals-overlap-p 5 10 0 10))
  (is (not (mcp-lisp:intervals-overlap-p 0 5 5 5)))
  (is (not (mcp-lisp:intervals-overlap-p 0 5 10 5))))

(test interval-contains-p-basic
  "interval-contains-p detects containment"
  (is (mcp-lisp:interval-contains-p 0 20 5 10))
  (is (mcp-lisp:interval-contains-p 0 10 0 10))
  (is (not (mcp-lisp:interval-contains-p 5 5 0 10)))
  (is (not (mcp-lisp:interval-contains-p 0 10 5 10))))

(test interval-before-p-basic
  "interval-before-p detects non-overlapping ordering"
  (is (mcp-lisp:interval-before-p 0 5 5))
  (is (mcp-lisp:interval-before-p 0 5 10))
  (is (not (mcp-lisp:interval-before-p 0 10 5))))

(test temporal-helpers-in-invariant
  "temporal helpers work inside invariant :check forms"
  (with-fresh-specs
    (mcp-lisp:defentity task ()
      (id string :required t)
      (start number :required t :min 0 :max 100)
      (duration number :required t :min 1 :max 50)
      (deadline number :required t :min 10 :max 200))
    (mcp-lisp:definvariant task-before-deadline
      :on task
      :check (mcp-lisp:interval-before-p (task-start task) (task-duration task) (task-deadline task)))
    (mcp-lisp:ensure-entity-accessors "task")
    (is (equal '(:pass)
               (mcp-lisp:check-invariants "task" '(:id "t1" :start 0 :duration 5 :deadline 10))))
    (is (eq :fail
            (first (mcp-lisp:check-invariants "task" '(:id "t1" :start 0 :duration 15 :deadline 10)))))))

(test temporal-helpers-sql-translation
  "form-to-sql translates temporal helpers to SQL expressions"
  (with-fresh-specs
    (mcp-lisp:defentity slot ()
      (id string :required t)
      (start-time number :required t)
      (duration number :required t)
      (deadline number :required t))
    (mcp-lisp:definvariant slot-before-deadline
      :on slot
      :check (mcp-lisp:interval-before-p (slot-start-time slot) (slot-duration slot) (slot-deadline slot)))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "start_time + duration <= deadline" sql)))))

;;; ===========================================================================
;;; Feature 4: Scenario :refs
;;; ===========================================================================

(test defscenario-stores-refs
  "defscenario parses and stores :refs on entity bindings"
  (with-fresh-specs
    (mcp-lisp:defentity device ()
      (id string :required t))
    (mcp-lisp:defentity group ()
      (id string :required t))
    (mcp-lisp:defentity assignment ()
      (id string :required t)
      (device-id string :required t)
      (group-id string :required t))
    (mcp-lisp:defscenario group-membership
      :entities ((devices (1 3) device)
                 (groups (1 2) group)
                 (assignments (1 5) assignment
                   :refs ((device-id :from devices :field id)
                          (group-id :from groups :field id)))))
    (let* ((scenario (mcp-lisp:describe-scenario "group-membership"))
           (especs (getf scenario :entities))
           (assign-spec (third especs))
           (refs (getf assign-spec :refs)))
      (is (= 2 (length refs)))
      (is (eq :device-id (getf (first refs) :local-field)))
      (is (eq :devices (getf (first refs) :from)))
      (is (eq :id (getf (first refs) :field))))))

(test defscenario-refs-wires-fks
  "default-generate-scenario wires FK fields from :refs"
  (with-fresh-specs
    (mcp-lisp:defentity device ()
      (id string :required t))
    (mcp-lisp:defentity group ()
      (id string :required t))
    (mcp-lisp:defentity assignment ()
      (id string :required t)
      (device-id string :required t)
      (group-id string :required t))
    (mcp-lisp:defscenario group-membership
      :entities ((devices 2 device)
                 (groups 2 group)
                 (assignments 3 assignment
                   :refs ((device-id :from devices :field id)
                          (group-id :from groups :field id)))))
    (let* ((result (mcp-lisp:generate-scenario "group-membership"))
           (devices (getf result :devices))
           (groups (getf result :groups))
           (assignments (getf result :assignments))
           (device-ids (mapcar (lambda (d) (getf d :id)) devices))
           (group-ids (mapcar (lambda (g) (getf g :id)) groups)))
      (is (= 3 (length assignments)))
      (dolist (a assignments)
        (is (member (getf a :device-id) device-ids :test #'equal))
        (is (member (getf a :group-id) group-ids :test #'equal))))))

;;; ===========================================================================
;;; Feature 5: :cardinality on has-many
;;; ===========================================================================

(test has-many-cardinality-stored
  "has-many relation stores :cardinality"
  (with-fresh-specs
    (mcp-lisp:defentity device ()
      (id string :required t)
      (:has-many group-assignments :of assignment :cardinality (1 15)))
    (let* ((rels (mcp-lisp:entity-relations "device"))
           (rel (first rels))
           (card (getf (cddr rel) :cardinality)))
      (is (equal '(1 15) card)))))

(test has-many-cardinality-codegen-trigger
  "specs-to-sql emits cardinality trigger for has-many with :cardinality"
  (with-fresh-specs
    (mcp-lisp:defentity device ()
      (id string :required t)
      (:has-many group-assignments :of assignment :cardinality (1 15)))
    (mcp-lisp:defentity assignment ()
      (id string :required t)
      (device-id string :required t))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "check_device_group_assignments_cardinality" sql))
      (is (search "max 15" sql)))))

;;; ===========================================================================
;;; Feature 7: :reqs on invariants
;;; ===========================================================================

(test definvariant-stores-reqs
  "definvariant stores :reqs metadata"
  (with-fresh-specs
    (mcp-lisp:defentity widget ()
      (weight number :required t))
    (mcp-lisp:definvariant weight-positive
      :on widget
      :reqs ("REQ-WIDGET-1" "REQ-WIDGET-2")
      :check (> (widget-weight widget) 0))
    (let ((inv (mcp-lisp:describe-invariant "weight-positive")))
      (is (equal '("REQ-WIDGET-1" "REQ-WIDGET-2") (getf inv :reqs))))))

(test definvariant-no-reqs
  "definvariant without :reqs stores nil for :reqs"
  (with-fresh-specs
    (mcp-lisp:defentity widget ()
      (weight number :required t))
    (mcp-lisp:definvariant weight-positive
      :on widget
      :check (> (widget-weight widget) 0))
    (let ((inv (mcp-lisp:describe-invariant "weight-positive")))
      (is (null (getf inv :reqs))))))

(test compliance-matrix-groups-by-req
  "compliance-matrix returns requirement-to-invariant mapping"
  (with-fresh-specs
    (mcp-lisp:defentity widget ()
      (weight number :required t)
      (height number :required t))
    (mcp-lisp:definvariant weight-positive
      :on widget
      :reqs ("REQ-001")
      :check (> (widget-weight widget) 0))
    (mcp-lisp:definvariant height-positive
      :on widget
      :reqs ("REQ-001" "REQ-002")
      :check (> (widget-height widget) 0))
    (mcp-lisp:definvariant weight-bounded
      :on widget
      :check (<= (widget-weight widget) 1000))
    (let ((matrix (mcp-lisp:compliance-matrix)))
      (is (>= (length matrix) 2))
      (let ((req1 (find "REQ-001" matrix :key (lambda (e) (getf e :req)) :test #'equal))
            (req2 (find "REQ-002" matrix :key (lambda (e) (getf e :req)) :test #'equal))
            (uncat (find :uncategorized matrix :key (lambda (e) (getf e :req)))))
        (is (= 2 (length (getf req1 :invariants))))
        (is (= 1 (length (getf req2 :invariants))))
        (is (= 1 (length (getf uncat :invariants))))))))

(test reqs-survives-lisp-serialization
  "specs-to-lisp emits :reqs and the form round-trips"
  (with-fresh-specs
    (mcp-lisp:defentity widget ()
      (weight number :required t))
    (mcp-lisp:definvariant weight-positive
      :on widget
      :reqs ("REQ-001")
      :check (> (widget-weight widget) 0))
    (let ((lisp-src (mcp-lisp:specs-to-lisp)))
      (is (search ":reqs" lisp-src))
      (is (search "REQ-001" lisp-src)))))

;;; ===========================================================================
;;; Feature 8: spec-reference documentation completeness
;;; ===========================================================================

(test spec-reference-documents-aliased-belongs-to
  "spec-reference includes aliased belongs-to documentation"
  (let ((ref (mcp-lisp:spec-reference)))
    (is (search ":belongs-to sender :of" ref))))

(test spec-reference-documents-rule-templates
  "spec-reference includes rule template section"
  (let ((ref (mcp-lisp:spec-reference)))
    (is (search "Rule templates" ref))
    (is (search "defmacro" ref))))
