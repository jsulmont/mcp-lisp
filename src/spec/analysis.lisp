;;;; src/spec/analysis.lisp
;;;;
;;;; Analysis tools for behavioral specs: coverage analysis, reverse indexing,
;;;; generation feasibility, state machine simulation, and scenario diagnostics.

(defpackage #:mcp-lisp/src/spec/analysis
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/spec
                #:*entities*
                #:*rules*
                #:*invariants*
                #:*generators*
                #:*variants*
                #:*scenarios*
                #:*scenario-generators*
                #:*scenario-negative-generators*
                #:describe-entity
                #:list-entities
                #:entity-fields
                #:entity-relations
                #:describe-rule
                #:list-rules
                #:describe-invariant
                #:list-invariants
                #:describe-scenario
                #:list-scenarios
                #:entity-variants)
  (:import-from #:mcp-lisp/src/spec/pbt
                #:invariants-for
                #:scenario-invariants-for
                #:extract-generation-constraints
                #:getf-field-p
                #:ensure-entity-accessors)
  (:import-from #:mcp-lisp/src/spec/transitions
                #:extract-transitions
                #:detect-state-fields)
  (:export #:invariant-coverage
           #:field-index
           #:generation-feasibility
           #:simulate-trace
           #:scenario-feasibility))

(in-package #:mcp-lisp/src/spec/analysis)

;;; ---------------------------------------------------------------------------
;;; Form walking — collect field keyword references from check/requires/ensures
;;; ---------------------------------------------------------------------------

(defun collect-field-refs (form entity-name)
  "Walk FORM collecting field keywords accessed via (getf VAR :field) or
(entity-field var) patterns for ENTITY-NAME. Returns a list of field keywords."
  (let ((refs nil)
        (ename (string-downcase (string entity-name))))
    (labels ((walk (f)
               (when (consp f)
                 (cond
                   ;; (getf entity-var :keyword) — check if var matches entity
                   ((and (eq (first f) 'getf) (= (length f) 3)
                         (symbolp (second f)) (keywordp (third f))
                         (string-equal (symbol-name (second f)) ename))
                    (pushnew (third f) refs))
                   ;; (entity-field entity-var) accessor pattern
                   ((and (= (length f) 2) (symbolp (first f)) (symbolp (second f))
                         (string-equal (symbol-name (second f)) ename))
                    (let* ((accessor (string-downcase (symbol-name (first f))))
                           (prefix (concatenate 'string ename "-")))
                      (when (and (> (length accessor) (length prefix))
                                 (string= prefix accessor :end2 (length prefix)))
                        (pushnew (intern (string-upcase
                                          (subseq accessor (length prefix)))
                                         :keyword)
                                 refs))))
                   ;; Quote — skip
                   ((eq (first f) 'quote) nil)
                   ;; Recurse
                   (t (dolist (sub f) (walk sub)))))))
      (walk form))
    refs))

(defun collect-all-field-refs (form)
  "Walk FORM collecting ALL field keywords accessed via (getf VAR :keyword)
regardless of entity. Returns a list of field keywords."
  (let ((refs nil))
    (labels ((walk (f)
               (when (consp f)
                 (cond
                   ((and (eq (first f) 'getf) (= (length f) 3)
                         (symbolp (second f)) (keywordp (third f)))
                    (pushnew (third f) refs)
                    (walk (second f)))
                   ((eq (first f) 'quote) nil)
                   (t (dolist (sub f) (walk sub)))))))
      (walk form))
    refs))

;;; ---------------------------------------------------------------------------
;;; 1. invariant-coverage
;;; ---------------------------------------------------------------------------

(defun invariant-coverage (entity-name)
  "Return an alist of (field-keyword . invariant-names) for ENTITY-NAME.
Fields with no invariant coverage have NIL as their value.
Helps identify unconstrained fields that may need invariants."
  (let* ((entity (describe-entity entity-name))
         (fields (getf entity :fields))
         (field-keys (mapcar (lambda (f)
                               (intern (string-upcase (symbol-name (first f)))
                                       :keyword))
                             fields))
         (coverage (make-hash-table :test #'eq))
         (invs (invariants-for entity-name)))
    ;; Initialize all fields
    (dolist (k field-keys)
      (setf (gethash k coverage) nil))
    ;; Walk each invariant's :check form
    (dolist (entry invs)
      (destructuring-bind (inv-name inv) entry
        (let ((refs (collect-field-refs (getf inv :check) entity-name)))
          (dolist (ref refs)
            (when (gethash ref coverage nil)
              ;; Key exists (might be nil)
              t)
            (push inv-name (gethash ref coverage))))))
    ;; Convert to sorted alist
    (let ((result nil))
      (dolist (k field-keys)
        (push (cons k (nreverse (gethash k coverage))) result))
      (nreverse result))))

;;; ---------------------------------------------------------------------------
;;; 2. field-index
;;; ---------------------------------------------------------------------------

(defun field-index (entity-name field-keyword)
  "Return all invariants, rules, and relations that reference FIELD-KEYWORD
on ENTITY-NAME. Returns a plist:
  :invariants — list of invariant names whose :check references the field
  :rules — list of (rule-name . :when/:requires/:ensures) pairs
  :relations — list of relation specs referencing the field"
  (let* ((ename (string-downcase (string entity-name)))
         (inv-refs nil)
         (rule-refs nil))
    ;; Check invariants
    (dolist (entry (invariants-for entity-name))
      (destructuring-bind (inv-name inv) entry
        (let ((refs (collect-field-refs (getf inv :check) entity-name)))
          (when (member field-keyword refs)
            (push inv-name inv-refs)))))
    ;; Check rules
    (dolist (rule-name (list-rules))
      (let* ((rule (describe-rule rule-name))
             (when-clause (getf rule :when)))
        ;; Only rules for this entity
        (when (and when-clause (symbolp (car when-clause))
                   (string-equal (symbol-name (car when-clause)) ename))
          ;; Check :when field
          (when (and (>= (length when-clause) 2)
                     (eq (second when-clause) field-keyword))
            (push (cons rule-name :when) rule-refs))
          ;; Check :requires
          (dolist (req (getf rule :requires))
            (when (member field-keyword (collect-field-refs req entity-name))
              (push (cons rule-name :requires) rule-refs)
              (return)))
          ;; Check :ensures
          (dolist (ens (getf rule :ensures))
            (when (member field-keyword (collect-field-refs ens entity-name))
              (push (cons rule-name :ensures) rule-refs)
              (return))))))
    (list :invariants (nreverse inv-refs)
          :rules (nreverse rule-refs))))

;;; ---------------------------------------------------------------------------
;;; 3. generation-feasibility
;;; ---------------------------------------------------------------------------

(defun generation-feasibility (entity-name)
  "Analyze whether the default constraint-aware generator can produce valid
instances of ENTITY-NAME. Returns a plist:
  :entity — entity name
  :total-fields — count of all fields
  :constrained-fields — fields with extractable constraints
  :unconstrained-fields — fields with no extractable constraints
  :conditional-constraints — fields whose constraints depend on enum state
  :has-custom-generator — whether a defgenerator is registered
  :verdict — :ok, :marginal, or :needs-custom-generator"
  (let* ((entity (describe-entity entity-name))
         (fields (getf entity :fields))
         (constraints (extract-generation-constraints entity-name))
         (has-custom (gethash (string-downcase (string entity-name))
                              *generators*))
         (constrained nil)
         (unconstrained nil)
         (conditional nil))
    (dolist (field fields)
      (let* ((fname (first field))
             (ftype (second field))
             (key (intern (string-upcase (symbol-name fname)) :keyword))
             (cs (gethash key constraints)))
        (cond
          ;; Member/enum fields are always constrained by type
          ((and (consp ftype) (eq (car ftype) 'member))
           (push (list key :type :member) constrained))
          ;; Has extracted constraints
          (cs
           (let ((has-conditional (some (lambda (c) (getf c :when)) cs))
                 (kinds nil))
             (dolist (c cs)
               (cond ((getf c :eq)      (pushnew :constant-eq kinds))
                     ((getf c :eq-expr) (pushnew :expr-eq kinds))
                     ((getf c :eq-field) (pushnew :field-eq kinds))
                     ((or (getf c :min) (getf c :max))
                      (pushnew :constant-bounds kinds))
                     ((or (getf c :min-field) (getf c :max-field))
                      (pushnew :field-bounds kinds))
                     ((or (getf c :min-expr) (getf c :max-expr))
                      (pushnew :expr-bounds kinds))
                     ((or (getf c :min-config) (getf c :max-config)
                          (getf c :eq-config))
                      (pushnew :config-bounds kinds))))
             (push (list* key :kinds kinds) constrained)
             (when has-conditional
               (push key conditional))))
          ;; No constraints at all
          (t
           (push key unconstrained)))))
    (let* ((n-fields (length fields))
           (n-unconstrained (length unconstrained))
           (verdict (cond
                      (has-custom :ok)
                      ((and (zerop n-unconstrained) (null conditional)) :ok)
                      ((plusp (length conditional)) :needs-custom-generator)
                      ((> n-unconstrained (/ n-fields 2)) :marginal)
                      (t :ok))))
      (list :entity entity-name
            :total-fields n-fields
            :constrained-fields (nreverse constrained)
            :unconstrained-fields (nreverse unconstrained)
            :conditional-constraints (nreverse conditional)
            :has-custom-generator (if has-custom t nil)
            :verdict verdict))))

;;; ---------------------------------------------------------------------------
;;; 4. simulate-trace
;;; ---------------------------------------------------------------------------

(defun evaluate-guard (guard-form entity-name instance)
  "Evaluate a single guard form against INSTANCE. Returns (values pass-p value-description)."
  (let* ((entity-sym (intern (string-upcase (string entity-name))))
         (fn (handler-bind ((warning #'muffle-warning))
               (compile nil `(lambda (,entity-sym)
                               (declare (ignorable ,entity-sym))
                               ,guard-form)))))
    (handler-case
        (let ((result (funcall fn instance)))
          (values (if result t nil)
                  (format nil "~S → ~A" guard-form (if result "PASS" "FAIL"))))
      (error (e)
        (values nil (format nil "~S → ERROR: ~A" guard-form e))))))

(defun match-state-accessor (form entity-sym state-fields)
  "Extract state field keyword from FORM if it accesses a state field.
Handles both (getf e :field) and (entity-field e) patterns."
  (cond
    ((and (consp form) (eq (first form) 'getf)
          (= (length form) 3) (keywordp (third form))
          (member (third form) state-fields))
     (third form))
    (t (let ((field (getf-field-p form entity-sym)))
         (when (and field (member field state-fields))
           field)))))

(defun extract-target-from-ensures (ensures entity-sym state-fields)
  "Extract (state-field . target-value) from :ensures forms."
  (dolist (ens ensures)
    (when (and (consp ens) (eq (first ens) 'eq) (= (length ens) 3))
      (let* ((lhs (second ens))
             (rhs (third ens))
             (lf (match-state-accessor lhs entity-sym state-fields))
             (rf (match-state-accessor rhs entity-sym state-fields)))
        (cond
          ((and lf (keywordp rhs)) (return (cons lf rhs)))
          ((and rf (keywordp lhs)) (return (cons rf lhs))))))))

(defun simulate-trace (entity-name instance rule-names)
  "Step through RULE-NAMES on INSTANCE, reporting guard pass/fail at each step.
Returns a list of step results, each a plist:
  :rule — rule name
  :from-state — state before
  :to-state — state after (if all guards pass)
  :guards — list of (:form FORM :pass BOOL :detail STRING)
  :applied — whether the rule was applied (all guards passed)
  :instance-after — instance after applying the rule (state updated)"
  (ensure-entity-accessors entity-name)
  (let* ((state-fields (detect-state-fields entity-name))
         (entity-sym (intern (string-upcase (string entity-name))))
         (current (copy-list instance))
         (results nil))
    (dolist (rule-name rule-names)
      (let* ((rname (string-downcase (string rule-name)))
             (rule (describe-rule rname))
             (when-clause (getf rule :when))
             (requires (getf rule :requires))
             (ensures (getf rule :ensures))
             (state-field (when (and when-clause (>= (length when-clause) 2))
                            (second when-clause)))
             (expected-state (when (and when-clause (>= (length when-clause) 3))
                               (third when-clause)))
             (current-state (when state-field (getf current state-field)))
             (when-ok (or (null expected-state)
                          (if (and (consp expected-state)
                                   (eq (car expected-state) 'member))
                              (member current-state (cdr expected-state))
                              (eq current-state expected-state))))
             (guard-results nil)
             (all-pass when-ok))
        ;; Report :when
        (push (list :form (list :when state-field expected-state)
                    :pass when-ok
                    :detail (format nil ":when ~A = ~A (have ~A) → ~A"
                                    state-field expected-state current-state
                                    (if when-ok "MATCH" "MISMATCH")))
              guard-results)
        ;; Check :requires
        (when when-ok
          (dolist (req requires)
            (multiple-value-bind (pass detail)
                (evaluate-guard req entity-name current)
              (push (list :form req :pass pass :detail detail) guard-results)
              (unless pass (setf all-pass nil)))))
        ;; Apply: extract target state from :ensures
        (let ((new-state (when (and all-pass ensures)
                           (extract-target-from-ensures ensures entity-sym state-fields))))
          (when new-state
            (setf (getf current (car new-state)) (cdr new-state)))
          (push (list :rule rname
                      :from-state current-state
                      :to-state (if new-state (cdr new-state) current-state)
                      :guards (nreverse guard-results)
                      :applied all-pass
                      :instance-after (copy-list current))
                results))))
    (nreverse results)))

;;; ---------------------------------------------------------------------------
;;; 5. scenario-feasibility
;;; ---------------------------------------------------------------------------

(defun form-uses-aggregate-p (form)
  "Check if FORM uses aggregate operations (reduce, mapcar, every, some, length,
loop) over list bindings, suggesting correlated generation is needed."
  (when (consp form)
    (cond
      ((eq (first form) 'quote) nil)
      ((member (first form) '(reduce mapcar every some count remove-if
                               remove-if-not loop length))
       t)
      (t (some #'form-uses-aggregate-p (cdr form))))))

(defun scenario-feasibility (scenario-name)
  "Analyze whether a scenario's invariants require correlated generation.
Returns a plist:
  :scenario — scenario name
  :invariants — list of invariant analysis plists
  :has-custom-generator — whether a defscenario-generator is registered
  :has-negative-generator — whether a defscenario-negative-generator is registered
  :needs-custom-generator — whether any invariant uses aggregates
  :verdict — :ok or :needs-custom-generator"
  (let* ((sname (string-downcase (string scenario-name)))
         (invs (scenario-invariants-for sname))
         (has-custom (gethash sname *scenario-generators*))
         (has-negative (gethash sname *scenario-negative-generators*))
         (inv-analysis nil)
         (needs-custom nil))
    (dolist (entry invs)
      (destructuring-bind (inv-name inv) entry
        (let* ((check (getf inv :check))
               (uses-aggregates (form-uses-aggregate-p check))
               (field-refs (collect-all-field-refs check)))
          (when uses-aggregates
            (setf needs-custom t))
          (push (list :name inv-name
                      :uses-aggregates uses-aggregates
                      :field-refs field-refs)
                inv-analysis))))
    (list :scenario sname
          :invariants (nreverse inv-analysis)
          :has-custom-generator (if has-custom t nil)
          :has-negative-generator (if has-negative t nil)
          :needs-custom-generator needs-custom
          :verdict (cond
                     ((and needs-custom (not has-custom)) :needs-custom-generator)
                     (t :ok)))))
