;;;; src/spec/pbt.lisp
;;;;
;;;; Property-based testing for behavioral specs. Generates random entity
;;;; instances from field type specs and checks invariants against them.

(defpackage #:mcp-lisp/src/spec/pbt
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/spec
                #:*entities*
                #:*rules*
                #:*invariants*
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
                #:*compiled-fn-cache*
                #:config
                #:describe-entity
                #:list-entities
                #:describe-rule
                #:list-rules
                #:describe-invariant
                #:list-invariants
                #:describe-variant
                #:entity-variants
                #:list-variants
                #:describe-scenario
                #:list-scenarios
                #:entity-fields
                #:entity-relations)
  (:import-from #:mcp-lisp/src/spec/transitions
                #:detect-state-fields
                #:field-default)
  (:export #:generate-value
           #:generate-instance
           #:default-generate-instance
           #:defgenerator
           #:override-val
           #:override-present-p
           #:ensure-entity-accessors
           #:ensure-variant-accessors
           #:generate-config
           #:check-invariants
           #:check-scenario-invariants
           #:invariants-for
           #:scenario-invariants-for
           #:generate-scenario
           #:default-generate-scenario
           #:defscenario-generator
           #:defscenario-negative-generator
           #:current-config
           #:shrink-scenario
           #:run-pbt
           #:check-scenario
           #:extract-generation-constraints
           #:getf-field-p
           #:apply-rule
           #:applicable-rules
           #:random-walk
           #:all-pairs-check
           #:consecutive-pairs-check
           #:haversine-distance-nm
           #:intervals-overlap-p
           #:interval-contains-p
           #:interval-before-p))

(in-package #:mcp-lisp/src/spec/pbt)

;;; ---------------------------------------------------------------------------
;;; Compiled function cache
;;; ---------------------------------------------------------------------------

(defun get-compiled-fn (cache-key params body)
  "Compile and memoize a lambda by its logical identity and source shape."
  (let ((full-key (list cache-key params body)))
    (or (gethash full-key *compiled-fn-cache*)
        (setf (gethash full-key *compiled-fn-cache*)
              (handler-bind ((warning #'muffle-warning))
                (compile nil `(lambda ,params ,body)))))))

;;; ---------------------------------------------------------------------------
;;; Value generators
;;; ---------------------------------------------------------------------------

(defparameter +alphanumeric+ "abcdefghijklmnopqrstuvwxyz0123456789")

(defun generate-value (type-spec &key min max)
  "Generate a random value conforming to TYPE-SPEC.
Optional MIN and MAX constrain numeric types."
  (cond
    ((eq type-spec 'string)
     (let ((len (1+ (random 20))))
       (map 'string
            (lambda (x)
              (declare (ignore x))
              (char +alphanumeric+ (random (length +alphanumeric+))))
            (make-string len))))
    ((eq type-spec 'number)
     (let ((lo (or min -1000.0))
           (hi (or max 1000.0)))
       (if (<= hi lo) lo
           (+ lo (random (- hi lo))))))
    ((eq type-spec 'integer)
     (let ((lo (or (and min (ceiling min)) -100))
           (hi (or (and max (floor max)) 100)))
       (if (> lo hi) lo
           (+ lo (random (1+ (- hi lo)))))))
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

(defvar *override-sentinel* (gensym "OVERRIDE-SENTINEL"))

(defun override-val (overrides key &optional default)
  "Look up KEY in OVERRIDES plist. Returns the value if present, DEFAULT otherwise.
Uses a sentinel to distinguish missing keys from nil/0/\"\" values.
OVERRIDES is a plist (:key1 val1 :key2 val2 ...)."
  (let ((val (getf overrides key *override-sentinel*)))
    (if (eq val *override-sentinel*) default val)))

(defun override-present-p (overrides key)
  "Return T if KEY is present in OVERRIDES plist, even if its value is NIL/0/\"\"."
  (not (eq (getf overrides key *override-sentinel*) *override-sentinel*)))

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

(defun pure-field-expr-p (form entity-var)
  "Check if FORM is a pure arithmetic expression over entity fields and constants.
Returns a list of field keywords referenced, or NIL if not a pure expression.
Recognizes +, -, *, /, abs, mod, expt, min, max, and nested combinations."
  (cond
    ;; Field access → single dependency
    ((getf-field-p form entity-var)
     (list (getf-field-p form entity-var)))
    ;; Numeric constant → no dependencies
    ((numberp form) nil)
    ;; Arithmetic expression → union of sub-dependencies
    ((and (consp form)
          (member (first form) '(+ - * / abs mod expt min max))
          (>= (length form) 2))
     (let ((deps nil)
           (ok t))
       (dolist (sub (cdr form))
         (let ((sub-deps (pure-field-expr-p sub entity-var)))
           (if (and (null sub-deps) (not (numberp sub))
                    (not (getf-field-p sub entity-var)))
               (progn (setf ok nil) (return))
               (setf deps (union deps sub-deps)))))
       (when ok deps)))
    (t nil)))

(defun eval-field-expr (form entity-var instance)
  "Evaluate a pure field expression by substituting field values from INSTANCE.
Returns the numeric result, or NIL if any field is missing from instance."
  (cond
    ;; Field access → look up value
    ((getf-field-p form entity-var)
     (let ((val (getf instance (getf-field-p form entity-var))))
       (when (numberp val) val)))
    ;; Numeric constant
    ((numberp form) form)
    ;; Arithmetic expression
    ((and (consp form) (member (first form) '(+ - * / abs mod expt min max)))
     (let* ((op (first form))
            (args (cdr form))
            (vals (mapcar (lambda (sub)
                            (eval-field-expr sub entity-var instance))
                          args)))
       (when (every #'numberp vals)
         (case op
           (+    (apply #'+ vals))
           (-    (apply #'- vals))
           (*    (apply #'* vals))
           (/    (when (every (lambda (v) (not (zerop v))) (cdr vals))
                   (apply #'/ vals)))
           (abs  (abs (first vals)))
           (mod  (mod (first vals) (second vals)))
           (expt (expt (first vals) (second vals)))
           (min  (apply #'min vals))
           (max  (apply #'max vals))))))
    (t nil)))

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
         (instance nil)
         (deferred nil))
    ;; Phase 1: generate member/enum fields
    (dolist (field member-fields)
      (let* ((fname (first field))
             (ftype (second field))
             (key (field-keyword fname)))
        (if (override-present-p overrides key)
            (progn (push (override-val overrides key) instance) (push key instance))
            (progn (push (generate-value ftype) instance) (push key instance)))))
    ;; Phase 2: generate non-member fields in dependency order
    (dolist (field sorted-others)
      (let* ((fname (first field))
             (ftype (second field))
             (key (field-keyword fname))
             (fc (field-constraints field))
             (ic (gethash key inv-constraints)))
        (cond
          ((override-present-p overrides key)
           (push (override-val overrides key) instance) (push key instance))
          ((getf fc :derived-from)
           (push nil instance) (push key instance)
           (push (list key (getf fc :derived-from)) deferred))
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
Returns (:PASS) when all invariants hold, or (:FAIL inv1 inv2 ...) with
the names of violated invariants."
  (let ((violations nil))
    ;; Base entity invariants
    (dolist (entry (invariants-for entity-name))
      (destructuring-bind (inv-name inv) entry
        (let ((on-sym (getf inv :on))
              (check-form (getf inv :check)))
          (handler-case
              (let ((fn (get-compiled-fn inv-name (list on-sym) check-form)))
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
                    (let ((fn (get-compiled-fn inv-name (list on-sym) check-form)))
                      (unless (funcall fn instance)
                        (push inv-name violations)))
                  (error (e)
                    (push (format nil "~A (error: ~A)" inv-name e) violations)))))))))
    (if violations
        (cons :fail (nreverse violations))
        '(:pass))))

;;; ---------------------------------------------------------------------------
;;; Scenario invariants
;;; ---------------------------------------------------------------------------

(defun scenario-invariants-for (scenario-name)
  "Return a list of (inv-name inv-plist) for invariants whose :on matches SCENARIO-NAME."
  (let ((sname (string-downcase (string scenario-name))))
    (loop for inv-name in (list-invariants)
          for inv = (describe-invariant inv-name)
          when (string-equal (string-downcase (symbol-name (getf inv :on)))
                             sname)
            collect (list inv-name inv))))

(defun check-scenario-invariants (scenario-name scenario-instance)
  "Check all scenario-level invariants for SCENARIO-NAME against SCENARIO-INSTANCE.
SCENARIO-INSTANCE is a plist mapping binding keywords to instances (or lists of instances).
Invariant check forms receive bindings as variables via flat-binding:
singular bindings (cardinality 1) are single plists, plural bindings are lists.
Returns (:PASS) when all invariants hold, or (:FAIL inv1 inv2 ...) with violation names."
  (let ((scenario (describe-scenario scenario-name))
        (violations nil))
    (when scenario
      (let* ((bindings (getf scenario :entities))
             ;; Build (sym value) pairs for let-binding
             (bind-pairs
               (mapcar (lambda (espec)
                         (let* ((binding-kw (getf espec :binding))
                                (sym (intern (symbol-name binding-kw)))
                                (val (getf scenario-instance binding-kw)))
                           (list sym val)))
                       bindings)))
        (dolist (entry (scenario-invariants-for scenario-name))
          (destructuring-bind (inv-name inv) entry
            (let ((check-form (getf inv :check)))
              (handler-case
                  (let* ((params (mapcar #'first bind-pairs))
                         (fn (get-compiled-fn inv-name params check-form)))
                    (unless (apply fn (mapcar #'second bind-pairs))
                      (push inv-name violations)))
                (error (e)
                  (push (format nil "~A (error: ~A)" inv-name e) violations))))))))
    (if violations
        (cons :fail (nreverse violations))
        '(:pass))))

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
                         (n (if (= emin emax) emin
                                (+ emin (random (1+ (- emax emin)))))))
                    (let ((instances nil))
                      (dotimes (_i n)
                        (push (generate-instance entity-name fk-ov) instances))
                      (setf (getf result binding) (nreverse instances)))))))))
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
;;; PBT runner
;;; ---------------------------------------------------------------------------

(defun ensure-config-accessor ()
  "Ensure CONFIG function is available in the caller's package."
  (let ((sym (intern "CONFIG")))
    (unless (fboundp sym)
      (setf (symbol-function sym)
            (lambda (key) (getf *current-config* key))))))

(defun generate-raw-instance (entity-name)
  "Generate a random instance of ENTITY-NAME WITHOUT constraint-aware generation.
All fields are independently random — used for negative testing."
  (let* ((entity (describe-entity entity-name))
         (fields (getf entity :fields))
         (instance nil))
    (dolist (field fields)
      (let* ((fname (first field))
             (ftype (second field))
             (key (field-keyword fname))
             (fc (field-constraints field)))
        (push (generate-value ftype :min (getf fc :min) :max (getf fc :max))
              instance)
        (push key instance)))
    instance))

(defun classify-zero-rejection (check-form &optional entity-name)
  "Classify why an invariant might never reject unconstrained data.
Returns a string label or NIL. ENTITY-NAME, if provided, enables
field-aware analysis (required/min/max, has-many accessors)."
  (when (consp check-form)
    (labels ((uses-p (syms form)
               (cond
                 ((and (symbolp form) (member (symbol-name form) syms
                                              :test #'string-equal))
                  t)
                 ((consp form) (some (lambda (f) (uses-p syms f)) form))))
             (uses-config-p (form)
               (cond
                 ((and (consp form) (= (length form) 2)
                       (symbolp (first form))
                       (string-equal (symbol-name (first form)) "CONFIG"))
                  t)
                 ((consp form) (some #'uses-config-p form))))
             (has-many-accessor-p ()
               (when entity-name
                 (let ((rels (entity-relations entity-name)))
                   (some (lambda (rel)
                           (when (eq (first rel) :has-many)
                             (let ((acc (format nil "~A-~A"
                                                (string-upcase (string entity-name))
                                                (symbol-name (second rel)))))
                               (uses-p (list acc) check-form))))
                         rels))))
             (all-fields-bounded-p ()
               (when entity-name
                 (let ((fields (entity-fields entity-name))
                       (all-bounded t))
                   (when fields
                     (dolist (field fields)
                       (let* ((ftype (second field))
                              (kwargs (cddr field))
                              (required (getf kwargs :required))
                              (has-min (getf kwargs :min))
                              (has-max (getf kwargs :max))
                              (is-member (member-type-p ftype)))
                         (unless (or required has-min has-max is-member)
                           (setf all-bounded nil)
                           (return))))
                     all-bounded)))))
      (cond
        ((has-many-accessor-p)
         "requires scenario-level testing — uses has-many accessor")
        ((uses-p '("REMOVE-DUPLICATES" "DELETE-DUPLICATES") check-form)
         "structurally untestable — uniqueness over high-entropy field")
        ((and (uses-p '("<" ">" "<=" ">=" "PLUSP") check-form)
              (uses-config-p check-form))
         "weak bounds — test with extreme config values")
        ((and (uses-p '("NOT" "NULL") check-form)
              (all-fields-bounded-p))
         "enforced by schema — all fields required or typed")
        ((and (uses-p '("<" ">" "<=" ">=" "PLUSP") check-form)
              (not (uses-config-p check-form))
              (all-fields-bounded-p))
         "enforced by field bounds — :min/:max or :required constraints")
        ((and (uses-p '("IF" "WHEN" "COND") check-form)
              (uses-p '("EQ" "MEMBER") check-form))
         "conditional — needs targeted negative generator (defscenario-negative-generator)")
        (t nil)))))

(defun run-negative-trials (trials)
  "Run negative PBT: generate unconstrained random instances and check that
invariants correctly reject them. Returns per-invariant rejection stats.
Invariants that never reject unconstrained data are flagged as suspicious."
  (let ((inv-stats (make-hash-table :test #'equal)))
    (dolist (entity-name (list-entities))
      (let ((relevant (invariants-for entity-name)))
        (when relevant
          ;; Initialize per-invariant counters
          (dolist (entry relevant)
            (let ((inv-name (first entry)))
              (setf (gethash inv-name inv-stats)
                    (list :entity entity-name :tested 0 :rejected 0))))
          (dotimes (i trials)
            (let ((instance (generate-raw-instance entity-name)))
              (dolist (entry relevant)
                (destructuring-bind (inv-name inv) entry
                  (let* ((on-sym (getf inv :on))
                         (check-form (getf inv :check))
                         (stats (gethash inv-name inv-stats)))
                    (incf (getf stats :tested))
                    (handler-case
                        (let ((fn (get-compiled-fn inv-name (list on-sym) check-form)))
                          (unless (funcall fn instance)
                            (incf (getf stats :rejected))))
                      (error ()
                        (incf (getf stats :rejected))))))))))))
    inv-stats))

(defun check-scenario-instance-against-invariants (scenario invs instance)
  "Check a single scenario instance against all invariants.
Returns a list of invariant names that rejected (failed) the instance."
  (let ((rejected nil)
        (bindings (getf scenario :entities)))
    (let ((bind-pairs
            (mapcar (lambda (es)
                      (let* ((bkw (getf es :binding))
                             (sym (intern (symbol-name bkw)))
                             (val (getf instance bkw)))
                        (list sym val)))
                    bindings)))
      (dolist (entry invs)
        (destructuring-bind (inv-name inv) entry
          (handler-case
              (let* ((params (mapcar #'first bind-pairs))
                     (fn (get-compiled-fn inv-name params (getf inv :check))))
                (unless (apply fn (mapcar #'second bind-pairs))
                  (push inv-name rejected)))
            (error ()
              (push inv-name rejected))))))
    (nreverse rejected)))

(defun run-negative-scenario-trials (trials)
  "Run negative PBT for scenarios: generate uncorrelated random instances for each
entity in each scenario and check that scenario invariants reject them.
When a defscenario-negative-generator is registered, uses it to produce targeted
bad data and verifies every generated instance is actually rejected.
Returns per-invariant rejection stats merged into the same hash table format."
  (let ((inv-stats (make-hash-table :test #'equal))
        (neg-gen-ok nil)
        (neg-gen-broken nil))
    (dolist (sname (list-scenarios))
      (let ((invs (scenario-invariants-for sname)))
        (when invs
          (let ((scenario (describe-scenario sname))
                (neg-gen (gethash sname *scenario-negative-generators*)))
            (dolist (entry invs)
              (setf (gethash (first entry) inv-stats)
                    (list :entity (format nil "scenario:~A" sname)
                          :tested 0 :rejected 0)))
            ;; Random negative trials (uncorrelated generation)
            (dotimes (_i trials)
              (let ((raw-instance nil))
                (dolist (espec (getf scenario :entities))
                  (let* ((binding (getf espec :binding))
                         (entity-name (getf espec :entity))
                         (emin (getf espec :min))
                         (emax (getf espec :max))
                         (n (if (= emin emax) emin
                                (+ emin (random (1+ (- emax emin)))))))
                    (if (and (= n 1) (= emin emax))
                        (setf (getf raw-instance binding)
                              (generate-raw-instance entity-name))
                        (setf (getf raw-instance binding)
                              (loop repeat n
                                    collect (generate-raw-instance entity-name))))))
                (let ((rejected (check-scenario-instance-against-invariants
                                  scenario invs raw-instance)))
                  (dolist (entry invs)
                    (let* ((inv-name (first entry))
                           (stats (gethash inv-name inv-stats)))
                      (incf (getf stats :tested))
                      (when (member inv-name rejected :test #'string=)
                        (incf (getf stats :rejected))))))))
            ;; Targeted negative trials (from defscenario-negative-generator)
            (when neg-gen
              (let ((neg-passed 0) (neg-total 0))
                (dotimes (_i trials)
                  (handler-case
                      (let* ((bad-instance (funcall neg-gen nil))
                             (rejected (check-scenario-instance-against-invariants
                                         scenario invs bad-instance)))
                        (incf neg-total)
                        (if rejected
                            (dolist (entry invs)
                              (let* ((inv-name (first entry))
                                     (stats (gethash inv-name inv-stats)))
                                (incf (getf stats :tested))
                                (when (member inv-name rejected :test #'string=)
                                  (incf (getf stats :rejected)))))
                            (incf neg-passed)))
                    (error () (incf neg-total))))
                (if (zerop neg-passed)
                    (push sname neg-gen-ok)
                    (push (cons sname neg-passed) neg-gen-broken))))))))
    (values inv-stats neg-gen-ok neg-gen-broken)))

(defun check-form-field-keys (check-form entity-name)
  "Extract field keywords referenced in CHECK-FORM for ENTITY-NAME.
Walks the form tree looking for accessor symbols (ENTITY-FIELD pattern)."
  (let* ((entity (describe-entity entity-name))
         (entity-sym (getf entity :name))
         (fields (getf entity :fields))
         (relations (getf entity :relations))
         (field-map (make-hash-table :test #'equal))
         (result nil))
    (let ((prefix (symbol-name entity-sym)))
      (dolist (field fields)
        (let* ((fname (first field))
               (acc (format nil "~A-~A" prefix (symbol-name fname))))
          (setf (gethash acc field-map) (field-keyword fname))))
      (dolist (rel relations)
        (let* ((rname (second rel))
               (acc (format nil "~A-~A" prefix (symbol-name rname))))
          (setf (gethash acc field-map) (field-keyword rname)))))
    (dolist (vkey (entity-variants entity-name))
      (let* ((variant (describe-variant vkey))
             (vsym (getf variant :name))
             (vfields (getf variant :fields)))
        (dolist (field vfields)
          (let* ((fname (first field))
                 (acc (format nil "~A-~A" (symbol-name vsym) (symbol-name fname))))
            (setf (gethash acc field-map) (field-keyword fname))))))
    (labels ((walk (form)
               (cond
                 ((symbolp form)
                  (let ((key (gethash (symbol-name form) field-map)))
                    (when (and key (not (member key result)))
                      (push key result))))
                 ((consp form)
                  (walk (car form))
                  (walk (cdr form))))))
      (walk check-form))
    (nreverse result)))

(defun compact-instance (instance keys)
  "Return a plist containing only KEYS from INSTANCE."
  (let ((sentinel (gensym)))
    (loop for key in keys
          for val = (getf instance key sentinel)
          unless (eq val sentinel)
            nconc (list key val))))

(defun run-pbt-trials (trials)
  "Run one round of entity trials with the current *CURRENT-CONFIG* binding.
Returns (values results total-passed total-failed).
Failures are grouped per-invariant with compact instances (relevant fields only)."
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
                (inv-failures (make-hash-table :test #'equal)))
            (dotimes (i trials)
              (let* ((instance (generate-instance entity-name))
                     (result (check-invariants entity-name instance))
                     (violations (when (eq (car result) :fail) (cdr result))))
                (if violations
                    (progn
                      (incf failed)
                      (dolist (vname violations)
                        (let ((examples (gethash vname inv-failures)))
                          (when (< (length examples) 3)
                            (let* ((base-name (let ((pos (search " (error:" vname)))
                                                (if pos (subseq vname 0 pos) vname)))
                                   (inv (or (describe-invariant vname)
                                            (describe-invariant base-name)))
                                   (keys (when inv
                                           (check-form-field-keys
                                            (getf inv :check) entity-name)))
                                   (compact (if keys
                                                (compact-instance instance keys)
                                                instance)))
                              (setf (gethash vname inv-failures)
                                    (append examples (list compact))))))))
                    (incf passed))))
            (let ((failures nil))
              (maphash (lambda (k v) (push (cons k v) failures)) inv-failures)
              (incf total-passed passed)
              (incf total-failed failed)
              (push (list :entity entity-name
                          :invariants (length all-relevant)
                          :trials trials
                          :passed passed
                          :failed failed
                          :failures (nreverse failures))
                    results))))))
    (values (nreverse results) total-passed total-failed)))

(defun shrink-scenario (scenario-name instance)
  "Attempt to minimize a failing scenario instance by removing list elements.
For each list binding, try removing one element at a time. Keep removals that
preserve the failure. Returns the shrunk scenario instance."
  (let* ((scenario (describe-scenario scenario-name))
         (entity-specs (getf scenario :entities))
         (current (copy-list instance))
         (changed t))
    (loop while changed do
      (setf changed nil)
      (dolist (espec entity-specs)
        (let* ((binding (getf espec :binding))
               (val (getf current binding)))
          (when (and (listp val) (> (length val) 1)
                     (not (keywordp (car val))))
            (dotimes (i (length val))
              (let* ((without (append (subseq val 0 i) (subseq val (1+ i))))
                     (trial (copy-list current)))
                (setf (getf trial binding) without)
                (let* ((sr (check-scenario-invariants scenario-name trial))
                       (sv (when (eq (car sr) :fail) (cdr sr))))
                  (when sv
                    (setf current trial
                          val without
                          changed t)
                    (return)))))))))
    current))

(defun run-scenario-trials (scenario-name trials)
  "Run scenario PBT trials. Returns a result plist.
Failures store only violation descriptions, not full scenario instances."
  (let* ((invs (scenario-invariants-for scenario-name))
         (scenario (describe-scenario scenario-name))
         (entity-specs (getf scenario :entities))
         (passed 0)
         (failed 0)
         (failures nil))
    (dotimes (i trials)
      (let* ((instance (generate-scenario scenario-name))
             (scenario-result (check-scenario-invariants scenario-name instance))
             (scenario-violations (when (eq (car scenario-result) :fail)
                                    (cdr scenario-result)))
             (entity-violations nil))
        (dolist (espec entity-specs)
          (let* ((binding (getf espec :binding))
                 (entity-name (getf espec :entity))
                 (val (getf instance binding))
                 (instances (if (listp val)
                                (if (and val (keywordp (car val)))
                                    (list val)
                                    val)
                                (list val))))
            (dolist (inst instances)
              (when inst
                (let* ((r (check-invariants entity-name inst))
                       (v (when (eq (car r) :fail) (cdr r))))
                  (when v
                    (push (format nil "~A.~A: ~{~A~^, ~}"
                                  binding entity-name v)
                          entity-violations)))))))
        (let ((all-v (remove-duplicates
                      (append scenario-violations (nreverse entity-violations))
                      :test #'string=)))
          (if all-v
              (progn
                (incf failed)
                (when (< (length failures) 3)
                  (push all-v failures)))
              (incf passed)))))
    (list :entity (format nil "scenario:~A" scenario-name)
          :invariants (length invs)
          :trials trials
          :passed passed
          :failed failed
          :failures (nreverse failures))))

(defun run-pbt (&key (trials 100) (config-trials 5) scenario (negative-trials 0) (verbose t))
  "Run property-based testing on all entities with invariants.
Generates TRIALS random instances per entity and checks all applicable
invariants. When *CONFIG* is defined, runs CONFIG-TRIALS rounds with
random configs to test across configuration space.
When SCENARIO is provided (name string), runs only that scenario's PBT.
When NEGATIVE-TRIALS is positive, also generates unconstrained random instances
and verifies that invariants reject them (catches trivially-true invariants).
When VERBOSE is NIL, prints only pass/fail counts (no counterexamples).
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
            (unless scenario
              (multiple-value-bind (results passed failed)
                  (run-pbt-trials trials)
                (setf all-results (append all-results results))
                (incf grand-passed passed)
                (incf grand-failed failed)))
            ;; Scenario trials
            (let ((scenario-names (if scenario
                                      (list (string-downcase (string scenario)))
                                      (list-scenarios))))
              (dolist (sname scenario-names)
                (when (scenario-invariants-for sname)
                  (let ((r (run-scenario-trials sname trials)))
                    (push r all-results)
                    (incf grand-passed (getf r :passed))
                    (incf grand-failed (getf r :failed))))))))
        ;; No config
        (progn
          (unless scenario
            (multiple-value-bind (results passed failed)
                (run-pbt-trials trials)
              (setf all-results results)
              (setf grand-passed passed)
              (setf grand-failed failed)))
          ;; Scenario trials
          (let ((scenario-names (if scenario
                                    (list (string-downcase (string scenario)))
                                    (list-scenarios))))
            (dolist (sname scenario-names)
              (when (scenario-invariants-for sname)
                (let ((r (run-scenario-trials sname trials)))
                  (push r all-results)
                  (incf grand-passed (getf r :passed))
                  (incf grand-failed (getf r :failed))))))))
    ;; Merge results by entity/scenario (sum across config trials)
    (let ((merged (make-hash-table :test #'equal)))
      (dolist (r all-results)
        (let* ((ename (getf r :entity))
               (existing (gethash ename merged)))
          (if existing
              (progn
                (incf (getf existing :passed) (getf r :passed))
                (incf (getf existing :failed) (getf r :failed))
                (incf (getf existing :trials) (getf r :trials))
                (let ((new-failures (getf r :failures))
                      (existing-f (getf existing :failures))
                      (is-scenario (and (stringp ename)
                                        (>= (length ename) 9)
                                        (string= "scenario:" ename :end2 9))))
                  (when new-failures
                    (if is-scenario
                        ;; Scenario: append violation lists, cap at 3
                        (when (< (length existing-f) 3)
                          (setf (getf existing :failures)
                                (append existing-f
                                        (subseq new-failures 0
                                                (min (length new-failures)
                                                     (- 3 (length existing-f)))))))
                        ;; Entity: merge per-invariant alist, cap 3 per invariant
                        (dolist (nf new-failures)
                          (let* ((inv-name (car nf))
                                 (new-examples (cdr nf))
                                 (ef (assoc inv-name (getf existing :failures)
                                            :test #'string=)))
                            (if ef
                                (let ((need (- 3 (length (cdr ef)))))
                                  (when (plusp need)
                                    (setf (cdr ef)
                                          (append (cdr ef)
                                                  (subseq new-examples 0
                                                          (min (length new-examples)
                                                               need))))))
                                (push nf (getf existing :failures)))))))))
              (setf (gethash ename merged) (copy-list r)))))
      ;; Print compact summary
      (let ((final-results nil))
        (maphash (lambda (k v) (declare (ignore k)) (push v final-results)) merged)
        (setf final-results (nreverse final-results))
        (format t "~%=== PBT Results ===~%")
        (when *config*
          (format t "(~A config x ~A trials)~%" config-trials trials))
        (dolist (r final-results)
          (let ((entity (getf r :entity))
                (inv-count (getf r :invariants))
                (rpassed (getf r :passed))
                (rtrials (getf r :trials))
                (rfailed (getf r :failed))
                (rfailures (getf r :failures)))
            (if (zerop rfailed)
                (format t "  ~A: ~A/~A passed (~A invariants)~%"
                        entity rpassed rtrials inv-count)
                (progn
                  (format t "  ~A: ~A/~A passed, ~A FAILED (~A invariants)~%"
                          entity rpassed rtrials rfailed inv-count)
                  (when (and verbose rfailures)
                    (let ((is-scenario (and (stringp entity)
                                           (>= (length entity) 9)
                                           (string= "scenario:" entity :end2 9))))
                      (if is-scenario
                          (let ((unique (remove-duplicates
                                        (loop for f in rfailures nconc (copy-list f))
                                        :test #'string=)))
                            (dolist (v unique)
                              (format t "    ~A~%" v)))
                          (dolist (entry rfailures)
                            (let ((inv-name (car entry))
                                  (examples (cdr entry)))
                              (dolist (ex examples)
                                (format t "    ~A: ~S~%" inv-name ex)))))))))))
        (format t "Total: ~A passed, ~A failed~%" grand-passed grand-failed)
        ;; Negative testing
        (when (and (plusp negative-trials) (not scenario))
          (let ((neg-stats (run-negative-trials negative-trials))
                (suspicious nil))
            (multiple-value-bind (neg-scenario-stats neg-gen-ok neg-gen-broken)
                (run-negative-scenario-trials negative-trials)
              ;; Merge scenario stats into entity stats
              (maphash (lambda (k v) (setf (gethash k neg-stats) v)) neg-scenario-stats)
              (format t "~%=== Negative Testing ===~%")
              (maphash (lambda (inv-name stats)
                         (let* ((tested (getf stats :tested))
                                (rejected (getf stats :rejected))
                                (pct (if (plusp tested)
                                         (round (* 100 (/ rejected tested)))
                                         0)))
                           (format t "  ~A: ~A% (~A/~A rejected)~%"
                                   inv-name pct rejected tested)
                           (when (zerop rejected)
                             (push inv-name suspicious))))
                       neg-stats)
              (when suspicious
                (format t "~%WARNING: never rejected:~%")
                (dolist (inv-name (nreverse suspicious))
                  (let* ((inv (describe-invariant inv-name))
                         (check (when inv (getf inv :check)))
                         (entity (when inv
                                   (let ((on (getf inv :on)))
                                     (when on (string-downcase (symbol-name on))))))
                         (classification (classify-zero-rejection check entity)))
                    (format t "  ~A~A~%" inv-name
                            (if classification
                                (format nil " (~A)" classification)
                                "")))))
              (when neg-gen-ok
                (format t "~%Negative generators validated:~%")
                (dolist (sname neg-gen-ok)
                  (format t "  ~A: all generated instances correctly rejected~%" sname)))
              (when neg-gen-broken
                (format t "~%WARNING: broken negative generators:~%")
                (dolist (entry neg-gen-broken)
                  (format t "  ~A: ~A/~A instances passed all invariants (should fail)~%"
                          (car entry) (cdr entry) negative-trials))))))
        final-results))))

;;; ---------------------------------------------------------------------------
;;; check-scenario — convenience for debugging scenario generators
;;; ---------------------------------------------------------------------------

(defun check-scenario (scenario-name instance)
  "Check a scenario instance for debugging generators.
Returns a list of result plists, one per invariant:
  ((:invariant \"name\" :pass t) (:invariant \"name\" :pass nil :value ...))"
  (dolist (name (list-entities))
    (ensure-entity-accessors name))
  (dolist (name (list-variants))
    (ensure-variant-accessors name))
  (when *config*
    (ensure-config-accessor))
  (let* ((results nil)
         (scenario (describe-scenario scenario-name))
         (entity-specs (getf scenario :entities)))
    ;; Scenario-level invariants
    (let* ((bindings (getf scenario :entities))
           (bind-pairs
             (mapcar (lambda (espec)
                       (let* ((binding-kw (getf espec :binding))
                              (sym (intern (symbol-name binding-kw)))
                              (val (getf instance binding-kw)))
                         (list sym val)))
                     bindings)))
      (dolist (entry (scenario-invariants-for scenario-name))
        (destructuring-bind (inv-name inv) entry
          (let ((check-form (getf inv :check)))
            (handler-case
                (let* ((params (mapcar #'first bind-pairs))
                       (fn (get-compiled-fn inv-name params check-form)))
                  (if (apply fn (mapcar #'second bind-pairs))
                      (push (list :invariant inv-name :pass t) results)
                      (push (list :invariant inv-name :pass nil) results)))
              (error (e)
                (push (list :invariant inv-name :pass nil
                            :error (princ-to-string e))
                      results)))))))
    ;; Per-entity invariants (including variant-specific) via check-invariants
    (let ((seen (make-hash-table :test #'equal)))
      (dolist (espec entity-specs)
        (let* ((binding (getf espec :binding))
               (entity-name (getf espec :entity))
               (val (getf instance binding))
               (instances (if (listp val)
                              (if (and val (keywordp (car val)))
                                  (list val)
                                  val)
                              (list val))))
          (dolist (inst instances)
            (when inst
              (let* ((result (check-invariants entity-name inst))
                     (violations (when (eq (car result) :fail) (cdr result))))
                (dolist (inv-name violations)
                  (unless (gethash inv-name seen)
                    (setf (gethash inv-name seen) t)
                    (let* ((base-name (let ((pos (search " (error:" inv-name)))
                                        (if pos (subseq inv-name 0 pos) inv-name)))
                           (inv (or (describe-invariant inv-name)
                                    (describe-invariant base-name)))
                           (keys (when inv
                                   (check-form-field-keys
                                    (getf inv :check) entity-name))))
                      (push (list :invariant inv-name :pass nil
                                  :binding binding
                                  :value (if keys
                                             (compact-instance inst keys)
                                             inst))
                            results))))))))
      ;; Add passing entries for entity invariants not yet in results
      (dolist (espec entity-specs)
        (let ((entity-name (getf espec :entity)))
          (dolist (entry (invariants-for entity-name))
            (let ((inv-name (first entry)))
              (unless (gethash inv-name seen)
                (setf (gethash inv-name seen) t)
                (push (list :invariant inv-name :pass t) results))))
          (dolist (vkey (entity-variants entity-name))
            (dolist (entry (variant-invariants-for vkey))
              (let ((inv-name (first entry)))
                (unless (gethash inv-name seen)
                  (setf (gethash inv-name seen) t)
                  (push (list :invariant inv-name :pass t) results))))))))
    (nreverse results))))

;;; ---------------------------------------------------------------------------
;;; Built-in utility functions for invariant check forms
;;; ---------------------------------------------------------------------------

(defun all-pairs-check (lst pred)
  "Check that PRED holds for every unordered pair in LST."
  (loop for (a . rest) on lst
        always (every (lambda (b) (funcall pred a b)) rest)))

(defun consecutive-pairs-check (lst pred)
  "Check that PRED holds for every consecutive pair in LST."
  (loop for (a b) on lst
        while b
        always (funcall pred a b)))

(declaim (ftype (function (real real real real) double-float) haversine-distance-nm))
(defun haversine-distance-nm (lat1 lon1 lat2 lon2)
  "Great-circle distance between two lat/lon points, in nautical miles."
  (declare (optimize (speed 3) (safety 1)))
  (let* ((to-rad (load-time-value (/ pi 180.0d0) t))
         (rlat1 (* (coerce lat1 'double-float) to-rad))
         (rlat2 (* (coerce lat2 'double-float) to-rad))
         (dlat (- rlat2 rlat1))
         (dlon (* (- (coerce lon2 'double-float) (coerce lon1 'double-float)) to-rad)))
    (declare (type double-float to-rad rlat1 rlat2 dlat dlon))
    (let* ((sdlat2 (sin (the double-float (/ dlat 2.0d0))))
           (sdlon2 (sin (the double-float (/ dlon 2.0d0))))
           (a (+ (* sdlat2 sdlat2)
                  (* (cos rlat1) (cos rlat2) sdlon2 sdlon2)))
           (c (* 2.0d0 (asin (sqrt (the (double-float 0.0d0 1.0d0) a))))))
      (declare (type double-float sdlat2 sdlon2 a c))
      (* 3440.065d0 c))))

;;; ---------------------------------------------------------------------------
;;; Temporal interval helpers
;;; ---------------------------------------------------------------------------

(defun intervals-overlap-p (start1 dur1 start2 dur2)
  "Return T if two intervals [start1, start1+dur1) and [start2, start2+dur2) overlap."
  (and (< start1 (+ start2 dur2))
       (< start2 (+ start1 dur1))))

(defun interval-contains-p (outer-start outer-dur inner-start inner-dur)
  "Return T if [inner-start, inner-start+inner-dur) is entirely within [outer-start, outer-start+outer-dur)."
  (and (<= outer-start inner-start)
       (<= (+ inner-start inner-dur) (+ outer-start outer-dur))))

(defun interval-before-p (start1 dur1 start2)
  "Return T if interval [start1, start1+dur1) ends at or before START2."
  (<= (+ start1 dur1) start2))

;;; ---------------------------------------------------------------------------
;;; Rule execution
;;; ---------------------------------------------------------------------------

(defun rule-when-matches-p (when-clause entity-name instance)
  "Check if a rule's :when clause matches ENTITY-NAME and INSTANCE's state.
Returns (values match-p state-field expected-state) or (values nil nil nil)."
  (when (and (consp when-clause) (>= (length when-clause) 3))
    (let* ((entity-sym (first when-clause))
           (field-kw (second when-clause))
           (value-spec (third when-clause))
           (ename (string-downcase (symbol-name entity-sym))))
      (when (and (string-equal ename (string-downcase (string entity-name)))
                 (keywordp field-kw))
        (let ((current (getf instance field-kw)))
          (cond
            ((keywordp value-spec)
             (values (eq current value-spec) field-kw value-spec))
            ((and (consp value-spec) (eq (car value-spec) 'member))
             (values (member current (cdr value-spec)) field-kw value-spec))
            (t (values nil field-kw value-spec))))))))

(defun extract-state-target (ensures entity-sym state-fields)
  "Extract (state-field . target-value) from :ensures forms.
Recognizes (eq accessor :keyword) patterns for state field assignments."
  (dolist (ens ensures)
    (when (and (consp ens) (eq (first ens) 'eq) (= (length ens) 3))
      (let ((lhs (second ens))
            (rhs (third ens)))
        (flet ((match-accessor (form)
                 (cond
                   ((and (consp form) (eq (first form) 'getf)
                         (= (length form) 3) (keywordp (third form))
                         (member (third form) state-fields))
                    (third form))
                   (t (let ((field (getf-field-p form entity-sym)))
                        (when (and field (member field state-fields))
                          field))))))
          (let ((lf (match-accessor lhs))
                (rf (match-accessor rhs)))
            (cond
              ((and lf (keywordp rhs)) (return (cons lf rhs)))
              ((and rf (keywordp lhs)) (return (cons rf lhs))))))))))

(defun extract-field-assignments (ensures entity-sym state-fields)
  "Extract non-state field assignments from :ensures forms.
Returns list of (field . value) for (= accessor constant) or (eq accessor constant)
patterns where field is NOT a state field."
  (let ((assignments nil))
    (dolist (ens ensures)
      (when (and (consp ens) (member (first ens) '(= eq)) (= (length ens) 3))
        (let ((lhs (second ens))
              (rhs (third ens)))
          (flet ((match-field (form)
                   (cond
                     ((and (consp form) (eq (first form) 'getf)
                           (= (length form) 3) (keywordp (third form))
                           (not (member (third form) state-fields)))
                      (third form))
                     (t (let ((field (getf-field-p form entity-sym)))
                          (when (and field (not (member field state-fields)))
                            field))))))
            (let ((lf (match-field lhs))
                  (rf (match-field rhs)))
              (cond
                ((and lf (atom rhs) (not (symbolp rhs)))
                 (push (cons lf rhs) assignments))
                ((and lf (keywordp rhs))
                 (push (cons lf rhs) assignments))
                ((and rf (atom lhs) (not (symbolp lhs)))
                 (push (cons rf lhs) assignments))
                ((and rf (keywordp lhs))
                 (push (cons rf lhs) assignments))))))))
    (nreverse assignments)))

(defun applicable-rules (entity-name instance)
  "Return list of rule name strings whose :when clause matches INSTANCE's current state."
  (let ((result nil))
    (dolist (rname (list-rules))
      (let* ((rule (describe-rule rname))
             (when-clause (getf rule :when)))
        (when (rule-when-matches-p when-clause entity-name instance)
          (push rname result))))
    (nreverse result)))

(defun apply-rule (entity-name instance rule-name)
  "Apply a rule to an entity instance, performing the state transition.
Returns (values new-instance applied-p rejection-reason).
  applied-p is T if the rule fired, NIL otherwise.
  rejection-reason is :when-mismatch, (:guard-failed form), or NIL."
  (ensure-entity-accessors entity-name)
  (let* ((rname (string-downcase (string rule-name)))
         (rule (describe-rule rname)))
    (unless rule
      (return-from apply-rule (values instance nil :unknown-rule)))
    (let* ((when-clause (getf rule :when))
           (requires (getf rule :requires))
           (sets-clause (getf rule :sets))
           (ensures (getf rule :ensures))
           (let-bindings (getf rule :let))
           (entity-sym (intern (string-upcase (string entity-name))))
           (state-fields (detect-state-fields entity-name)))
      ;; 1. Check :when
      (unless (rule-when-matches-p when-clause entity-name instance)
        (return-from apply-rule (values instance nil :when-mismatch)))
      ;; 2. Evaluate :let bindings (best-effort; cross-entity refs will error)
      (let ((let-vars nil)
            (let-vals nil))
        (dolist (binding let-bindings)
          (when (and (consp binding) (= (length binding) 2))
            (let ((var (first binding))
                  (expr (second binding)))
              (handler-case
                  (let ((fn (handler-bind ((warning #'muffle-warning))
                              (compile nil `(lambda (,entity-sym)
                                              (declare (ignorable ,entity-sym))
                                              ,expr)))))
                    (push var let-vars)
                    (push (funcall fn instance) let-vals))
                (error () nil)))))
        ;; 3. Check :requires
        (dolist (req requires)
          (handler-case
              (let* ((params (cons entity-sym (reverse let-vars)))
                     (fn (handler-bind ((warning #'muffle-warning))
                           (compile nil `(lambda ,params
                                           (declare (ignorable ,@params))
                                           ,req)))))
                (unless (apply fn instance (reverse let-vals))
                  (return-from apply-rule
                    (values instance nil (list :guard-failed req)))))
            (error ()
              (return-from apply-rule
                (values instance nil (list :guard-failed req))))))
        ;; 4. Apply state transition and field assignments from :ensures
        (let* ((target (extract-state-target ensures entity-sym state-fields))
               (field-assignments (extract-field-assignments ensures entity-sym state-fields))
               (new (copy-list instance)))
          (when target
            (setf (getf new (car target)) (cdr target)))
          (dolist (assignment field-assignments)
            (setf (getf new (car assignment)) (cdr assignment)))
          ;; 5. Check immutable fields before applying :sets
          (let ((immutable-keys nil))
            (dolist (field (getf (describe-entity entity-name) :fields))
              (when (getf (cddr field) :immutable)
                (push (field-keyword (first field)) immutable-keys)))
            (when immutable-keys
              (loop for (accessor-form _vf) on sets-clause by #'cddr
                    for fkw = (getf-field-p accessor-form entity-sym)
                    when (and fkw (member fkw immutable-keys)
                              (getf instance fkw))
                      do (return-from apply-rule
                           (values instance nil (list :immutable-violation fkw))))))
          ;; 6. Apply :sets — evaluate each (accessor-form value-form) pair
          (loop for (accessor-form value-form) on sets-clause by #'cddr
                do (handler-case
                       (let* ((params (cons entity-sym (reverse let-vars)))
                              (val-fn (handler-bind ((warning #'muffle-warning))
                                        (compile nil `(lambda ,params
                                                        (declare (ignorable ,@params))
                                                        ,value-form))))
                              (field-kw (getf-field-p accessor-form entity-sym)))
                         (when field-kw
                           (setf (getf new field-kw)
                                 (apply val-fn new (reverse let-vals)))))
                     (error () nil)))
          (values new t nil))))))

(defun random-walk (entity-name &key (steps 20) (trials 50) (verbose t))
  "Random walk PBT: generate instances and apply random applicable rules,
checking invariants at each step. Reports violations with the rule trace
that led to them.
Returns a result plist:
  :entity — entity name
  :trials — number of trials
  :steps — max steps per trial
  :passed — trials with no violations
  :failed — trials with at least one violation
  :failures — list of failure plists (:trace :violation :instance)"
  (ensure-entity-accessors entity-name)
  (dolist (vname (entity-variants entity-name))
    (ensure-variant-accessors vname))
  (when *config*
    (ensure-config-accessor))
  (let ((passed 0)
        (failed 0)
        (failures nil))
    (dotimes (_trial trials)
      (let ((instance (let ((state-fields (detect-state-fields entity-name)))
                        (if state-fields
                            (let ((overrides nil))
                              (dolist (sf state-fields)
                                (let ((default (field-default entity-name sf)))
                                  (when default
                                    (push default overrides)
                                    (push sf overrides))))
                              (generate-instance entity-name overrides))
                            (generate-instance entity-name))))
            (trace nil)
            (violation nil))
        ;; Check initial invariants
        (let* ((result (check-invariants entity-name instance))
               (violations (when (eq (car result) :fail) (cdr result))))
          (when violations
            (setf violation (list :step 0
                                  :after "initial"
                                  :violated violations
                                  :instance (copy-list instance)))))
        ;; Walk
        (unless violation
          (loop for step from 1 to steps
                for rules = (applicable-rules entity-name instance)
                while (and rules (not violation))
                do (let ((shuffled (let ((v (coerce (copy-list rules) 'vector)))
                                      (loop for i from (1- (length v)) downto 1
                                            for j = (random (1+ i))
                                            do (rotatef (aref v i) (aref v j)))
                                      (coerce v 'list)))
                         (applied nil))
                     ;; Try rules in random order until one applies
                     (dolist (rname shuffled)
                       (multiple-value-bind (new ok _reason)
                           (apply-rule entity-name instance rname)
                         (declare (ignore _reason))
                         (when ok
                           (push rname trace)
                           (setf instance new
                                 applied t)
                           ;; Check invariants after transition
                           (let* ((r2 (check-invariants entity-name instance))
                                  (violations (when (eq (car r2) :fail) (cdr r2))))
                             (when violations
                               (setf violation
                                     (list :step step
                                           :after rname
                                           :violated violations
                                           :instance (copy-list instance)
                                           :trace (reverse trace)))))
                           (return))))
                     (unless applied (return)))))
        (if violation
            (progn
              (incf failed)
              (when (< (length failures) 10)
                (push violation failures)))
            (incf passed))))
    ;; Print results
    (let* ((inv-count (length (invariants-for entity-name)))
           (result (list :entity entity-name
                         :trials trials
                         :steps steps
                         :invariants inv-count
                         :passed passed
                         :failed failed
                         :failures (nreverse failures))))
      (when verbose
        (format t "~%=== Random Walk Results ===~%")
        (format t "  ~A (~A invariants, ~A steps/trial)~%"
                entity-name inv-count steps)
        (if (zerop failed)
            (format t "    ~A/~A passed~%" passed trials)
            (progn
              (format t "    ~A/~A passed, ~A FAILED~%" passed trials failed)
              (dolist (f (getf result :failures))
                (let ((after (getf f :after))
                      (violated (getf f :violated))
                      (trace (getf f :trace))
                      (inst (getf f :instance)))
                  (format t "    after ~A~@[ (trace: ~{~A~^ → ~})~]:~%"
                          after trace)
                  (dolist (v violated)
                    (format t "      ~A: ~S~%" v inst)))))))
      result)))
