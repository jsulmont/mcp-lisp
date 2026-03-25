;;;; tests/issues-tests.lisp
;;;;
;;;; Tests for DSL issues found during compliance spec work

(in-package #:mcp-lisp/tests)

(def-suite issues-tests
  :description "Tests for DSL issues found during CSIP-AUS compliance spec"
  :in mcp-lisp-tests)

(in-suite issues-tests)

(defmacro with-fresh-specs (&body body)
  `(let ((mcp-lisp/src/spec/spec::*entities* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*rules* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*invariants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*generator-sources* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*variants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenarios* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenario-generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenario-negative-generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenario-negative-generator-sources* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*compiled-fn-cache* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*valuesets* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*requirements* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*config* nil)
         (mcp-lisp/src/spec/spec::*current-config* nil))
     ,@body))

;;; ---------------------------------------------------------------------------
;;; Issue 1: belongs-to FK fields in generate-instance
;;; ---------------------------------------------------------------------------

(test issue-1-belongs-to-fk-in-generate-instance
  "generate-instance creates FK fields for belongs-to relations"
  (with-fresh-specs
    (mcp-lisp:defentity parent-entity ()
      (id string :required t)
      (name string))
    (mcp-lisp:defentity child-entity ()
      (id string :required t)
      (value number)
      (:belongs-to parent-entity :of parent-entity))
    (let ((inst (mcp-lisp:generate-instance "child-entity")))
      (is (not (null (getf inst :parent-entity-id)))
          "FK field :parent-entity-id should be present")
      (is (stringp (getf inst :parent-entity-id))
          "FK field should be a string"))))

(test issue-1-fk-override-respected
  "generate-instance respects overrides for FK fields"
  (with-fresh-specs
    (mcp-lisp:defentity team ()
      (id string :required t))
    (mcp-lisp:defentity player ()
      (id string :required t)
      (name string)
      (:belongs-to team :of team))
    (let ((inst (mcp-lisp:generate-instance "player" '(:team-id "team-42"))))
      (is (equal "team-42" (getf inst :team-id))))))

(test issue-1-fk-in-raw-instance
  "generate-raw-instance also creates FK fields for belongs-to"
  (with-fresh-specs
    (mcp-lisp:defentity org ()
      (id string :required t))
    (mcp-lisp:defentity member ()
      (id string :required t)
      (:belongs-to org :of org))
    (let ((inst (mcp-lisp/src/spec/pbt::generate-raw-instance "member")))
      (is (not (null (getf inst :org-id)))))))

;;; ---------------------------------------------------------------------------
;;; Issue 2: detect-state-fields for non-"state" field names
;;; ---------------------------------------------------------------------------

(test issue-2-detect-state-fields-non-state-name
  "detect-state-fields works with field names other than 'state'"
  (with-fresh-specs
    (mcp-lisp:defentity control ()
      (id string :required t)
      (current-status (member :scheduled :active :cancelled :completed) :default :scheduled))
    (mcp-lisp:defrule activate-control
      :when (control :current-status :scheduled)
      :ensures ((eq (control-current-status control) :active)))
    (mcp-lisp:defrule cancel-control
      :when (control :current-status (member :scheduled :active))
      :ensures ((eq (control-current-status control) :cancelled)))
    (mcp-lisp:defrule complete-control
      :when (control :current-status :active)
      :ensures ((eq (control-current-status control) :completed)))
    (let ((fields (mcp-lisp:detect-state-fields "control")))
      (is (= 1 (length fields)))
      (is (eq :current-status (first fields))))))

(test issue-2-analyze-state-machine-non-state-name
  "analyze-state-machine works with non-'state' field names"
  (with-fresh-specs
    (mcp-lisp:defentity workflow ()
      (id string :required t)
      (lifecycle-phase (member :draft :review :approved :rejected) :default :draft))
    (mcp-lisp:defrule submit-for-review
      :when (workflow :lifecycle-phase :draft)
      :ensures ((eq (workflow-lifecycle-phase workflow) :review)))
    (mcp-lisp:defrule approve
      :when (workflow :lifecycle-phase :review)
      :ensures ((eq (workflow-lifecycle-phase workflow) :approved)))
    (mcp-lisp:defrule reject
      :when (workflow :lifecycle-phase :review)
      :ensures ((eq (workflow-lifecycle-phase workflow) :rejected)))
    (let ((analysis (mcp-lisp:analyze-state-machine "workflow")))
      (is (not (null analysis)))
      (is (eq :lifecycle-phase (getf analysis :field)))
      (is (eq :draft (getf analysis :initial)))
      (is (= 4 (length (getf analysis :states))))
      (is (member :approved (getf analysis :terminal)))
      (is (member :rejected (getf analysis :terminal))))))

;;; ---------------------------------------------------------------------------
;;; Issue 3: generate-instance respects :default for state fields
;;; ---------------------------------------------------------------------------

(test issue-3-state-field-uses-default
  "generate-instance uses :default for state fields"
  (with-fresh-specs
    (mcp-lisp:defentity ticket ()
      (id string :required t)
      (state (member :open :in-progress :resolved :closed) :default :open))
    (mcp-lisp:defrule start-ticket
      :when (ticket :state :open)
      :ensures ((eq (ticket-state ticket) :in-progress)))
    (mcp-lisp:defrule resolve-ticket
      :when (ticket :state :in-progress)
      :ensures ((eq (ticket-state ticket) :resolved)))
    (mcp-lisp:defrule close-ticket
      :when (ticket :state :resolved)
      :ensures ((eq (ticket-state ticket) :closed)))
    (let ((results (loop repeat 20
                         collect (getf (mcp-lisp:generate-instance "ticket") :state))))
      (is (every (lambda (s) (eq s :open)) results)
          "All generated instances should have :state :open (the default)"))))

(test issue-3-non-state-member-still-random
  "Non-state member fields still get random values"
  (with-fresh-specs
    (mcp-lisp:defentity item ()
      (id string :required t)
      (color (member :red :green :blue) :default :red))
    (let ((results (loop repeat 30
                         collect (getf (mcp-lisp:generate-instance "item") :color))))
      (is (> (length (remove-duplicates results)) 1)
          "Non-state member field should produce varied values"))))

;;; ---------------------------------------------------------------------------
;;; Issue 4: defreq for non-invariant requirements
;;; ---------------------------------------------------------------------------

(test issue-4-defreq-basic
  "defreq registers a requirement"
  (with-fresh-specs
    (mcp-lisp:defreq "REQ-API-001" "Return 404 for unauthorized"
      :category :api
      :status :not-expressible
      :notes "HTTP-level behavior")
    (is (member "req-api-001" (mcp-lisp:list-requirements) :test #'string=))))

(test issue-4-compliance-matrix-includes-reqs
  "compliance-matrix includes defreq entries"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant non-negative
      :on account
      :reqs ("REQ-DATA-001")
      :check (>= (account-balance account) 0))
    (mcp-lisp:defreq "REQ-API-001" "Return 404 for unauthorized"
      :category :api
      :status :not-expressible)
    (let ((matrix (mcp-lisp:compliance-matrix)))
      (is (find "REQ-DATA-001" matrix
                :key (lambda (e) (getf e :req)) :test #'string=))
      (is (find "REQ-API-001" matrix
                :key (lambda (e) (getf e :req)) :test #'string=)))))

;;; ---------------------------------------------------------------------------
;;; Issue 5: eval_lisp returns last form's result
;;; ---------------------------------------------------------------------------

(defun call-agent-tool (name args)
  "Call tool NAME with ARGS hash-table, return text result."
  (let* ((tool (mcp-lisp/src/primitives/tools/registry:get-tool name))
         (handler (mcp-lisp/src/primitives/tools/registry:tool-entry-handler tool))
         (result (funcall handler nil nil args))
         (first-content (aref result 0)))
    (gethash "text" first-content)))

(test issue-5-eval-lisp-last-form
  "eval_lisp returns the last form's result, not the first"
  (let* ((result (call-agent-tool "eval_lisp"
                   (mcp-lisp:make-ht "code" "(+ 1 2) (+ 3 4)"))))
    (is (search "7" result)
        "Should contain 7 (result of last form), not 3 (result of first form)")))

;;; ---------------------------------------------------------------------------
;;; Issue 6: validate-specs FK detection only flags known entities
;;; ---------------------------------------------------------------------------

(test issue-6-fk-detection-no-false-positives
  "validate-specs does not flag domain identifiers like log-event-id"
  (with-fresh-specs
    (mcp-lisp:defentity device ()
      (id string :required t)
      (log-event-id string :required t)
      (profile-id string)
      (connection-point-id string))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (notany (lambda (w) (search "log-event-id" w)) warnings)
          "log-event-id should not be flagged (no 'log-event' entity exists)")
      (is (notany (lambda (w) (search "profile-id" w)) warnings)
          "profile-id should not be flagged (no 'profile' entity exists)")
      (is (notany (lambda (w) (search "connection-point-id" w)) warnings)
          "connection-point-id should not be flagged"))))

(test issue-6-fk-detection-flags-real-fks
  "validate-specs still flags FK fields that match known entities"
  (with-fresh-specs
    (mcp-lisp:defentity team ()
      (id string :required t))
    (mcp-lisp:defentity player ()
      (id string :required t)
      (team-id string :required t))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (some (lambda (w) (search "team-id" w)) warnings)
          "team-id should be flagged ('team' entity exists)"))))

;;; ---------------------------------------------------------------------------
;;; Issue 7: Negative testing field-bound classification
;;; ---------------------------------------------------------------------------

(test issue-7-field-bound-classification
  "classify-zero-rejection detects field-bound invariants even when not all fields are bounded"
  (with-fresh-specs
    (mcp-lisp:defentity sensor ()
      (id string :required t)
      (name string)
      (priority integer :required t :min 0 :max 255))
    (mcp-lisp:definvariant priority-valid
      :on sensor
      :check (and (>= (sensor-priority sensor) 0)
                  (<= (sensor-priority sensor) 255)))
    (mcp-lisp:ensure-entity-accessors "sensor")
    (let ((check (getf (mcp-lisp:describe-invariant "priority-valid") :check)))
      (let ((classification (mcp-lisp/src/spec/pbt::classify-zero-rejection check "sensor")))
        (is (and classification (search "field bounds" classification))
            "Should be classified as enforced by field bounds")))))

;;; ---------------------------------------------------------------------------
;;; Issue 8: list-of field type
;;; ---------------------------------------------------------------------------

(test issue-8-generate-value-list-of
  "generate-value handles (list-of type)"
  (let ((v (mcp-lisp:generate-value '(list-of number) :min 3 :max 5)))
    (is (listp v))
    (is (>= (length v) 3))
    (is (<= (length v) 5))
    (is (every #'numberp v))))

(test issue-8-generate-instance-list-of-field
  "generate-instance handles entities with list-of fields"
  (with-fresh-specs
    (mcp-lisp:defentity curve ()
      (id string :required t)
      (data-points (list-of number) :min 2 :max 10))
    (let ((inst (mcp-lisp:generate-instance "curve")))
      (is (listp (getf inst :data-points)))
      (is (>= (length (getf inst :data-points)) 2)))))

;;; ---------------------------------------------------------------------------
;;; Issue 9: defvalueset and in-set
;;; ---------------------------------------------------------------------------

(test issue-9-defvalueset-basic
  "defvalueset registers a value set"
  (with-fresh-specs
    (mcp-lisp:defvalueset valid-codes (1 2 3 10 20))
    (is (member "valid-codes" (mcp-lisp:list-valuesets) :test #'string=))))

(test issue-9-in-set-checks-membership
  "in-set checks value membership in named set"
  (with-fresh-specs
    (mcp-lisp:defvalueset valid-codes (1 2 3 10 20))
    (is (mcp-lisp:in-set 'valid-codes 1))
    (is (mcp-lisp:in-set 'valid-codes 10))
    (is (not (mcp-lisp:in-set 'valid-codes 5)))
    (is (not (mcp-lisp:in-set 'valid-codes 99)))))

(test issue-9-in-set-in-invariant
  "in-set works in invariant check forms"
  (with-fresh-specs
    (mcp-lisp:defvalueset valid-statuses (1 2 3 4 5))
    (mcp-lisp:defentity response ()
      (id string :required t)
      (status integer :required t :min 1 :max 5))
    (mcp-lisp:definvariant valid-status
      :on response
      :check (mcp-lisp:in-set 'valid-statuses (response-status response)))
    (mcp-lisp:ensure-entity-accessors "response")
    (let ((result (mcp-lisp:check-invariants "response"
                    '(:id "r1" :status 3))))
      (is (eq :pass (car result))))
    (let ((result (mcp-lisp:check-invariants "response"
                    '(:id "r1" :status 99))))
      (is (eq :fail (car result))))))

;;; ---------------------------------------------------------------------------
;;; Issue 10: Temporal duration helpers
;;; ---------------------------------------------------------------------------

(test issue-10-elapsed-since
  "elapsed-since computes time difference"
  (is (= 100 (mcp-lisp:elapsed-since 900 1000)))
  (is (= 0 (mcp-lisp:elapsed-since 500 500))))

(test issue-10-duration-at-least-p
  "duration-at-least-p checks minimum duration"
  (is (mcp-lisp:duration-at-least-p 100 200 50))
  (is (mcp-lisp:duration-at-least-p 100 200 100))
  (is (not (mcp-lisp:duration-at-least-p 100 200 200))))

(test issue-10-within-retention-period-p
  "within-retention-period-p checks retention window"
  (is (mcp-lisp:within-retention-period-p 100 200 250))
  (is (not (mcp-lisp:within-retention-period-p 100 200 350))))

(test issue-10-temporal-in-invariant
  "Temporal helpers work in invariant check forms"
  (with-fresh-specs
    (mcp-lisp:defentity event ()
      (id string :required t)
      (created-at number :required t :min 0 :max 1000)
      (checked-at number :required t :min 0 :max 2000)
      (retention number :required t :min 100 :max 500))
    (mcp-lisp:definvariant event-retained
      :on event
      :check (mcp-lisp:within-retention-period-p
               (event-created-at event)
               (event-retention event)
               (event-checked-at event)))
    (mcp-lisp:ensure-entity-accessors "event")
    (let ((result (mcp-lisp:check-invariants "event"
                    '(:id "e1" :created-at 100 :checked-at 150 :retention 200))))
      (is (eq :pass (car result))))
    (let ((result (mcp-lisp:check-invariants "event"
                    '(:id "e1" :created-at 100 :checked-at 500 :retention 200))))
      (is (eq :fail (car result))))))

;;; ---------------------------------------------------------------------------
;;; Issue 11: Boolean fields with :default should respect default in generator
;;; ---------------------------------------------------------------------------

(test issue-11-boolean-default-respected
  "Boolean fields with :default should generate at their default value"
  (with-fresh-specs
    (mcp-lisp:defentity device ()
      (id string :required t)
      (enabled boolean :default t)
      (active boolean :default nil))
    (let ((all-enabled t)
          (all-inactive t))
      (dotimes (_ 50)
        (let ((inst (mcp-lisp:generate-instance "device")))
          (unless (getf inst :enabled) (setf all-enabled nil))
          (when (getf inst :active) (setf all-inactive nil))))
      (is (eq t all-enabled))
      (is (eq t all-inactive)))))

;;; ---------------------------------------------------------------------------
;;; Issue 12: Compliance matrix merges defreq + invariant :reqs
;;; ---------------------------------------------------------------------------

(test issue-12-compliance-matrix-merges-defreq
  "When a req has both invariants and defreq, metadata is merged into one row"
  (with-fresh-specs
    (mcp-lisp:defentity curve ()
      (id string :required t)
      (num-points integer :required t :min 2))
    (mcp-lisp:definvariant min-points
      :on curve
      :reqs ("REQ-CONTROL-13")
      :check (>= (curve-num-points curve) 2))
    (mcp-lisp:defreq "REQ-CONTROL-13" "Curve data validation"
      :category :control
      :status :partial)
    (let* ((matrix (mcp-lisp:compliance-matrix))
           (entries (remove-if-not
                      (lambda (e) (string= (getf e :req) "REQ-CONTROL-13"))
                      matrix)))
      (is (= 1 (length entries)))
      (let ((entry (first entries)))
        (is (equal '("min-points") (getf entry :invariants)))
        (is (eq :partial (getf entry :status)))
        (is (string= "Curve data validation" (getf entry :description)))
        (is (eq :control (getf entry :category)))))))

;;; ---------------------------------------------------------------------------
;;; Issue 13: Nullable field generation
;;; ---------------------------------------------------------------------------

(test issue-13-nullable-field-generates-nil
  ":nullable t fields produce nil some of the time"
  (with-fresh-specs
    (mcp-lisp:defentity device ()
      (id string :required t)
      (soft-deletion-time number :nullable t))
    (let ((nil-count 0)
          (total 200))
      (dotimes (_ total)
        (let ((inst (mcp-lisp:generate-instance "device")))
          (when (null (getf inst :soft-deletion-time))
            (incf nil-count))))
      (is (> nil-count 0))
      (is (< nil-count total)))))

;;; ---------------------------------------------------------------------------
;;; Issue 14: Composite unique constraints
;;; ---------------------------------------------------------------------------

(test issue-14-unique-together-stored
  ":unique-together constraints are stored on entity"
  (with-fresh-specs
    (mcp-lisp:defentity assignment ()
      (id string :required t)
      (device-id string :required t)
      (group-id string :required t)
      (:unique-together device-id group-id))
    (let ((entity (mcp-lisp:describe-entity "assignment")))
      (is (equal '((device-id group-id)) (getf entity :constraints))))))

(test issue-14-unique-together-validate-warns-unknown-field
  ":unique-together referencing unknown field produces validation warning"
  (with-fresh-specs
    (mcp-lisp:defentity assignment ()
      (id string :required t)
      (device-id string :required t)
      (:unique-together device-id nonexistent-field))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (some (lambda (w) (search "unique-together" w)) warnings)))))

(test issue-14-unique-together-codegen
  ":unique-together emits UNIQUE constraint in SQL"
  (with-fresh-specs
    (mcp-lisp:defentity assignment ()
      (id string :required t)
      (device-id string :required t)
      (group-id string :required t)
      (:unique-together device-id group-id))
    (let ((sql (mcp-lisp:specs-to-sql)))
      (is (search "UNIQUE (device_id, group_id)" sql)))))

(test issue-14-unique-together-lisp-roundtrip
  ":unique-together survives specs-to-lisp serialization"
  (with-fresh-specs
    (mcp-lisp:defentity assignment ()
      (id string :required t)
      (device-id string :required t)
      (group-id string :required t)
      (:unique-together device-id group-id))
    (let ((lisp-src (mcp-lisp:specs-to-lisp)))
      (is (search "unique-together" lisp-src)))))
