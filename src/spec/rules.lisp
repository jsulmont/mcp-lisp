(defpackage #:mcp-lisp/src/spec/rules
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/registry
                #:*entities*
                #:*rules*
                #:*invariants*
                #:*config*)
  (:import-from #:mcp-lisp/src/spec/introspection
                #:describe-entity
                #:describe-rule
                #:list-rules
                #:entity-fields
                #:entity-variants
                #:describe-scenario
                #:list-scenarios)
  (:import-from #:mcp-lisp/src/spec/transitions
                #:detect-state-fields
                #:field-default)
  (:import-from #:mcp-lisp/src/spec/pbt-util
                #:get-compiled-fn
                #:field-keyword
                #:getf-field-p)
  (:import-from #:mcp-lisp/src/spec/checking
                #:invariants-for
                #:check-invariants
                #:check-scenario-invariants)
  (:import-from #:mcp-lisp/src/spec/generation
                #:generate-instance
                #:generate-scenario
                #:ensure-entity-accessors
                #:ensure-variant-accessors
                #:ensure-config-accessor)
  (:export #:rule-when-matches-p
           #:extract-state-target
           #:extract-field-assignments
           #:applicable-rules
           #:apply-rule
           #:random-walk
           #:random-walk-scenario))

(in-package #:mcp-lisp/src/spec/rules)

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

(defun apply-rule (entity-name instance rule-name &key (now nil) (bindings nil))
  "Apply a rule to an entity instance, performing the state transition.
Returns (values new-instance applied-p rejection-reason).
  applied-p is T if the rule fired, NIL otherwise.
  rejection-reason is :when-mismatch, (:after-failed form), (:guard-failed form), or NIL.
  NOW, if provided, is the simulated clock value for :after evaluation.
  BINDINGS is an alist of (symbol . value) for cross-entity scenario context."
  (ensure-entity-accessors entity-name)
  (let* ((rname (string-downcase (string rule-name)))
         (rule (describe-rule rname)))
    (unless rule
      (return-from apply-rule (values instance nil :unknown-rule)))
    (let* ((when-clause (getf rule :when))
           (requires (getf rule :requires))
           (sets-clause (getf rule :sets))
           (ensures (getf rule :ensures))
           (after-clause (getf rule :after))
           (let-bindings (getf rule :let))
           (entity-sym (intern (string-upcase (string entity-name))))
           (now-sym (intern "NOW"))
           (state-fields (detect-state-fields entity-name))
           (ctx-syms (mapcar #'car bindings))
           (ctx-vals (mapcar #'cdr bindings)))
      ;; 1. Check :when
      (unless (rule-when-matches-p when-clause entity-name instance)
        (return-from apply-rule (values instance nil :when-mismatch)))
      ;; 1b. Check :after (temporal guard)
      (when after-clause
        (handler-case
            (let* ((all-params (list* entity-sym now-sym ctx-syms))
                   (fn (handler-bind ((warning #'muffle-warning))
                         (compile nil `(lambda ,all-params
                                         (declare (ignorable ,@all-params))
                                         ,after-clause)))))
              (unless (apply fn instance (or now 0) ctx-vals)
                (return-from apply-rule
                  (values instance nil (list :after-failed after-clause)))))
          (error ()
            (return-from apply-rule
              (values instance nil (list :after-failed after-clause))))))
      ;; 2. Evaluate :let bindings with scenario context
      (let ((let-vars nil)
            (let-vals nil))
        (dolist (binding let-bindings)
          (when (and (consp binding) (= (length binding) 2))
            (let ((var (first binding))
                  (expr (second binding)))
              (handler-case
                  (let* ((all-params (list* entity-sym now-sym (append ctx-syms (reverse let-vars))))
                         (fn (handler-bind ((warning #'muffle-warning))
                               (compile nil `(lambda ,all-params
                                               (declare (ignorable ,@all-params))
                                               ,expr)))))
                    (push var let-vars)
                    (push (apply fn instance (or now 0) (append ctx-vals (reverse let-vals))) let-vals))
                (error () nil)))))
        ;; 3. Check :requires
        (dolist (req requires)
          (handler-case
              (let* ((params (list* entity-sym now-sym (append (reverse let-vars) ctx-syms)))
                     (fn (handler-bind ((warning #'muffle-warning))
                           (compile nil `(lambda ,params
                                           (declare (ignorable ,@params))
                                           ,req)))))
                (unless (apply fn instance (or now 0) (append (reverse let-vals) ctx-vals))
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
                       (let* ((params (list* entity-sym now-sym (append (reverse let-vars) ctx-syms)))
                              (val-fn (handler-bind ((warning #'muffle-warning))
                                        (compile nil `(lambda ,params
                                                        (declare (ignorable ,@params))
                                                        ,value-form))))
                              (field-kw (getf-field-p accessor-form entity-sym)))
                         (when field-kw
                           (setf (getf new field-kw)
                                 (apply val-fn new (or now 0) (append (reverse let-vals) ctx-vals)))))
                     (error () nil)))
          (values new t nil))))))

(defun has-after-rules-p (entity-name)
  "Return T if any rule for ENTITY-NAME has an :after clause."
  (dolist (rname (list-rules))
    (let* ((rule (describe-rule rname))
           (when-clause (getf rule :when)))
      (when (and when-clause (symbolp (car when-clause))
                 (string-equal (symbol-name (car when-clause))
                               (string entity-name))
                 (getf rule :after))
        (return t)))))

(defun random-walk (entity-name &key (steps 20) (trials 50) (verbose t)
                                     (clock-start 0) (clock-step 10))
  "Random walk PBT: generate instances and apply random applicable rules,
checking invariants at each step. Reports violations with the rule trace
that led to them.

When rules have :after clauses, a simulated clock advances by CLOCK-STEP
each step. The clock value is passed as `now` to :after predicates.

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
        (failures nil)
        (use-clock (has-after-rules-p entity-name)))
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
            (now clock-start)
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
                do (when use-clock
                     (incf now (1+ (random clock-step))))
                   (let ((shuffled (let ((v (coerce (copy-list rules) 'vector)))
                                      (loop for i from (1- (length v)) downto 1
                                            for j = (random (1+ i))
                                            do (rotatef (aref v i) (aref v j)))
                                      (coerce v 'list)))
                         (applied nil))
                     ;; Try rules in random order until one applies
                     (dolist (rname shuffled)
                       (multiple-value-bind (new ok _reason)
                           (apply-rule entity-name instance rname
                                       :now (when use-clock now))
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

;;; ---------------------------------------------------------------------------
;;; Scenario-aware random walk
;;; ---------------------------------------------------------------------------

(defun build-entity-index (scenario-instance scenario)
  "Build a hash table mapping entity-name → list of instances from a scenario instance."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (espec (getf scenario :entities))
      (let* ((binding (getf espec :binding))
             (entity-name (getf espec :entity))
             (val (getf scenario-instance binding))
             (instances (cond
                          ((null val) nil)
                          ((and (listp val) (not (keywordp (car val)))) val)
                          (t (list val)))))
        (setf (gethash entity-name index) instances)))
    index))

(defun rebuild-scenario-instance (entity-index scenario)
  "Rebuild a scenario instance plist from the entity index."
  (let ((result nil))
    (dolist (espec (getf scenario :entities))
      (let* ((binding (getf espec :binding))
             (entity-name (getf espec :entity))
             (singular (getf espec :singular))
             (instances (gethash entity-name entity-index)))
        (setf (getf result binding)
              (if singular (first instances) instances))))
    result))

(defun random-walk-scenario (scenario-name &key (steps 20) (trials 50) (verbose t)
                                                (clock-start 0) (clock-step 10))
  "Scenario-aware random walk: operates on a multi-entity working set.
Each step picks a random entity instance, finds applicable rules, applies one.
:creates adds new instances; :deletes removes instances from the working set.
Checks both entity-level and scenario-level invariants after each step.

Returns a result plist like random-walk."
  (let* ((sname (string-downcase (string scenario-name)))
         (scenario (describe-scenario sname))
         (entity-specs (getf scenario :entities))
         (passed 0)
         (failed 0)
         (failures nil)
         (use-clock nil))
    ;; Set up accessors
    (dolist (espec entity-specs)
      (let ((ename (getf espec :entity)))
        (ensure-entity-accessors ename)
        (dolist (vname (entity-variants ename))
          (ensure-variant-accessors vname))
        (when (has-after-rules-p ename)
          (setf use-clock t))))
    (when *config* (ensure-config-accessor))
    ;; Run trials
    (dotimes (_trial trials)
      (let* ((scenario-instance (generate-scenario sname))
             (entity-index (build-entity-index scenario-instance scenario))
             (now clock-start)
             (trace nil)
             (violation nil)
             (ctx-bindings (mapcar (lambda (espec)
                                     (let ((sym (intern (symbol-name (getf espec :binding)))))
                                       (cons sym (gethash (getf espec :entity) entity-index))))
                                   entity-specs)))
        ;; Walk
        (loop for step from 1 to steps
              while (not violation)
              do (when use-clock (incf now (1+ (random clock-step))))
                 (let ((candidates nil))
                   ;; Collect (entity-name instance index) triples with applicable rules
                   (maphash (lambda (entity-name instances)
                              (loop for inst in instances
                                    for idx from 0
                                    for rules = (applicable-rules entity-name inst)
                                    when rules
                                      do (push (list entity-name inst idx rules) candidates)))
                            entity-index)
                   (unless candidates (return))
                   ;; Pick a random candidate
                   (let* ((pick (nth (random (length candidates)) candidates))
                          (entity-name (first pick))
                          (inst (second pick))
                          (inst-idx (third pick))
                          (rules (fourth pick))
                          (rname (nth (random (length rules)) rules))
                          (applied nil))
                     (multiple-value-bind (new ok _reason)
                         (apply-rule entity-name inst rname
                                     :now (when use-clock now)
                                     :bindings ctx-bindings)
                       (declare (ignore _reason))
                       (when ok
                         (setf applied t)
                         (push (format nil "~A[~A].~A" entity-name inst-idx rname) trace)
                         ;; Update instance in index and refresh bindings
                         (let ((instances (gethash entity-name entity-index)))
                           (setf (nth inst-idx instances) new))
                         (setf ctx-bindings
                               (mapcar (lambda (espec)
                                         (let ((sym (intern (symbol-name (getf espec :binding)))))
                                           (cons sym (gethash (getf espec :entity) entity-index))))
                                       entity-specs))
                         ;; Check entity invariants on the changed instance
                         (let* ((r (check-invariants entity-name new))
                                (vs (when (eq (car r) :fail) (cdr r))))
                           (when vs
                             (setf violation (list :step step :after rname
                                                   :violated vs :trace (reverse trace)))))))
                     ;; Check scenario invariants
                     (when (and applied (not violation))
                       (let* ((rebuilt (rebuild-scenario-instance entity-index scenario))
                              (sr (check-scenario-invariants sname rebuilt))
                              (sv (when (eq (car sr) :fail) (cdr sr))))
                         (when sv
                           (setf violation (list :step step :after rname
                                                  :violated sv :trace (reverse trace)))))))))
        (if violation
            (progn (incf failed)
                   (when (< (length failures) 10) (push violation failures)))
            (incf passed))))
    ;; Results
    (let ((result (list :entity (format nil "scenario:~A" sname)
                        :trials trials :steps steps
                        :passed passed :failed failed
                        :failures (nreverse failures))))
      (when verbose
        (format t "~%=== Scenario Random Walk Results ===~%")
        (format t "  ~A (~A steps/trial)~%" sname steps)
        (if (zerop failed)
            (format t "    ~A/~A passed~%" passed trials)
            (progn
              (format t "    ~A/~A passed, ~A FAILED~%" passed trials failed)
              (dolist (f (getf result :failures))
                (format t "    step ~A after ~A: ~{~A~^, ~}~%"
                        (getf f :step) (getf f :after) (getf f :violated))
                (when (getf f :trace)
                  (format t "      trace: ~{~A~^ → ~}~%" (getf f :trace)))))))
      result)))
