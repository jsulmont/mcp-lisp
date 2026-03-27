(defpackage #:mcp-lisp/src/spec/pbt-util
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/registry
                #:*entities*
                #:*compiled-fn-cache*)
  (:import-from #:mcp-lisp/src/spec/introspection
                #:describe-entity
                #:entity-fields
                #:entity-relations)
  (:export #:get-compiled-fn
           #:generate-value
           #:+alphanumeric+
           #:find-symbol-named
           #:field-keyword
           #:*override-sentinel*
           #:override-val
           #:override-present-p
           #:field-constraints
           #:member-type-p
           #:getf-field-p
           #:pure-field-expr-p
           #:eval-field-expr
           #:config-ref-p))

(in-package #:mcp-lisp/src/spec/pbt-util)

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
    ((and (consp type-spec)
          (symbolp (car type-spec))
          (string-equal (symbol-name (car type-spec)) "LIST-OF"))
     (let* ((inner-type (second type-spec))
            (lo (max 0 (or (and min (ceiling min)) 1)))
            (hi (or (and max (floor max)) 5))
            (n (if (>= lo hi) lo (+ lo (random (1+ (- hi lo)))))))
       (loop repeat n collect (generate-value inner-type))))
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
