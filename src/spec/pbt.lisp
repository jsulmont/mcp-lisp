;;;; src/spec/pbt.lisp
;;;;
;;;; Property-based testing for behavioral specs. Generates random entity
;;;; instances from field type specs and checks invariants against them.

(defpackage #:mcp-lisp/src/spec/pbt
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/spec
                #:*entities*
                #:*invariants*
                #:*generators*
                #:*variants*
                #:*config*
                #:*current-config*
                #:config
                #:describe-entity
                #:list-entities
                #:describe-invariant
                #:list-invariants
                #:describe-variant
                #:entity-variants
                #:list-variants
                #:entity-fields
                #:entity-relations)
  (:export #:generate-value
           #:generate-instance
           #:default-generate-instance
           #:defgenerator
           #:ensure-entity-accessors
           #:ensure-variant-accessors
           #:generate-config
           #:check-invariants
           #:run-pbt
           #:extract-generation-constraints))

(in-package #:mcp-lisp/src/spec/pbt)

;;; ---------------------------------------------------------------------------
;;; Value generators
;;; ---------------------------------------------------------------------------

(defparameter +alphanumeric+ "abcdefghijklmnopqrstuvwxyz0123456789")

(defun generate-value (type-spec &key min max)
  "Generate a random value conforming to TYPE-SPEC.
Optional MIN and MAX constrain numeric types."
  (cond
    ((eq type-spec 'string)
     (let ((len (random 20)))
       (map 'string
            (lambda (x)
              (declare (ignore x))
              (char +alphanumeric+ (random (length +alphanumeric+))))
            (make-string len))))
    ((eq type-spec 'number)
     (let ((lo (or min -1000.0))
           (hi (or max 1000.0)))
       (+ lo (random (- hi lo)))))
    ((eq type-spec 'integer)
     (let ((lo (or (and min (ceiling min)) -100))
           (hi (or (and max (floor max)) 100)))
       (+ lo (random (1+ (- hi lo))))))
    ((and (consp type-spec) (eq (car type-spec) 'member))
     (let ((choices (cdr type-spec)))
       (nth (random (length choices)) choices)))
    ((eq type-spec 'boolean)
     (zerop (random 2)))
    (t nil)))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun find-symbol-named (name form)
  "Find the first symbol whose symbol-name is NAME (case-insensitive) in FORM."
  (cond
    ((and (symbolp form) (string-equal (symbol-name form) name)) form)
    ((consp form) (or (find-symbol-named name (car form))
                      (find-symbol-named name (cdr form))))
    (t nil)))

(defun field-keyword (field-name-sym)
  "Convert a field name symbol to a keyword for plist access."
  (intern (symbol-name field-name-sym) :keyword))

(defun field-constraints (field)
  "Extract plist of generator constraints (:min :max :derived-from) from a field spec."
  (let ((kwargs (cddr field))
        (constraints nil))
    (loop for (k v) on kwargs by #'cddr
          do (case k
               (:min          (setf (getf constraints :min) v))
               (:max          (setf (getf constraints :max) v))
               (:derived-from (setf (getf constraints :derived-from) v))))
    constraints))

(defun member-type-p (type-spec)
  "Return T if TYPE-SPEC is a member/enum type like (MEMBER :A :B :C)."
  (and (consp type-spec) (eq (car type-spec) 'member)))

;;; ---------------------------------------------------------------------------
;;; Invariant constraint extraction
;;; ---------------------------------------------------------------------------

(defun getf-field-p (form entity-var)
  "If FORM accesses a field of ENTITY-VAR, return the field keyword.
Recognizes both (GETF ENTITY-VAR :FIELD) and (ENTITY-FIELD ENTITY-VAR) patterns."
  (cond
    ;; (getf entity-var :keyword)
    ((and (consp form) (= (length form) 3)
          (eq (first form) 'getf)
          (eq (second form) entity-var)
          (keywordp (third form)))
     (third form))
    ;; (entity-field entity-var) — accessor pattern
    ((and (consp form) (= (length form) 2)
          (symbolp (first form))
          (eq (second form) entity-var))
     (let* ((accessor-name (string-downcase (symbol-name (first form))))
            (entity-name (string-downcase (symbol-name entity-var)))
            (prefix (concatenate 'string entity-name "-")))
       (when (and (> (length accessor-name) (length prefix))
                  (string= prefix accessor-name :end2 (length prefix)))
         (intern (string-upcase (subseq accessor-name (length prefix)))
                 :keyword))))))

(defun extract-scaled-ref (form entity-var)
  "Recognize (* FACTOR (GETF E :F)) or (* (GETF E :F) FACTOR).
Returns (:field KEYWORD :factor NUMBER) or NIL."
  (when (and (consp form) (eq (car form) '*) (= (length form) 3))
    (let ((a (second form))
          (b (third form)))
      (cond
        ((and (numberp a) (getf-field-p b entity-var))
         (list :field (getf-field-p b entity-var) :factor a))
        ((and (numberp b) (getf-field-p a entity-var))
         (list :field (getf-field-p a entity-var) :factor b))))))

(defun config-ref-p (form)
  "If FORM is (CONFIG :KEY), return the config key. Otherwise NIL."
  (when (and (consp form) (= (length form) 2)
             (symbolp (first form))
             (string-equal (symbol-name (first form)) "CONFIG")
             (keywordp (second form)))
    (second form)))

(defun extract-comparison (form entity-var)
  "Extract constraint(s) from a comparison form (OP LHS RHS).
Returns a list of constraint plists or NIL."
  (when (and (consp form) (= (length form) 3)
             (member (first form) '(> >= < <= =)))
    (let* ((op (first form))
           (lhs (second form))
           (rhs (third form))
           (lf (getf-field-p lhs entity-var))
           (rf (getf-field-p rhs entity-var))
           (epsilon 0.001))
      (cond
        ;; (op (getf e :field) number)
        ((and lf (numberp rhs))
         (list (case op
                 (>  (list :field lf :min (+ rhs epsilon)))
                 (>= (list :field lf :min rhs))
                 (<  (list :field lf :max (- rhs epsilon)))
                 (<= (list :field lf :max rhs))
                 (=  (list :field lf :eq rhs)))))
        ;; (op number (getf e :field))
        ((and rf (numberp lhs))
         (list (case op
                 (>  (list :field rf :max (- lhs epsilon)))
                 (>= (list :field rf :max lhs))
                 (<  (list :field rf :min (+ lhs epsilon)))
                 (<= (list :field rf :min lhs))
                 (=  (list :field rf :eq lhs)))))
        ;; (op (getf e :f1) (getf e :f2))
        ((and lf rf)
         (list (case op
                 (>  (list :field lf :min-field rf :exclusive t))
                 (>= (list :field lf :min-field rf))
                 (<  (list :field lf :max-field rf :exclusive t))
                 (<= (list :field lf :max-field rf))
                 (=  (list :field lf :eq-field rf)))))
        ;; (op (getf e :f) (config :key))
        ((and lf (config-ref-p rhs))
         (let ((ck (config-ref-p rhs)))
           (list (case op
                   (>  (list :field lf :min-config ck :exclusive t))
                   (>= (list :field lf :min-config ck))
                   (<  (list :field lf :max-config ck :exclusive t))
                   (<= (list :field lf :max-config ck))
                   (=  (list :field lf :eq-config ck))))))
        ;; (op (config :key) (getf e :f))
        ((and rf (config-ref-p lhs))
         (let ((ck (config-ref-p lhs)))
           (list (case op
                   (>  (list :field rf :max-config ck :exclusive t))
                   (>= (list :field rf :max-config ck))
                   (<  (list :field rf :min-config ck :exclusive t))
                   (<= (list :field rf :min-config ck))
                   (=  (list :field rf :eq-config ck))))))
        ;; (op (getf e :f) (* factor (getf e :other)))
        ((and lf (extract-scaled-ref rhs entity-var))
         (let* ((scaled (extract-scaled-ref rhs entity-var))
                (ref (getf scaled :field))
                (factor (getf scaled :factor)))
           (list (case op
                   ((>= >) (list :field lf :min-field ref :factor factor))
                   ((<= <) (list :field lf :max-field ref :factor factor))
                   (=      (list :field lf :eq-field ref :factor factor))))))))))

(defun extract-condition (form entity-var)
  "Extract a condition from (EQ (GETF E :F) :V), (NOT ...), or (MEMBER ...).
Returns (:field KW :value V :negated BOOL) or (:field KW :values LIST :negated BOOL) or NIL."
  (cond
    ;; (eq (getf e :field) value)
    ((and (consp form) (eq (first form) 'eq) (= (length form) 3))
     (let ((field (getf-field-p (second form) entity-var)))
       (when field
         (list :field field :value (third form) :negated nil))))
    ;; (not expr) — negate
    ((and (consp form) (eq (first form) 'not) (= (length form) 2))
     (let ((inner (extract-condition (second form) entity-var)))
       (when inner
         (setf (getf inner :negated) (not (getf inner :negated)))
         inner)))
    ;; (member (getf e :field) '(values...))
    ((and (consp form) (eq (first form) 'member))
     (let ((field (getf-field-p (second form) entity-var)))
       (when field
         (let ((values (third form)))
           ;; Unquote if needed
           (when (and (consp values) (eq (car values) 'quote))
             (setf values (second values)))
           (when (listp values)
             (list :field field :values values :negated nil))))))))

(defun negate-condition (condition)
  "Return a copy of CONDITION with :negated flipped."
  (when condition
    (let ((copy (copy-list condition)))
      (setf (getf copy :negated) (not (getf copy :negated)))
      copy)))

(defun extract-constraints-from-form (form entity-var &optional condition)
  "Recursively extract generation constraints from an invariant check form.
CONDITION, if present, gates when extracted constraints apply.
Returns a list of constraint plists."
  (when (consp form)
    (case (first form)
      ;; (and c1 c2 ...) — extract from each conjunct
      ((and)
       (loop for sub in (cdr form)
             nconc (extract-constraints-from-form sub entity-var condition)))

      ;; (or branch1 branch2 ...) — extract if branches are conditional
      ((or)
       (let ((branches (cdr form)))
         ;; Check if each branch is either (and (condition) ...) or a bare condition
         (let ((extracted nil)
               (all-ok t))
           (dolist (branch branches)
             (cond
               ;; (and (eq/member ...) constraints...)
               ((and (consp branch) (eq (car branch) 'and) (cddr branch)
                     (extract-condition (second branch) entity-var))
                (let ((branch-cond (extract-condition (second branch) entity-var)))
                  (dolist (sub (cddr branch))
                    (setf extracted
                          (nconc extracted
                                 (extract-constraints-from-form
                                  sub entity-var
                                  (or condition branch-cond)))))))
               ;; Bare condition like (eq (getf e :state) :idle) — no constraints, just satisfied
               ((extract-condition branch entity-var)
                nil) ;; nothing to extract, branch is just "pass"
               ;; Unrecognized branch — bail on the whole or
               (t (setf all-ok nil)
                  (return))))
           (when all-ok extracted))))

      ;; (if condition then else)
      ((if)
       (when (= (length form) 4)
         (let ((cond-form (second form))
               (then-form (third form))
               (else-form (fourth form)))
           (let ((cond-info (extract-condition cond-form entity-var)))
             (when cond-info
               (let ((neg-cond (negate-condition cond-info)))
                 (cond
                   ;; (if condition constraints t) — most common
                   ((eq else-form t)
                    (extract-constraints-from-form then-form entity-var
                                                   (or condition cond-info)))
                   ;; (if condition t constraints)
                   ((eq then-form t)
                    (extract-constraints-from-form else-form entity-var
                                                   (or condition neg-cond)))
                   ;; Both branches have constraints
                   (t
                    (append
                     (extract-constraints-from-form then-form entity-var
                                                    (or condition cond-info))
                     (extract-constraints-from-form else-form entity-var
                                                    (or condition neg-cond)))))))))))

      ;; Comparison operators
      ((> >= < <= =)
       (let ((constraints (extract-comparison form entity-var)))
         (when constraints
           (if condition
               (mapcar (lambda (c) (append c (list :when condition))) constraints)
               constraints))))

      ;; Default — unrecognized, skip
      (otherwise nil))))

(defun extract-generation-constraints (entity-name)
  "Extract per-field generation constraints from all invariants for ENTITY-NAME.
Returns a hash table mapping field keywords to lists of constraint plists."
  (let ((result (make-hash-table :test #'eq))
        (entity (describe-entity entity-name))
        (invs (invariants-for entity-name)))
    (let ((entity-var (getf entity :name)))
      (dolist (entry invs)
        (destructuring-bind (inv-name inv) entry
          (declare (ignore inv-name))
          (let ((check (getf inv :check)))
            (dolist (constraint (extract-constraints-from-form check entity-var))
              (let ((field (getf constraint :field)))
                (when field
                  (push constraint (gethash field result)))))))))
    result))

;;; ---------------------------------------------------------------------------
;;; Constraint resolution
;;; ---------------------------------------------------------------------------

(defun condition-satisfied-p (condition instance)
  "Check if CONDITION is satisfied by the current INSTANCE state."
  (when condition
    (let* ((field (getf condition :field))
           (actual (getf instance field))
           (negated (getf condition :negated))
           (match (cond
                    ((getf condition :values)
                     (member actual (getf condition :values)))
                    (t (equal actual (getf condition :value))))))
      (if negated (not match) match))))

(defun resolve-field-bounds (field-keyword inv-constraints field-constraints instance)
  "Given a field's invariant constraints, field-level :min/:max, and current instance,
compute effective generation bounds. Returns (:min N :max N :eq N)."
  (let ((lo (getf field-constraints :min))
        (hi (getf field-constraints :max))
        (fixed nil))
    ;; Apply invariant-extracted constraints
    (dolist (c inv-constraints)
      (let ((when-cond (getf c :when)))
        (when (or (null when-cond) (condition-satisfied-p when-cond instance))
          ;; Constant bounds
          (when (getf c :min)
            (setf lo (if lo (max lo (getf c :min)) (getf c :min))))
          (when (getf c :max)
            (setf hi (if hi (min hi (getf c :max)) (getf c :max))))
          ;; Equality
          (when (getf c :eq)
            (setf fixed (getf c :eq)))
          ;; Field-reference bounds
          (when (getf c :min-field)
            (let* ((ref (getf instance (getf c :min-field)))
                   (factor (or (getf c :factor) 1))
                   (exclusive (getf c :exclusive)))
              (when ref
                (let ((bound (+ (* ref factor) (if exclusive 0.001 0))))
                  (setf lo (if lo (max lo bound) bound))))))
          (when (getf c :max-field)
            (let* ((ref (getf instance (getf c :max-field)))
                   (factor (or (getf c :factor) 1))
                   (exclusive (getf c :exclusive)))
              (when ref
                (let ((bound (- (* ref factor) (if exclusive 0.001 0))))
                  (setf hi (if hi (min hi bound) bound))))))
          ;; Equality with field
          (when (getf c :eq-field)
            (let* ((ref (getf instance (getf c :eq-field)))
                   (factor (or (getf c :factor) 1)))
              (when ref (setf fixed (* ref factor)))))
          ;; Config-reference bounds
          (when (getf c :min-config)
            (let ((ref (config (getf c :min-config)))
                  (exclusive (getf c :exclusive)))
              (when ref
                (let ((bound (+ ref (if exclusive 0.001 0))))
                  (setf lo (if lo (max lo bound) bound))))))
          (when (getf c :max-config)
            (let ((ref (config (getf c :max-config)))
                  (exclusive (getf c :exclusive)))
              (when ref
                (let ((bound (- ref (if exclusive 0.001 0))))
                  (setf hi (if hi (min hi bound) bound))))))
          (when (getf c :eq-config)
            (let ((ref (config (getf c :eq-config))))
              (when ref (setf fixed ref)))))))
    (list :min lo :max hi :eq fixed)))

;;; ---------------------------------------------------------------------------
;;; Field dependency ordering
;;; ---------------------------------------------------------------------------

(defun field-deps (field-keyword inv-constraints)
  "Return a list of field keywords that FIELD-KEYWORD depends on via constraints."
  (let ((deps nil))
    (dolist (c inv-constraints)
      (when (getf c :min-field) (pushnew (getf c :min-field) deps))
      (when (getf c :max-field) (pushnew (getf c :max-field) deps))
      (when (getf c :eq-field)  (pushnew (getf c :eq-field) deps)))
    deps))

(defun toposort-fields (non-member-fields constraint-map)
  "Topologically sort NON-MEMBER-FIELDS so dependencies come first.
CONSTRAINT-MAP maps field keywords to lists of constraint plists."
  (let* ((keys (mapcar (lambda (f) (field-keyword (first f))) non-member-fields))
         (key->field (make-hash-table :test #'eq))
         (visited (make-hash-table :test #'eq))
         (sorted nil))
    (dolist (f non-member-fields)
      (setf (gethash (field-keyword (first f)) key->field) f))
    (labels ((visit (k)
               (case (gethash k visited)
                 (:done nil)
                 (:visiting nil) ;; cycle — break it
                 (t
                  (setf (gethash k visited) :visiting)
                  (dolist (dep (field-deps k (gethash k constraint-map)))
                    (when (member dep keys)
                      (visit dep)))
                  (setf (gethash k visited) :done)
                  (push (gethash k key->field) sorted)))))
      (dolist (k keys) (visit k)))
    (nreverse sorted)))

;;; ---------------------------------------------------------------------------
;;; Instance generation
;;; ---------------------------------------------------------------------------

(defun default-generate-instance (entity-name &optional overrides)
  "Generate a random instance of ENTITY-NAME as a plist.
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
         (instance nil)
         (deferred nil))
    ;; Phase 1: generate member/enum fields
    (dolist (field member-fields)
      (let* ((fname (first field))
             (ftype (second field))
             (key (field-keyword fname))
             (override (assoc key overrides)))
        (if override
            (progn (push (cdr override) instance) (push key instance))
            (progn (push (generate-value ftype) instance) (push key instance)))))
    ;; Phase 2: generate non-member fields in dependency order
    (dolist (field sorted-others)
      (let* ((fname (first field))
             (ftype (second field))
             (key (field-keyword fname))
             (fc (field-constraints field))
             (ic (gethash key inv-constraints))
             (override (assoc key overrides)))
        (cond
          (override
           (push (cdr override) instance) (push key instance))
          ((getf fc :derived-from)
           (push nil instance) (push key instance)
           (push (list key (getf fc :derived-from)) deferred))
          (t
           (let* ((bounds (resolve-field-bounds key ic fc instance))
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
    ;; Phase 3: compute derived fields
    (when deferred
      (ensure-entity-accessors entity-name)
      (dolist (entry deferred)
        (destructuring-bind (key form) entry
          (let* ((inst-sym (find-symbol-named "INSTANCE" form))
                 (fn (handler-bind ((warning #'muffle-warning))
                       (compile nil `(lambda (,inst-sym) ,form)))))
            (setf (getf instance key) (funcall fn instance))))))
    instance))

(defun generate-config ()
  "Generate a random config plist from *CONFIG* field specs."
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
                         (cons (cons (getf variant :discriminator)
                                     (getf variant :value))
                               (or overrides nil))
                         overrides))
                   (inst (default-generate-instance entity-name eff-overrides))
                   (full-inst (if variant
                                  (generate-variant-fields variant inst)
                                  inst))
                   (violations (check-invariants entity-name full-inst))
                   (n (length violations)))
              (when (< n best-n)
                (setf best full-inst best-n n))
              (when (zerop n)
                (return-from generate-instance full-inst))))
          best))))

(defmacro defgenerator (entity-name (overrides-var) &body body)
  "Register a custom instance generator for ENTITY-NAME.
The generator receives OVERRIDES (an alist of (keyword . value) or NIL)
and must return a plist. GENERATE-VALUE and DEFAULT-GENERATE-INSTANCE
are available within the body for building instances.

  (defgenerator trader (overrides)
    (let ((inst (default-generate-instance \"trader\" overrides)))
      (when (getf inst :suspended)
        (setf (getf inst :margin-ratio) (random 0.5)))
      inst))"
  (let ((key (string-downcase (string entity-name))))
    `(progn
       (setf (gethash ,key *generators*)
             (lambda (,overrides-var)
               ,@body))
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

;;; ---------------------------------------------------------------------------
;;; Invariant checking
;;; ---------------------------------------------------------------------------

(defun invariants-for (entity-name)
  "Return a list of (inv-name inv-plist) for invariants that apply to ENTITY-NAME."
  (let* ((entity (describe-entity entity-name))
         (entity-sym (getf entity :name)))
    (loop for inv-name in (list-invariants)
          for inv = (describe-invariant inv-name)
          when (string-equal (symbol-name (getf inv :on))
                             (symbol-name entity-sym))
            collect (list inv-name inv))))

(defun variant-invariants-for (variant-name)
  "Return a list of (inv-name inv-plist) for invariants whose :on matches VARIANT-NAME."
  (let ((vname (string-downcase (string variant-name))))
    (loop for inv-name in (list-invariants)
          for inv = (describe-invariant inv-name)
          when (string-equal (string-downcase (symbol-name (getf inv :on)))
                             vname)
            collect (list inv-name inv))))

(defun check-invariants (entity-name instance)
  "Check all invariants for ENTITY-NAME against INSTANCE.
Also checks variant-specific invariants when the discriminator matches.
Returns a list of violated invariant name strings. Empty list = all pass."
  (let ((violations nil))
    ;; Base entity invariants
    (dolist (entry (invariants-for entity-name))
      (destructuring-bind (inv-name inv) entry
        (let ((on-sym (getf inv :on))
              (check-form (getf inv :check)))
          (handler-case
              (let ((fn (handler-bind ((warning #'muffle-warning))
                          (compile nil `(lambda (,on-sym) ,check-form)))))
                (unless (funcall fn instance)
                  (push inv-name violations)))
            (error (e)
              (push (format nil "~A (error: ~A)" inv-name e) violations))))))
    ;; Variant-specific invariants
    (dolist (vkey (entity-variants entity-name))
      (let* ((variant (describe-variant vkey))
             (disc (getf variant :discriminator))
             (val (getf variant :value))
             (actual (getf instance disc)))
        (when (eq actual val)
          (dolist (entry (variant-invariants-for vkey))
            (destructuring-bind (inv-name inv) entry
              (let ((on-sym (getf inv :on))
                    (check-form (getf inv :check)))
                (handler-case
                    (let ((fn (handler-bind ((warning #'muffle-warning))
                                (compile nil `(lambda (,on-sym) ,check-form)))))
                      (unless (funcall fn instance)
                        (push inv-name violations)))
                  (error (e)
                    (push (format nil "~A (error: ~A)" inv-name e) violations)))))))))
    (nreverse violations)))

;;; ---------------------------------------------------------------------------
;;; PBT runner
;;; ---------------------------------------------------------------------------

(defun ensure-config-accessor ()
  "Ensure CONFIG function is available in the caller's package."
  (let ((sym (intern "CONFIG")))
    (unless (fboundp sym)
      (setf (symbol-function sym)
            (lambda (key) (getf *current-config* key))))))

(defun run-pbt-trials (trials)
  "Run one round of entity trials with the current *CURRENT-CONFIG* binding.
Returns (values results total-passed total-failed)."
  (let ((results nil)
        (total-passed 0)
        (total-failed 0))
    (dolist (entity-name (list-entities))
      (let* ((relevant (invariants-for entity-name))
             (variant-invs (loop for vkey in (entity-variants entity-name)
                                 nconc (variant-invariants-for vkey)))
             (all-relevant (append relevant variant-invs)))
        (when all-relevant
          (let ((passed 0)
                (failed 0)
                (failures nil))
            (dotimes (i trials)
              (let* ((instance (generate-instance entity-name))
                     (violations (check-invariants entity-name instance)))
                (if violations
                    (progn
                      (incf failed)
                      (when (< (length failures) 3)
                        (push (list :instance instance :violations violations)
                              failures)))
                    (incf passed))))
            (incf total-passed passed)
            (incf total-failed failed)
            (push (list :entity entity-name
                        :invariants (mapcar #'first all-relevant)
                        :trials trials
                        :passed passed
                        :failed failed
                        :failures (nreverse failures))
                  results)))))
    (values (nreverse results) total-passed total-failed)))

(defun run-pbt (&key (trials 100) (config-trials 5))
  "Run property-based testing on all entities with invariants.
Generates TRIALS random instances per entity and checks all applicable
invariants. When *CONFIG* is defined, runs CONFIG-TRIALS rounds with
random configs to test across configuration space.
Returns a list of result plists and prints a summary."
  ;; Set up accessors for all entities and variants
  (dolist (name (list-entities))
    (ensure-entity-accessors name))
  (dolist (name (list-variants))
    (ensure-variant-accessors name))
  ;; Set up config accessor in caller's package
  (when *config*
    (ensure-config-accessor))
  ;; Run trials
  (let ((all-results nil)
        (grand-passed 0)
        (grand-failed 0))
    (if *config*
        ;; Config-aware: multiple config trials
        (dotimes (ct config-trials)
          (let ((*current-config* (generate-config)))
            (multiple-value-bind (results passed failed)
                (run-pbt-trials trials)
              (setf all-results (append all-results results))
              (incf grand-passed passed)
              (incf grand-failed failed))))
        ;; No config: single round
        (multiple-value-bind (results passed failed)
            (run-pbt-trials trials)
          (setf all-results results)
          (setf grand-passed passed)
          (setf grand-failed failed)))
    ;; Merge results by entity (sum across config trials)
    (let ((merged (make-hash-table :test #'equal)))
      (dolist (r all-results)
        (let* ((ename (getf r :entity))
               (existing (gethash ename merged)))
          (if existing
              (progn
                (incf (getf existing :passed) (getf r :passed))
                (incf (getf existing :failed) (getf r :failed))
                (incf (getf existing :trials) (getf r :trials))
                (let ((new-failures (getf r :failures)))
                  (when (and new-failures (< (length (getf existing :failures)) 3))
                    (setf (getf existing :failures)
                          (append (getf existing :failures)
                                  (subseq new-failures 0
                                          (min (length new-failures)
                                               (- 3 (length (getf existing :failures))))))))))
              (setf (gethash ename merged) (copy-list r)))))
      ;; Print summary
      (let ((final-results nil))
        (maphash (lambda (k v) (declare (ignore k)) (push v final-results)) merged)
        (setf final-results (nreverse final-results))
        (format t "~%=== PBT Results ===~%")
        (when *config*
          (format t "(~A config trials x ~A entity trials)~%" config-trials trials))
        (dolist (r final-results)
          (format t "~%~A (~A invariants)~%  ~A/~A passed"
                  (getf r :entity)
                  (length (getf r :invariants))
                  (getf r :passed)
                  (getf r :trials))
          (when (plusp (getf r :failed))
            (format t ", ~A FAILED" (getf r :failed))
            (dolist (f (getf r :failures))
              (format t "~%  counterexample: ~S~%    violated: ~{~A~^, ~}"
                      (getf f :instance)
                      (getf f :violations)))))
        (format t "~%~%Total: ~A passed, ~A failed~%"
                grand-passed grand-failed)
        final-results))))
