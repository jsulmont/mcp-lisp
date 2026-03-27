(defpackage #:mcp-lisp/src/spec/generation
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/registry
                #:register-dsl-doc
                #:*entities*
                #:*generators*
                #:*generator-sources*
                #:*variants*
                #:*config*
                #:*current-config*
                #:*scenarios*
                #:*scenario-generators*
                #:*scenario-generator-sources*
                #:*scenario-negative-generators*
                #:*scenario-negative-generator-sources*
                #:*compiled-fn-cache*)
  (:import-from #:mcp-lisp/src/spec/introspection
                #:describe-entity
                #:list-entities
                #:entity-fields
                #:entity-relations
                #:entity-variants
                #:describe-variant
                #:describe-scenario
                #:config)
  (:import-from #:mcp-lisp/src/spec/transitions
                #:detect-state-fields
                #:field-default)
  (:import-from #:mcp-lisp/src/spec/pbt-util
                #:generate-value
                #:field-keyword
                #:*override-sentinel*
                #:override-val
                #:override-present-p
                #:field-constraints
                #:member-type-p
                #:find-symbol-named
                #:getf-field-p
                #:get-compiled-fn)
  (:import-from #:mcp-lisp/src/spec/checking
                #:check-invariants
                #:config-invariants
                #:check-config-invariants)
  (:import-from #:mcp-lisp/src/spec/constraints
                #:extract-generation-constraints
                #:resolve-field-bounds
                #:toposort-fields
                #:condition-satisfied-p)
  (:export #:*generation-depth*
           #:*max-generation-depth*
           #:find-child-fk-key
           #:populate-has-many
           #:default-generate-instance
           #:generate-config-once
           #:generate-config
           #:generate-variant-fields
           #:generate-instance
           #:body-references-p
           #:body-declares-ignore-p
           #:defgenerator
           #:ensure-entity-accessors
           #:ensure-variant-accessors
           #:ensure-config-accessor
           #:scenario-fk-overrides
           #:refs-overrides
           #:default-generate-scenario
           #:generate-scenario
           #:current-config
           #:defscenario-generator
           #:defscenario-negative-generator))

(in-package #:mcp-lisp/src/spec/generation)

;;; ---------------------------------------------------------------------------
;;; Instance generation
;;; ---------------------------------------------------------------------------

(defvar *generation-depth* 0
  "Current nesting depth during recursive instance generation.
Used to prevent infinite recursion when has-many relations form cycles.")

(defparameter *max-generation-depth* 3
  "Maximum depth for recursive has-many population in generate-instance.")

(defun find-child-fk-key (child-entity-name parent-entity-name)
  "Find the FK keyword on CHILD-ENTITY-NAME that points to PARENT-ENTITY-NAME.
Returns a keyword like :TEAM-ID, or NIL if no belongs-to relation found."
  (let ((child-rels (entity-relations child-entity-name)))
    (dolist (cr child-rels)
      (when (eq (first cr) :belongs-to)
        (let ((target (string-downcase (string (second cr)))))
          (when (string= target (string-downcase (string parent-entity-name)))
            (return (intern (format nil "~A-ID"
                                    (string-upcase (string (second cr))))
                            :keyword))))))))

(defun populate-has-many (entity-name instance)
  "Populate has-many relations on INSTANCE that have :cardinality specs.
Generates child instances and wires FK fields back to the parent.
Skips when *generation-depth* exceeds *max-generation-depth*."
  (when (>= *generation-depth* *max-generation-depth*)
    (return-from populate-has-many instance))
  (let* ((entity (describe-entity entity-name))
         (relations (getf entity :relations))
         (parent-id (getf instance :id)))
    (dolist (rel relations)
      (when (eq (first rel) :has-many)
        (let* ((rel-name (second rel))
               (rel-key (field-keyword rel-name))
               (child-entity (getf (cddr rel) :of))
               (cardinality (getf (cddr rel) :cardinality)))
          (when (and child-entity cardinality)
            (let* ((cmin (first cardinality))
                   (cmax (second cardinality))
                   (n (if (= cmin cmax) cmin
                          (+ cmin (random (1+ (- cmax cmin))))))
                   (child-name (string-downcase (string child-entity)))
                   (fk-kw (when parent-id
                            (find-child-fk-key child-name entity-name))))
              (let ((*generation-depth* (1+ *generation-depth*)))
                (setf (getf instance rel-key)
                      (loop repeat n
                            collect (let ((child (generate-instance child-name)))
                                      (when (and fk-kw parent-id)
                                        (setf (getf child fk-kw) parent-id))
                                      child)))))))))
    instance))

(defun default-generate-instance (entity-name &optional overrides)
  "Generate a random instance of ENTITY-NAME as a plist.
OVERRIDES is a plist (:key1 val1 :key2 val2 ...) of pre-set field values.
Uses invariant-extracted constraints for smarter generation:
member/enum fields first, then numeric fields in dependency order
with bounds derived from invariant check forms."
  (let* ((entity (describe-entity entity-name))
         (fields (getf entity :fields))
         (inv-constraints (extract-generation-constraints entity-name))
         ;; Separate member fields from non-member fields
         (member-fields (remove-if-not (lambda (f) (member-type-p (second f))) fields))
         (other-fields (remove-if (lambda (f) (member-type-p (second f))) fields))
         ;; Sort non-member fields by dependency order
         (sorted-others (toposort-fields other-fields inv-constraints))
         ;; Detect state fields so we can use :default for them
         (state-fields (detect-state-fields entity-name))
         (instance nil)
         (deferred nil))
    ;; Phase 1: generate member/enum fields
    ;; State fields (used in :when/:ensures of rules) use :default if available
    (dolist (field member-fields)
      (let* ((fname (first field))
             (ftype (second field))
             (key (field-keyword fname))
             (kwargs (cddr field))
             (default (getf kwargs :default))
             (is-state (member key state-fields)))
        (cond
          ((override-present-p overrides key)
           (push (override-val overrides key) instance) (push key instance))
          ((and (getf kwargs :nullable) (< (random 10) 3))
           (push nil instance) (push key instance))
          ((and is-state default)
           (push default instance) (push key instance))
          (t
           (push (generate-value ftype) instance) (push key instance)))))
    ;; Phase 2: generate non-member fields in dependency order
    (dolist (field sorted-others)
      (let* ((fname (first field))
             (ftype (second field))
             (key (field-keyword fname))
             (kwargs (cddr field))
             (fc (field-constraints field))
             (ic (gethash key inv-constraints)))
        (cond
          ((override-present-p overrides key)
           (push (override-val overrides key) instance) (push key instance))
          ((getf fc :derived-from)
           (push nil instance) (push key instance)
           (push (list key (getf fc :derived-from)) deferred))
          ((and (getf kwargs :nullable) (< (random 10) 3))
           (push nil instance) (push key instance))
          ;; Boolean fields with :default use the default value (like member state fields)
          ((and (eq ftype 'boolean) (member :default kwargs))
           (push (getf kwargs :default) instance) (push key instance))
          (t
           (let* ((bounds (resolve-field-bounds key ic fc instance
                                                          (getf entity :name)))
                  (eq-val (getf bounds :eq))
                  (eff-min (getf bounds :min))
                  (eff-max (getf bounds :max)))
             ;; Sanity: if min > max, drop the tighter one
             (when (and eff-min eff-max (> eff-min eff-max))
               (setf eff-min nil eff-max nil))
             (push (if eq-val eq-val
                       (generate-value ftype :min eff-min :max eff-max))
                   instance)
             (push key instance))))))
    ;; Phase 2.5: generate FK fields from belongs-to relations
    (let ((relations (getf entity :relations)))
      (dolist (rel relations)
        (when (eq (first rel) :belongs-to)
          (let* ((rel-name (second rel))
                 (fk-kw (intern (format nil "~A-ID"
                                        (string-upcase (symbol-name rel-name)))
                                :keyword)))
            (cond
              ((override-present-p overrides fk-kw)
               (unless (getf instance fk-kw)
                 (push (override-val overrides fk-kw) instance)
                 (push fk-kw instance)))
              ((not (getf instance fk-kw))
               (push (generate-value 'string) instance)
               (push fk-kw instance)))))))
    ;; Phase 3: compute derived fields
    (when deferred
      (ensure-entity-accessors entity-name)
      (dolist (entry deferred)
        (destructuring-bind (key form) entry
          (let* ((inst-sym (find-symbol-named "INSTANCE" form))
                 (fn (get-compiled-fn (cons entity-name key)
                                      (list inst-sym) form)))
            (setf (getf instance key) (funcall fn instance))))))
    ;; Phase 4: populate has-many relations with cardinality
    (populate-has-many entity-name instance)))

(defun generate-config-once ()
  "Generate a single random config plist from *CONFIG* field specs (no invariant checking)."
  (let ((result nil))
    (dolist (field *config*)
      (let* ((fname (first field))
             (ftype (second field))
             (key (field-keyword fname))
             (fc (field-constraints field)))
        (push (generate-value ftype :min (getf fc :min) :max (getf fc :max))
              result)
        (push key result)))
    result))

(defun generate-config ()
  "Generate a random config plist from *CONFIG* field specs.
Retries up to 100 times to satisfy config-level invariants."
  (let ((invs (config-invariants)))
    (if (null invs)
        (generate-config-once)
        (dotimes (attempt 100 (generate-config-once))
          (let* ((cfg (generate-config-once))
                 (result (check-config-invariants cfg)))
            (when (eq (first result) :pass)
              (return cfg)))))))

(defun generate-variant-fields (variant instance)
  "Generate variant-specific fields and merge into INSTANCE plist."
  (dolist (field (getf variant :fields))
    (let* ((fname (first field))
           (ftype (second field))
           (key (field-keyword fname))
           (fc (field-constraints field)))
      (setf (getf instance key)
            (generate-value ftype :min (getf fc :min) :max (getf fc :max)))))
  instance)

(defun generate-instance (entity-name &optional overrides)
  "Generate a random instance of ENTITY-NAME as a plist.
If a custom generator is registered via DEFGENERATOR, uses that.
Otherwise uses constraint-aware default generation with a retry loop.
For entities with variants, picks a random variant and generates
variant-specific fields."
  (let ((custom (gethash (string-downcase (string entity-name)) *generators*)))
    (if custom
        (funcall custom overrides)
        (let* ((variants (entity-variants entity-name))
               (best nil)
               (best-n most-positive-fixnum))
          (dotimes (attempt 10)
            (let* ((variant (when variants
                              (describe-variant
                               (nth (random (length variants)) variants))))
                   (eff-overrides
                     (if variant
                         (list* (getf variant :discriminator)
                                (getf variant :value)
                                (or overrides nil))
                         overrides))
                   (inst (default-generate-instance entity-name eff-overrides))
                   (full-inst (if variant
                                  (generate-variant-fields variant inst)
                                  inst))
                   (result (check-invariants entity-name full-inst))
                   (n (if (eq (car result) :pass) 0 (length (cdr result)))))
              (when (< n best-n)
                (setf best full-inst best-n n))
              (when (zerop n)
                (return-from generate-instance full-inst))))
          best))))

(defun body-references-p (sym body)
  "Check if BODY (a list of forms) references symbol SYM anywhere."
  (labels ((walk (form)
             (cond
               ((eq form sym) t)
               ((and (consp form) (eq (first form) 'quote)) nil)
               ((consp form) (or (walk (car form)) (walk (cdr form))))
               (t nil))))
    (some #'walk body)))

(defun body-declares-ignore-p (sym body)
  "Check if BODY contains (declare (ignore SYM)) or (declare (ignorable SYM))."
  (dolist (form body)
    (when (and (consp form) (eq (first form) 'declare))
      (dolist (decl (cdr form))
        (when (and (consp decl)
                   (member (first decl) '(ignore ignorable))
                   (member sym (cdr decl)))
          (return-from body-declares-ignore-p t)))))
  nil)

(defmacro defgenerator (entity-name (overrides-var) &body body)
  "Register a custom instance generator for ENTITY-NAME.
The generator receives OVERRIDES (a plist of :key value pairs, or NIL)
and must return a plist. Use OVERRIDE-VAL to look up override values
(handles NIL/0/\"\" correctly). GENERATE-VALUE and DEFAULT-GENERATE-INSTANCE
are available within the body for building instances.

  (defgenerator trader (overrides)
    (let ((inst (default-generate-instance \"trader\" overrides)))
      (when (getf inst :suspended)
        (setf (getf inst :margin-ratio) (random 0.5)))
      inst))"
  (when (and (not (body-references-p overrides-var body))
             (not (body-declares-ignore-p overrides-var body)))
    (warn "defgenerator ~A: overrides parameter ~A is never used. ~
           Scenario-generated overrides will be silently ignored. ~
           Add (declare (ignore ~A)) if intentional."
          entity-name overrides-var overrides-var))
  (let ((key (string-downcase (string entity-name))))
    `(progn
       (setf (gethash ,key *generators*)
             (lambda (,overrides-var)
               ,@body))
       (setf (gethash ,key *generator-sources*)
             '(defgenerator ,entity-name (,overrides-var) ,@body))
       ',entity-name)))

;;; ---------------------------------------------------------------------------
;;; Accessor generation
;;; ---------------------------------------------------------------------------

(defun ensure-entity-accessors (entity-name)
  "Define accessor functions for ENTITY-NAME's fields and relations.
Accessor names follow the pattern ENTITY-FIELD, e.g. ACCOUNT-BALANCE.
Symbols are interned in *PACKAGE* (the caller's dynamic package)."
  (let* ((entity (describe-entity entity-name))
         (entity-sym (getf entity :name))
         (fields (getf entity :fields))
         (relations (getf entity :relations)))
    ;; Field accessors
    (dolist (field fields)
      (let* ((field-sym (first field))
             (accessor (intern (format nil "~A-~A"
                                       (symbol-name entity-sym)
                                       (symbol-name field-sym))))
             (key (field-keyword field-sym)))
        (setf (symbol-function accessor)
              (let ((k key)) (lambda (instance) (getf instance k))))))
    ;; Relation accessors
    (dolist (rel relations)
      (let* ((rel-name (second rel))
             (accessor (intern (format nil "~A-~A"
                                       (symbol-name entity-sym)
                                       (symbol-name rel-name))))
             (key (field-keyword rel-name)))
        (unless (fboundp accessor)
          (setf (symbol-function accessor)
                (let ((k key)) (lambda (instance) (getf instance k)))))))
    entity-name))

(defun ensure-variant-accessors (variant-name)
  "Define accessor functions for a variant's fields.
Accessor names follow the pattern VARIANT-FIELD, e.g. BRANCH-CHILDREN."
  (let* ((variant (describe-variant variant-name))
         (variant-sym (getf variant :name))
         (fields (getf variant :fields)))
    (dolist (field fields)
      (let* ((field-sym (first field))
             (accessor (intern (format nil "~A-~A"
                                       (symbol-name variant-sym)
                                       (symbol-name field-sym))))
             (key (field-keyword field-sym)))
        (setf (symbol-function accessor)
              (let ((k key)) (lambda (instance) (getf instance k))))))
    variant-name))

(defun ensure-config-accessor ()
  "Ensure CONFIG function is available in the caller's package."
  (let ((sym (intern "CONFIG")))
    (unless (fboundp sym)
      (setf (symbol-function sym)
            (lambda (key) (getf *current-config* key))))))

;;; ---------------------------------------------------------------------------
;;; Scenario generation
;;; ---------------------------------------------------------------------------

(defun scenario-fk-overrides (entity-name result scenario-entities)
  "Compute FK override plist for ENTITY-NAME from already-generated RESULT.
Looks up :belongs-to relations and finds matching parent entities in the scenario.
SCENARIO-ENTITIES is the list of entity specs (to map entity names to bindings)."
  (let ((rels (entity-relations entity-name))
        (fk-overrides nil))
    (dolist (rel rels)
      (when (eq (first rel) :belongs-to)
        (let* ((target-name (string-downcase (string (second rel))))
               (fk-kw (intern (format nil "~A-ID"
                                       (string-upcase (string (second rel))))
                               :keyword))
               (target-binding
                 (loop for es in scenario-entities
                       when (string= (getf es :entity) target-name)
                         return (getf es :binding)))
               (parent-val (when target-binding (getf result target-binding))))
          (when parent-val
            (let* ((parents (if (and (listp parent-val) (not (keywordp (car parent-val))))
                                parent-val
                                (list parent-val)))
                   (parent (nth (random (length parents)) parents))
                   (parent-id (getf parent :id)))
              (when parent-id
                (setf fk-overrides (list* fk-kw parent-id fk-overrides))))))))
    fk-overrides))

(defun refs-overrides (refs result)
  "Compute FK override plist from :refs declarations and already-generated RESULT."
  (let ((overrides nil))
    (dolist (ref refs)
      (let* ((local-field (getf ref :local-field))
             (from-binding (getf ref :from))
             (remote-field (getf ref :field))
             (source-val (getf result from-binding)))
        (when source-val
          (let* ((sources (if (and (listp source-val) (not (keywordp (car source-val))))
                              source-val (list source-val)))
                 (picked (nth (random (length sources)) sources))
                 (val (getf picked remote-field)))
            (when val
              (setf overrides (list* local-field val overrides)))))))
    overrides))

(defun default-generate-scenario (scenario-name &optional overrides)
  "Generate a scenario instance: a plist mapping binding keywords to entity instances.
Iterates entity specs in declaration order, respecting cardinality and :per relations.
Auto-wires FK fields from :belongs-to relations to parent entities in the scenario.
:refs declarations explicitly wire FK fields from referenced bindings.
OVERRIDES is a plist mapping binding keywords to pre-built instances."
  (let* ((scenario (describe-scenario scenario-name))
         (entity-specs (getf scenario :entities))
         (result nil))
    (dolist (espec entity-specs)
      (let* ((binding (getf espec :binding))
             (entity-name (getf espec :entity))
             (emin (getf espec :min))
             (emax (getf espec :max))
             (per (getf espec :per))
             (refs (getf espec :refs))
             (override (getf overrides binding)))
        (if override
            (setf (getf result binding) override)
            (let ((ref-ov (when refs (refs-overrides refs result))))
              (if per
                  ;; Generate N instances per parent
                  (let ((parents (let ((p (getf result per)))
                                   (if (and (listp p) (not (keywordp (car p))))
                                       p (list p))))
                        (all-instances nil))
                    (dolist (parent parents)
                      (let* ((fk-ov (scenario-fk-overrides entity-name result entity-specs))
                             (parent-id (getf parent :id))
                             (per-entity (loop for es in entity-specs
                                               when (eq (getf es :binding) per)
                                                 return (getf es :entity)))
                             (per-fk-kw (when per-entity
                                          (intern (format nil "~A-ID"
                                                           (string-upcase per-entity))
                                                  :keyword)))
                             (full-ov (append ref-ov
                                              (if (and per-fk-kw parent-id)
                                                  (list* per-fk-kw parent-id fk-ov)
                                                  fk-ov)))
                             (n (if (= emin emax) emin
                                    (+ emin (random (1+ (- emax emin)))))))
                        (dotimes (_i n)
                          (push (generate-instance entity-name full-ov) all-instances))))
                    (setf (getf result binding) (nreverse all-instances)))
                  ;; Generate N instances (no parent)
                  (let* ((fk-ov (append ref-ov
                                        (scenario-fk-overrides entity-name result entity-specs)))
                         (singular (getf espec :singular))
                         (n (if (= emin emax) emin
                                (+ emin (random (1+ (- emax emin)))))))
                    (let ((instances nil))
                      (dotimes (_i n)
                        (push (generate-instance entity-name fk-ov) instances))
                      (setf (getf result binding)
                            (if (and singular (= n 1))
                                (first instances)
                                (nreverse instances))))))))))
    result))

(defun generate-scenario (scenario-name &optional overrides)
  "Generate a scenario instance, using custom generator if registered."
  (let ((custom (gethash (string-downcase (string scenario-name))
                         *scenario-generators*)))
    (if custom
        (funcall custom overrides)
        (default-generate-scenario scenario-name overrides))))

(defun current-config ()
  "Return the active config plist during PBT. Outside PBT, returns NIL.
Use (CONFIG :key) to read individual config values (returns defaults outside PBT)."
  *current-config*)

(defmacro defscenario-generator (scenario-name (overrides-var) &body body)
  "Register a custom scenario generator for SCENARIO-NAME.
The generator receives OVERRIDES (a plist or NIL) and must return a plist
mapping binding keywords to instances (or lists of instances).
During PBT config trials, (CONFIG :key) and (CURRENT-CONFIG) are available
to access the active config."
  (let ((key (string-downcase (string scenario-name))))
    `(progn
       (setf (gethash ,key *scenario-generators*)
             (lambda (,overrides-var)
               ,@body))
       (setf (gethash ,key *scenario-generator-sources*)
             '(defscenario-generator ,scenario-name (,overrides-var) ,@body))
       ',scenario-name)))

(defmacro defscenario-negative-generator (scenario-name (overrides-var) &body body)
  "Register a negative scenario generator for SCENARIO-NAME.
The generator must return instances that SHOULD violate at least one scenario
invariant. During negative PBT, every generated instance is checked — if none
of the scenario invariants reject it, the negative generator is flagged as broken."
  (let ((key (string-downcase (string scenario-name))))
    `(progn
       (setf (gethash ,key *scenario-negative-generators*)
             (lambda (,overrides-var)
               ,@body))
       (setf (gethash ,key *scenario-negative-generator-sources*)
             '(defscenario-negative-generator ,scenario-name (,overrides-var) ,@body))
       ',scenario-name)))

;;; ---------------------------------------------------------------------------
;;; DSL documentation registration
;;; ---------------------------------------------------------------------------

(register-dsl-doc 'defgenerator
  :type :macro :section "Defining specs" :order 10
  :synopsis "Register a custom instance generator for an entity."
  :example "(defgenerator triple (overrides)
  (let* ((inst (default-generate-instance \"triple\" overrides))
         (a (getf inst :a))
         (b (getf inst :b)))
    (setf (getf inst :result) (- (* b b) a))
    inst))"
  :options '(("overrides" "Plist of :keyword value or NIL; use override-val / override-present-p to read")
             ("default-generate-instance" "Constraint-aware base generator — use as starting point")
             ("generate-value" "Generate individual typed values: (generate-value 'number :min 0 :max 10)")))

(register-dsl-doc 'defscenario-generator
  :type :macro :section "Defining specs" :order 11
  :synopsis "Register a custom scenario generator. Required when scenario invariants use aggregates."
  :example "(defscenario-generator order-fulfillment (overrides)
  (declare (ignore overrides))
  (let* ((warehouses (list (generate-instance \"warehouse\")))
         (orders (loop repeat 5 collect (generate-instance \"order\"))))
    (list :warehouses warehouses :orders orders)))"
  :options '(("Return format" "Plist mapping binding keywords to instances (lists or single plists)")
             ("config" "Use (config :key) — returns :default outside PBT, live value during PBT")))

(register-dsl-doc 'defscenario-negative-generator
  :type :macro :section "Defining specs" :order 12
  :synopsis "Register a targeted negative generator for scenario invariant testing."
  :example "(defscenario-negative-generator raft-cluster (overrides)
  (declare (ignore overrides))
  (let ((term (+ 1 (random 10))))
    (list :servers
          (list (generate-instance \"server\" (list :state :leader :current-term term))
                (generate-instance \"server\" (list :state :leader :current-term term))))))"
  :options '(("Purpose" "Produce instances that SHOULD violate at least one scenario invariant")
             ("Validation" "During negative PBT, instances passing all invariants are flagged as broken")))
