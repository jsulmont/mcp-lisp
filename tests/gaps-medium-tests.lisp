;;;; tests/gaps-medium-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite gaps-medium-tests
  :description "Tests for medium-tier DSL gap fixes: mixins, M:N, compounds, present-when, conditional gen"
  :in mcp-lisp-tests)

(in-suite gaps-medium-tests)

(defmacro with-clean-specs (&body body)
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
;;; Feature 1: Entity mixins via supers
;;; ===========================================================================

(test mixin-fields-merged-into-entity
  "defmixin fields are merged into entity via supers"
  (with-clean-specs
    (mcp-lisp:defmixin timestamped
      (created-at number :required t :immutable t)
      (updated-at number))
    (mcp-lisp:defentity record (timestamped)
      (id string :required t)
      (name string))
    (let ((fields (mcp-lisp:entity-fields "record")))
      (is (= 4 (length fields)))
      (is (find 'id fields :key #'first :test #'string-equal))
      (is (find 'name fields :key #'first :test #'string-equal))
      (is (find 'created-at fields :key #'first :test #'string-equal))
      (is (find 'updated-at fields :key #'first :test #'string-equal)))))

(test mixin-entity-field-overrides-mixin
  "entity's own field wins on collision with mixin field"
  (with-clean-specs
    (mcp-lisp:defmixin base-fields
      (status (member :draft :active) :default :draft)
      (name string))
    (mcp-lisp:defentity doc (base-fields)
      (id string :required t)
      (status (member :draft :review :published) :default :draft))
    (let* ((fields (mcp-lisp:entity-fields "doc"))
           (status-field (find 'status fields :key #'first :test #'string-equal))
           (members (second status-field)))
      (is (= 3 (length fields)))
      (is (member :published (cdr members))))))

(test mixin-generation-produces-all-fields
  "generate-instance produces values for mixin-inherited fields"
  (with-clean-specs
    (mcp-lisp:defmixin auditable
      (created-by string :required t))
    (mcp-lisp:defentity item (auditable)
      (id string :required t)
      (price number :required t :min 0.0 :max 100.0))
    (let ((inst (mcp-lisp:generate-instance "item")))
      (is (stringp (getf inst :id)))
      (is (numberp (getf inst :price)))
      (is (stringp (getf inst :created-by))))))

(test list-mixins-returns-names
  "list-mixins returns registered mixin names"
  (with-clean-specs
    (mcp-lisp:defmixin foo (x number))
    (mcp-lisp:defmixin bar (y string))
    (let ((names (mcp-lisp:list-mixins)))
      (is (= 2 (length names)))
      (is (member "foo" names :test #'string=))
      (is (member "bar" names :test #'string=)))))

;;; ===========================================================================
;;; Feature 2: Many-to-many relation sugar
;;; ===========================================================================

(test many-to-many-creates-join-entity
  "defentity with :many-to-many auto-generates a join entity"
  (with-clean-specs
    (mcp-lisp:defentity user ()
      (id string :required t)
      (:many-to-many roles :of role))
    (mcp-lisp:defentity role ()
      (id string :required t)
      (name string :required t))
    (let ((join (mcp-lisp:describe-entity "user-roles")))
      (is (not (null join)))
      (is (eq t (getf join :auto-generated)))
      (let ((fields (getf join :fields)))
        (is (find 'user-id fields :key #'first :test #'string-equal))
        (is (find 'role-id fields :key #'first :test #'string-equal)))
      (let ((constraints (getf join :constraints)))
        (is (= 1 (length constraints)))))))

(test many-to-many-join-entity-generates
  "join entity from :many-to-many can be generated"
  (with-clean-specs
    (mcp-lisp:defentity user ()
      (id string :required t)
      (:many-to-many roles :of role))
    (mcp-lisp:defentity role ()
      (id string :required t))
    (let ((inst (mcp-lisp:generate-instance "user-roles")))
      (is (stringp (getf inst :id)))
      (is (stringp (getf inst :user-id)))
      (is (stringp (getf inst :role-id))))))

;;; ===========================================================================
;;; Feature 3: Composite types (defcompound)
;;; ===========================================================================

(test compound-expands-to-prefixed-fields
  "defcompound type expands to prefixed sub-fields in defentity"
  (with-clean-specs
    (mcp-lisp:defcompound active-power
      (multiplier integer :required t)
      (value number :required t))
    (mcp-lisp:defentity inverter ()
      (id string :required t)
      (max-power active-power))
    (let ((fields (mcp-lisp:entity-fields "inverter")))
      (is (= 3 (length fields)))
      (is (find 'max-power-multiplier fields :key #'first :test #'string-equal))
      (is (find 'max-power-value fields :key #'first :test #'string-equal)))))

(test compound-kwargs-propagate
  "field-level kwargs propagate to expanded sub-fields"
  (with-clean-specs
    (mcp-lisp:defcompound power
      (multiplier integer)
      (value number))
    (mcp-lisp:defentity device ()
      (id string :required t)
      (rating power :required t))
    (let* ((fields (mcp-lisp:entity-fields "device"))
           (mult-field (find 'rating-multiplier fields :key #'first :test #'string-equal))
           (val-field (find 'rating-value fields :key #'first :test #'string-equal)))
      (is (getf (cddr mult-field) :required))
      (is (getf (cddr val-field) :required)))))

(test compound-generation-produces-values
  "generate-instance produces values for compound-expanded fields"
  (with-clean-specs
    (mcp-lisp:defcompound coord
      (lat number :min -90.0 :max 90.0)
      (lon number :min -180.0 :max 180.0))
    (mcp-lisp:defentity waypoint ()
      (id string :required t)
      (position coord))
    (let ((inst (mcp-lisp:generate-instance "waypoint")))
      (is (numberp (getf inst :position-lat)))
      (is (numberp (getf inst :position-lon))))))

(test list-compounds-returns-names
  "list-compounds returns registered compound names"
  (with-clean-specs
    (mcp-lisp:defcompound foo (x number))
    (is (member "foo" (mcp-lisp:list-compounds) :test #'string=))))

;;; ===========================================================================
;;; Feature 4: Conditional field presence (:present-when)
;;; ===========================================================================

(test present-when-generation-sets-nil
  "generate-instance sets field to nil when :present-when condition is not met"
  (with-clean-specs
    (mcp-lisp:defentity msg ()
      (id string :required t)
      (msg-type (member :request :response) :default :request)
      (response-body string :present-when (:msg-type :response)))
    (dotimes (i 50)
      (let ((inst (mcp-lisp:generate-instance "msg")))
        (if (eq (getf inst :msg-type) :request)
            (is (null (getf inst :response-body)))
            (is (not (null (getf inst :response-body)))))))))

(test present-when-checking-rejects-violation
  "check-invariants rejects instance violating :present-when"
  (with-clean-specs
    (mcp-lisp:defentity msg ()
      (id string :required t)
      (msg-type (member :request :response))
      (response-body string :present-when (:msg-type :response)))
    (mcp-lisp:ensure-entity-accessors "msg")
    (let ((result (mcp-lisp:check-invariants "msg"
                    '(:id "m1" :msg-type :response :response-body nil))))
      (is (eq :fail (first result))))
    (let ((result (mcp-lisp:check-invariants "msg"
                    '(:id "m1" :msg-type :request :response-body "oops"))))
      (is (eq :fail (first result))))
    (let ((result (mcp-lisp:check-invariants "msg"
                    '(:id "m1" :msg-type :response :response-body "ok"))))
      (is (equal '(:pass) result)))
    (let ((result (mcp-lisp:check-invariants "msg"
                    '(:id "m1" :msg-type :request :response-body nil))))
      (is (equal '(:pass) result)))))

;;; ===========================================================================
;;; Feature 6: Generator conditional field deps
;;; ===========================================================================

(test conditional-nil-from-invariant
  "Generator nils out field when invariant implies conditional nil"
  (with-clean-specs
    (mcp-lisp:defentity message ()
      (id string :required t)
      (kind (member :request :response) :default :request)
      (result string))
    (mcp-lisp:definvariant request-has-no-result
      :on message
      :check (if (eq (message-kind message) :request)
                 (null (message-result message))
                 t))
    (mcp-lisp:ensure-entity-accessors "message")
    (let ((request-results nil))
      (dotimes (i 100)
        (let ((inst (mcp-lisp:generate-instance "message")))
          (when (eq (getf inst :kind) :request)
            (push (getf inst :result) request-results))))
      (is (every #'null request-results)))))
