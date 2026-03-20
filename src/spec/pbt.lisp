;;;; src/spec/pbt.lisp
;;;;
;;;; Property-based testing for behavioral specs. Generates random entity
;;;; instances from field type specs and checks invariants against them.

(defpackage #:mcp-lisp/src/spec/pbt
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/spec
                #:*entities*
                #:*invariants*
                #:describe-entity
                #:list-entities
                #:describe-invariant
                #:list-invariants
                #:entity-fields
                #:entity-relations)
  (:export #:generate-value
           #:generate-instance
           #:ensure-entity-accessors
           #:check-invariants
           #:run-pbt))

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

;;; ---------------------------------------------------------------------------
;;; Instance generation
;;; ---------------------------------------------------------------------------

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

(defun generate-instance (entity-name &optional overrides)
  "Generate a random instance of ENTITY-NAME as a plist.
OVERRIDES is an alist of (field-keyword . value) to fix specific fields.
Respects :min/:max constraints and computes :derived-from fields."
  (let* ((entity (describe-entity entity-name))
         (fields (getf entity :fields))
         (instance nil)
         (deferred nil))
    ;; First pass: generate non-derived fields
    (dolist (field (reverse fields))
      (let* ((fname (first field))
             (ftype (second field))
             (key (field-keyword fname))
             (constraints (field-constraints field))
             (override (assoc key overrides)))
        (cond
          (override
           (push (cdr override) instance)
           (push key instance))
          ((getf constraints :derived-from)
           ;; Placeholder — will compute after other fields are set
           (push nil instance)
           (push key instance)
           (push (list key (getf constraints :derived-from)) deferred))
          (t
           (push (generate-value ftype
                                 :min (getf constraints :min)
                                 :max (getf constraints :max))
                 instance)
           (push key instance)))))
    ;; Second pass: compute derived fields using the instance as context
    (when deferred
      (ensure-entity-accessors entity-name)
      (dolist (entry deferred)
        (destructuring-bind (key form) entry
          (let* ((inst-sym (find-symbol-named "INSTANCE" form))
                 (fn (compile nil `(lambda (,inst-sym) ,form))))
            (setf (getf instance key) (funcall fn instance))))))
    instance))

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

(defun check-invariants (entity-name instance)
  "Check all invariants for ENTITY-NAME against INSTANCE.
Returns a list of violated invariant name strings. Empty list = all pass."
  (let ((violations nil))
    (dolist (entry (invariants-for entity-name))
      (destructuring-bind (inv-name inv) entry
        (let ((on-sym (getf inv :on))
              (check-form (getf inv :check)))
          (handler-case
              (let ((fn (compile nil `(lambda (,on-sym) ,check-form))))
                (unless (funcall fn instance)
                  (push inv-name violations)))
            (error (e)
              (push (format nil "~A (error: ~A)" inv-name e) violations))))))
    (nreverse violations)))

;;; ---------------------------------------------------------------------------
;;; PBT runner
;;; ---------------------------------------------------------------------------

(defun run-pbt (&key (trials 100))
  "Run property-based testing on all entities with invariants.
Generates TRIALS random instances per entity and checks all applicable
invariants. Returns a list of result plists and prints a summary."
  ;; Set up accessors for all entities
  (dolist (name (list-entities))
    (ensure-entity-accessors name))
  ;; Run trials
  (let ((results nil)
        (total-passed 0)
        (total-failed 0))
    (dolist (entity-name (list-entities))
      (let ((relevant (invariants-for entity-name)))
        (when relevant
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
                        :invariants (mapcar #'first relevant)
                        :trials trials
                        :passed passed
                        :failed failed
                        :failures (nreverse failures))
                  results)))))
    ;; Print summary
    (format t "~%=== PBT Results ===~%")
    (dolist (r (reverse results))
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
            total-passed total-failed)
    (nreverse results)))
