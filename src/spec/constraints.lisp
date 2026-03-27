(defpackage #:mcp-lisp/src/spec/constraints
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/registry
                #:*invariants*)
  (:import-from #:mcp-lisp/src/spec/introspection
                #:describe-entity
                #:list-invariants
                #:describe-invariant
                #:entity-fields
                #:entity-relations
                #:config)
  (:import-from #:mcp-lisp/src/spec/checking
                #:invariants-for)
  (:import-from #:mcp-lisp/src/spec/pbt-util
                #:getf-field-p
                #:pure-field-expr-p
                #:eval-field-expr
                #:config-ref-p
                #:field-constraints
                #:member-type-p
                #:field-keyword)
  (:export #:extract-comparison
           #:extract-condition
           #:negate-condition
           #:extract-constraints-from-form
           #:extract-generation-constraints
           #:condition-satisfied-p
           #:resolve-field-bounds
           #:field-deps
           #:toposort-fields))

(in-package #:mcp-lisp/src/spec/constraints)

;;; ---------------------------------------------------------------------------
;;; Invariant constraint extraction
;;; ---------------------------------------------------------------------------

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
        ;; (op (getf e :f) pure-field-expr) — generic expression on RHS
        ((and lf (pure-field-expr-p rhs entity-var))
         (let ((deps (pure-field-expr-p rhs entity-var)))
           (list (case op
                   ((>= >) (list :field lf :min-expr rhs :deps deps))
                   ((<= <) (list :field lf :max-expr rhs :deps deps))
                   (=      (list :field lf :eq-expr rhs :deps deps))))))
        ;; (op pure-field-expr (getf e :f)) — generic expression on LHS
        ((and rf (pure-field-expr-p lhs entity-var))
         (let ((deps (pure-field-expr-p lhs entity-var)))
           (list (case op
                   ;; reversed: (>= expr field) means field <= expr
                   ((>= >) (list :field rf :max-expr lhs :deps deps))
                   ((<= <) (list :field rf :min-expr lhs :deps deps))
                   (=      (list :field rf :eq-expr lhs :deps deps))))))))))

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
             (list :field field :values values :negated nil))))))
    ;; Bare boolean accessor: (entity-field entity-var) → treat as (eq field T)
    ((getf-field-p form entity-var)
     (list :field (getf-field-p form entity-var) :value t :negated nil))))

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

(defun resolve-field-bounds (field-keyword inv-constraints field-constraints instance
                             &optional entity-var)
  "Given a field's invariant constraints, field-level :min/:max, and current instance,
compute effective generation bounds. Returns (:min N :max N :eq N).
ENTITY-VAR is needed for evaluating expression constraints."
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
          ;; Expression constraints (generic arithmetic over fields)
          (when (getf c :eq-expr)
            (let ((val (eval-field-expr (getf c :eq-expr) entity-var instance)))
              (when val (setf fixed val))))
          (when (getf c :min-expr)
            (let ((val (eval-field-expr (getf c :min-expr) entity-var instance)))
              (when val
                (setf lo (if lo (max lo val) val)))))
          (when (getf c :max-expr)
            (let ((val (eval-field-expr (getf c :max-expr) entity-var instance)))
              (when val
                (setf hi (if hi (min hi val) val)))))
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
      (when (getf c :eq-field)  (pushnew (getf c :eq-field) deps))
      ;; Expression constraints: deps listed explicitly
      (when (getf c :deps)
        (dolist (d (getf c :deps)) (pushnew d deps)))
      ;; Conditional constraints depend on the condition field
      (when (getf c :when)
        (let ((cond-field (getf (getf c :when) :field)))
          (when cond-field (pushnew cond-field deps)))))
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
