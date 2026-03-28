;;;; src/spec/dsl.lisp
;;;;
;;;; DSL macros for the behavioral specification system.

(defpackage #:mcp-lisp/src/spec/dsl
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/registry
                #:*entities*
                #:*rules*
                #:*invariants*
                #:*variants*
                #:*config*
                #:*scenarios*
                #:*helpers*
                #:*helper-sources*
                #:*valuesets*
                #:*requirements*
                #:*compiled-fn-cache*
                #:+known-field-keys+
                #:+relation-types+
                #:register-dsl-doc)
  (:export #:defentity
           #:defrule
           #:definvariant
           #:defvariant
           #:defconfig
           #:defscenario
           #:defhelper
           #:defvalueset
           #:defreq
           #:register-entity-accessors
           #:parse-entity-slots
           #:parse-scenario-cardinality
           #:in-set
           #:list-valuesets
           #:list-requirements))

(in-package #:mcp-lisp/src/spec/dsl)

;;; ---------------------------------------------------------------------------
;;; Entity accessor generation
;;; ---------------------------------------------------------------------------

(defun register-entity-accessors (name fields relations)
  "Define accessor functions for an entity's fields and relations.
Accessor names follow the pattern ENTITY-FIELD, e.g. ACCOUNT-BALANCE.
Called automatically by DEFENTITY so accessors exist immediately."
  (let ((entity-name (string name)))
    (dolist (field fields)
      (let* ((field-sym (first field))
             (accessor (intern (format nil "~A-~A" entity-name (symbol-name field-sym))))
             (key (intern (symbol-name field-sym) :keyword)))
        (setf (symbol-function accessor)
              (let ((k key)) (lambda (instance) (getf instance k))))))
    (dolist (rel relations)
      (let* ((rel-name (second rel))
             (accessor (intern (format nil "~A-~A" entity-name (symbol-name rel-name))))
             (key (intern (symbol-name rel-name) :keyword)))
        (unless (fboundp accessor)
          (setf (symbol-function accessor)
                (let ((k key)) (lambda (instance) (getf instance k)))))))))

;;; ---------------------------------------------------------------------------
;;; defentity
;;; ---------------------------------------------------------------------------

(defun parse-entity-slots (slots)
  "Classify SLOTS into fields, relations, derived entries, and constraints.
Returns (values fields relations derived constraints)."
  (let (fields relations derived constraints)
    (dolist (slot slots)
      (let ((head (car slot)))
        (cond
          ((member head +relation-types+)
           (push slot relations))
          ((eq head :derived)
           (push slot derived))
          ((eq head :unique-together)
           (push (cdr slot) constraints))
          (t
           (let ((kwargs (cddr slot)))
             (loop for (k) on kwargs by #'cddr
                   unless (member k +known-field-keys+)
                     do (error "defentity: unknown field keyword ~S in slot ~S" k slot)))
           (push slot fields)))))
    (values (nreverse fields) (nreverse relations) (nreverse derived) (nreverse constraints))))

(defmacro defentity (name (&rest supers) &body slots)
  "Define a specification entity. Stores metadata in *entities* — no class generation.

  (defentity user ()
    (id string :required t)
    (email string :required t)
    (role (member :admin :member :guest) :default :member)
    (:has-many orders :of order)
    (:unique-together email role)
    (:derived display-name (lambda (u) (or (name u) (email u)))))"
  (multiple-value-bind (fields relations derived constraints)
      (parse-entity-slots slots)
    (let ((key (string-downcase (string name))))
      `(progn
         (setf (gethash ,key *entities*)
               (list :name ',name
                     :supers ',supers
                     :fields ',fields
                     :relations ',relations
                     :derived ',derived
                     ,@(when constraints `(:constraints ',constraints))))
         (register-entity-accessors ',name ',fields ',relations)
         ',name))))

;;; ---------------------------------------------------------------------------
;;; defrule
;;; ---------------------------------------------------------------------------

(defmacro defrule (name &key when let requires sets ensures reqs)
  "Define a behavioral rule. Metadata-only — nothing is compiled or executed.

  (defrule place-order
    :when (order :state :draft)
    :let ((customer (order-customer order)))
    :requires ((active-account-p customer)
               (pos (account-balance customer)))
    :sets ((order-placed-at order) (get-universal-time))
    :ensures ((eq (order-state order) :placed))
    :reqs (\"REQ-ORD-001\"))"
  (let ((key (string-downcase (string name))))
    `(progn
       (setf (gethash ,key *rules*)
             (list :name ',name
                   :when ',when
                   :let ',let
                   :requires ',requires
                   :sets ',sets
                   :ensures ',ensures
                   ,@(when reqs `(:reqs ',reqs))))
       ',name)))

;;; ---------------------------------------------------------------------------
;;; definvariant
;;; ---------------------------------------------------------------------------

(defmacro definvariant (name &key on check reqs)
  "Define a spec invariant. Stored as quoted form, not compiled.
Optional :reqs maps to requirement IDs for compliance traceability.

  (definvariant positive-balance
    :on account
    :reqs (\"REQ-001\")
    :check (>= (account-balance account) 0))"
  (let ((key (string-downcase (string name))))
    `(progn
       (setf (gethash ,key *invariants*)
             (list :name ',name
                   :on ',on
                   :check ',check
                   ,@(when reqs `(:reqs ',reqs))))
       (clrhash *compiled-fn-cache*)
       ',name)))

;;; ---------------------------------------------------------------------------
;;; defvariant
;;; ---------------------------------------------------------------------------

(defmacro defvariant (name (parent discriminator value) &body fields)
  "Define a variant of an entity (sum type arm). Stores metadata in *variants*.

  (defvariant branch (node :kind :branch)
    (children list :required t))"
  (let ((key (string-downcase (string name)))
        (parent-key (string-downcase (string parent))))
    (dolist (field fields)
      (let ((kwargs (cddr field)))
        (loop for (k) on kwargs by #'cddr
              unless (member k +known-field-keys+)
                do (error "defvariant: unknown field keyword ~S in field ~S" k field))))
    `(progn
       (setf (gethash ,key *variants*)
             (list :name ',name
                   :parent ,parent-key
                   :discriminator ',discriminator
                   :value ',value
                   :fields ',fields))
       ',name)))

;;; ---------------------------------------------------------------------------
;;; defconfig
;;; ---------------------------------------------------------------------------

(defmacro defconfig (&body fields)
  "Define a global typed configuration. Single config per spec set.

  (defconfig
    (max-leverage number :default 10.0 :min 1.0 :max 100.0)
    (margin-call-threshold number :default 0.5 :min 0.0 :max 1.0)
    (allow-short-selling boolean :default t))"
  (dolist (field fields)
    (let ((kwargs (cddr field)))
      (loop for (k) on kwargs by #'cddr
            unless (member k +known-field-keys+)
              do (error "defconfig: unknown field keyword ~S in field ~S" k field))))
  `(progn
     (setf *config* ',fields)
     (values)))

;;; ---------------------------------------------------------------------------
;;; defscenario
;;; ---------------------------------------------------------------------------

(defun parse-scenario-cardinality (card)
  "Parse cardinality spec: N → (N N), (MIN MAX) → (MIN MAX).
Returns (values min max singular-p) where singular-p is T for bare N."
  (if (consp card)
      (values (first card) (second card) nil)
      (values card card t)))

(defmacro defscenario (name &key entities)
  "Define a multi-entity test scenario for cross-entity PBT.

  (defscenario grid-dispatch
    :entities ((zones   (1 3) grid-zone)
               (gens    (3 8) generator :per zones)
               (storage (0 2) storage-unit :per zones)
               (interval 1 dispatch-interval)))"
  (let ((key (string-downcase (string name)))
        (parsed-entities
          (mapcar (lambda (spec)
                    (destructuring-bind (binding card entity-name &key per refs) spec
                      (multiple-value-bind (cmin cmax singular-p)
                          (parse-scenario-cardinality card)
                        (let ((result (list :binding (intern (string binding) :keyword)
                                            :entity (string-downcase (string entity-name))
                                            :min cmin
                                            :max cmax
                                            :per (when per
                                                   (intern (string per) :keyword))
                                            :singular singular-p)))
                          (when refs
                            (setf (getf result :refs)
                                  (mapcar (lambda (ref)
                                            (destructuring-bind (local-field &key from field) ref
                                              (list :local-field (intern (string local-field) :keyword)
                                                    :from (intern (string from) :keyword)
                                                    :field (intern (string field) :keyword))))
                                          refs)))
                          result))))
                  entities)))
    `(progn
       (setf (gethash ,key *scenarios*)
             (list :name ',name
                   :entities ',parsed-entities))
       ',name)))

;;; ---------------------------------------------------------------------------
;;; defhelper
;;; ---------------------------------------------------------------------------

(defmacro defhelper (name lambda-list &body body)
  "Define a helper function that persists across JSON round-trips.
Use for utility functions referenced by invariant check forms.

  (defhelper haversine-distance-nm (lat1 lon1 lat2 lon2)
    ...)"
  (let ((key (string-downcase (string name))))
    `(progn
       (defun ,name ,lambda-list ,@body)
       (setf (gethash ,key *helpers*) #',name)
       (setf (gethash ,key *helper-sources*)
             '(defhelper ,name ,lambda-list ,@body))
       ',name)))

;;; ---------------------------------------------------------------------------
;;; defvalueset
;;; ---------------------------------------------------------------------------

(defmacro defvalueset (name values)
  "Define a named set of values for use in invariant checks via IN-SET.

  (defvalueset valid-response-codes (1 2 3 4 5 6 7 8 9 10 11 13 14 252 253 254))"
  (let ((key (string-downcase (string name))))
    `(progn
       (setf (gethash ,key *valuesets*) ',values)
       ',name)))

(defun in-set (set-name value)
  "Check if VALUE is a member of the named value set SET-NAME.
SET-NAME is a symbol or string naming a set defined by DEFVALUESET."
  (let ((values (gethash (string-downcase (string set-name)) *valuesets*)))
    (and values (member value values :test #'equal) t)))

(defun list-valuesets ()
  "Return a list of registered valueset name strings."
  (loop for k being the hash-keys of *valuesets* collect k))

;;; ---------------------------------------------------------------------------
;;; defreq
;;; ---------------------------------------------------------------------------

(defmacro defreq (id description &key category status notes)
  "Register a requirement that cannot be expressed as a definvariant.
Used for API-level, authorization, operational, or performance requirements.

  (defreq \"REQ-API-001\" \"Return 404 for unauthorized access\"
    :category :api
    :status :not-expressible
    :notes \"HTTP-level behavior, not data property\")"
  (let ((key (string-downcase (string id))))
    `(progn
       (setf (gethash ,key *requirements*)
             (list :id ',id
                   :description ,description
                   :category ,(or category :uncategorized)
                   :status ,(or status :not-expressible)
                   :notes ,notes))
       ',id)))

(defun list-requirements ()
  "Return a list of registered requirement ID strings."
  (loop for k being the hash-keys of *requirements* collect k))

;;; ---------------------------------------------------------------------------
;;; DSL documentation registration
;;; ---------------------------------------------------------------------------

(register-dsl-doc 'defentity
  :type :macro :section "Defining specs" :order 1
  :synopsis "Define a specification entity with typed fields, relations, and constraints."
  :example "(defentity user ()
  (id string :required t :unique t)
  (name string)
  (email string :required t)
  (role (member :admin :member :guest) :default :member)
  (:has-many orders :of order)
  (:unique-together email role)
  (:derived display-name (lambda (u) (or (name u) (email u)))))"
  :options '(("Field types" "string, number, integer, boolean, (member :a :b ...), (list-of type)")
             (":required" "Field must be non-nil")
             (":unique" "Field value must be unique across instances")
             (":default" "Default value for generation")
             (":min / :max" "Numeric bounds for generation and SQL CHECK")
             (":immutable" "Field cannot be changed after initial set")
             (":nullable" "Generator produces nil ~30% of the time")
             (":derived-from" "Field computed from other fields")
             (":has-many" "One-to-many relation; :of names target entity; :cardinality (min max) bounds count")
             (":has-one" "One-to-one relation")
             (":belongs-to" "Many-to-one relation; auto-generates FK field. Aliased: (:belongs-to sender :of user) creates :sender-id FK, allowing multiple FKs to same entity")
             (":unique-together" "Composite uniqueness constraint across fields")))

(register-dsl-doc 'defrule
  :type :macro :section "Defining specs" :order 2
  :synopsis "Define a state transition rule with guards and side effects."
  :example "(defrule place-order
  :when (order :state :draft)
  :let ((customer (order-customer order)))
  :requires ((active-account-p customer))
  :sets ((order-placed-at order) (get-universal-time))
  :ensures ((eq (order-state order) :placed))
  :reqs (\"REQ-ORD-001\"))"
  :options '((":when" "(entity :field :value) — required source state; accepts (member ...) for multiple")
             (":let" "Bind local variables for use in :requires/:sets")
             (":requires" "Guard predicates — all must be true")
             (":sets" "Alternating (accessor value) pairs for field updates")
             (":ensures" "Target state assertions after transition")
             (":reqs" "Requirement IDs for compliance traceability")))

(register-dsl-doc 'definvariant
  :type :macro :section "Defining specs" :order 3
  :synopsis "Define a property that must always hold on an entity, variant, scenario, or config."
  :example "(definvariant positive-balance
  :on account
  :check (>= (account-balance account) 0))"
  :options '((":on" "Entity, variant, scenario name, or :config")
             (":check" "Lisp form evaluated against instances; must return non-nil")
             (":reqs" "Requirement IDs for compliance traceability")))

(register-dsl-doc 'defvariant
  :type :macro :section "Defining specs" :order 4
  :synopsis "Define a variant (discriminated union arm) of an entity."
  :example "(defvariant branch (node :kind :branch)
  (children list :required t))"
  :options '(("parent" "Base entity name")
             ("discriminator" "Keyword field used for dispatch")
             ("value" "Discriminator value identifying this variant")
             ("fields" "Additional fields specific to this variant")))

(register-dsl-doc 'defconfig
  :type :macro :section "Defining specs" :order 5
  :synopsis "Define typed configuration parameters with defaults and bounds."
  :example "(defconfig
  (max-leverage number :default 10.0 :min 1.0 :max 100.0)
  (allow-short-selling boolean :default t))"
  :options '(("Field modifiers" "Same as defentity: :default, :min, :max")
             ("PBT" ":config-trials generates random configs within declared bounds")
             ("Invariants" "Reference config values with (config :key)")))

(register-dsl-doc 'defscenario
  :type :macro :section "Defining specs" :order 6
  :synopsis "Define a multi-entity test scenario for cross-entity PBT."
  :example "(defscenario order-fulfillment
  :entities ((warehouses (1 3) warehouse)
             (orders     (5 20) order)
             (items      (1 5) line-item :per orders)))"
  :options '(("Cardinality" "(min max) produces a list; bare N produces a single plist")
             (":per" "Generate instances per parent binding")
             (":refs" "Auto-wire FK fields: ((local-field :from binding :field field) ...)")))

(register-dsl-doc 'defhelper
  :type :macro :section "Defining specs" :order 7
  :synopsis "Define a persistent utility function for use in invariant :check forms."
  :example "(defhelper haversine-distance-nm (lat1 lon1 lat2 lon2)
  (let* ((to-rad (/ pi 180.0d0)) ...) ...))"
  :options '(("Persistence" "Source stored in registry; survives JSON round-trips")
             ("clear-specs" "Also clears registered helpers")))

(register-dsl-doc 'defvalueset
  :type :macro :section "Defining specs" :order 8
  :synopsis "Define a named set of values for use in invariant checks via in-set."
  :example "(defvalueset valid-codes (1 2 3 4 5 6 7 8 9 10 11 13 14 252 253 254))"
  :options '(("in-set" "(in-set 'valid-codes value) — membership check; translates to SQL IN (...)")))

(register-dsl-doc 'defreq
  :type :macro :section "Defining specs" :order 9
  :synopsis "Register a non-invariant requirement for compliance tracking."
  :example "(defreq \"REQ-API-001\" \"Return 404 for unauthorized access\"
  :category :api
  :status :not-expressible
  :notes \"HTTP-level behavior, not a data property\")"
  :options '((":category" ":api, :authorization, :operational, :performance, or custom")
             (":status" ":not-expressible or :partial")
             (":notes" "Free-text explanation")
             ("compliance-matrix" "Appears alongside invariant-backed requirements")))
