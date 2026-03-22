;;;; src/spec/transitions.lisp
;;;;
;;;; Extract implicit state machines from existing rules. The rules already
;;;; encode the transition graph — this module reads it.

(defpackage #:mcp-lisp/src/spec/transitions
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/spec
                #:*entities*
                #:*rules*
                #:describe-entity
                #:list-entities
                #:entity-fields
                #:list-rules
                #:describe-rule
                #:decompose-accessor)
  (:export #:detect-state-fields
           #:extract-transitions
           #:unreachable-states
           #:terminal-states
           #:dead-end-states
           #:analyze-state-machine
           #:validate-transitions))

(in-package #:mcp-lisp/src/spec/transitions)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun member-type-values (type-spec)
  "If TYPE-SPEC is (MEMBER :a :b ...), return the list of values. Else NIL."
  (when (and (consp type-spec) (eq (car type-spec) 'member))
    (cdr type-spec)))

(defun entity-member-fields (entity-name)
  "Return alist of (field-keyword . member-values) for all member-typed fields."
  (let ((fields (entity-fields entity-name)))
    (loop for (fname ftype . _rest) in fields
          for values = (member-type-values ftype)
          when values
            collect (cons (intern (symbol-name fname) :keyword) values))))

(defun field-default (entity-name field-keyword)
  "Return the :default value for FIELD-KEYWORD in ENTITY-NAME, or NIL."
  (let ((fields (entity-fields entity-name)))
    (loop for (fname _ftype . kwargs) in fields
          when (eq (intern (symbol-name fname) :keyword) field-keyword)
            return (getf kwargs :default))))

;;; ---------------------------------------------------------------------------
;;; Parsing :when forms for source states
;;; ---------------------------------------------------------------------------

(defun parse-when-source (when-form entity-name)
  "Extract (entity-key field-keyword source-states) from a :when form.
WHEN-FORM is (entity :field :value) or (entity :field (member ...)).
Returns (values entity-key field-keyword source-state-list) or NIL."
  (when (and (consp when-form) (>= (length when-form) 3))
    (let* ((entity-sym (first when-form))
           (field-kw (second when-form))
           (value-spec (third when-form))
           (ename (string-downcase (symbol-name entity-sym))))
      (when (and (string-equal ename (string-downcase (string entity-name)))
                 (keywordp field-kw))
        (let ((states (cond
                        ((keywordp value-spec) (list value-spec))
                        ((and (consp value-spec) (eq (car value-spec) 'member))
                         (cdr value-spec))
                        (t nil))))
          (when states
            (values ename field-kw states)))))))

;;; ---------------------------------------------------------------------------
;;; Parsing :ensures forms for target states
;;; ---------------------------------------------------------------------------

(defun extract-target-state (form entity-name field-keyword)
  "Extract target state keyword from an :ensures form.
Recognizes:
  (eq (entity-field entity) :target)
  (eq (getf entity :field) :target)
Returns the target keyword or NIL."
  (when (and (consp form) (eq (first form) 'eq) (= (length form) 3))
    (let ((lhs (second form))
          (rhs (third form)))
      ;; Try both orientations: (eq accessor :kw) and (eq :kw accessor)
      (flet ((try-pair (accessor-form value-form)
               (when (keywordp value-form)
                 (cond
                   ;; (getf entity :field) pattern
                   ((and (consp accessor-form)
                         (eq (first accessor-form) 'getf)
                         (= (length accessor-form) 3)
                         (eq (third accessor-form) field-keyword)
                         (let ((var (second accessor-form)))
                           (string-equal (symbol-name var)
                                         (string entity-name))))
                    value-form)
                   ;; (entity-field entity) accessor pattern
                   ((and (consp accessor-form)
                         (= (length accessor-form) 2)
                         (symbolp (first accessor-form)))
                    (multiple-value-bind (ekey fname)
                        (decompose-accessor (first accessor-form))
                      (when (and ekey
                                 (string-equal ekey (string-downcase (string entity-name)))
                                 (string-equal fname (string-downcase
                                                      (symbol-name field-keyword))))
                        value-form)))))))
        (or (try-pair lhs rhs)
            (try-pair rhs lhs))))))

(defun scan-ensures-for-target (ensures-forms entity-name field-keyword)
  "Scan a list of :ensures forms for a target state assignment.
Returns the target state keyword or NIL."
  (dolist (form ensures-forms)
    (let ((target (extract-target-state form entity-name field-keyword)))
      (when target (return target)))))

;;; ---------------------------------------------------------------------------
;;; Extracting guards from :requires
;;; ---------------------------------------------------------------------------

(defun extract-guards (requires-forms)
  "Return the :requires forms as-is — they are the guard conditions."
  requires-forms)

;;; ---------------------------------------------------------------------------
;;; detect-state-fields
;;; ---------------------------------------------------------------------------

(defun detect-state-fields (entity-name)
  "Auto-detect which member-typed fields of ENTITY-NAME are state fields.
A state field is a member field that appears as a source in at least one
rule's :when AND as a target in at least one rule's :ensures.
Returns a list of field keywords."
  (let ((member-fields (entity-member-fields entity-name))
        (result nil))
    (dolist (entry member-fields)
      (let ((field-kw (car entry))
            (seen-source nil)
            (seen-target nil))
        (dolist (rule-name (list-rules))
          (let ((rule (describe-rule rule-name)))
            (multiple-value-bind (_ekey fkw _states)
                (parse-when-source (getf rule :when) entity-name)
              (declare (ignore _ekey _states))
              (when (eq fkw field-kw)
                (setf seen-source t)))
            (when (scan-ensures-for-target (getf rule :ensures) entity-name field-kw)
              (setf seen-target t))))
        (when (and seen-source seen-target)
          (push field-kw result))))
    (nreverse result)))

;;; ---------------------------------------------------------------------------
;;; extract-transitions
;;; ---------------------------------------------------------------------------

(defun extract-transitions (entity-name &optional field)
  "Extract the transition graph for ENTITY-NAME's state FIELD.
If FIELD is omitted, uses the first detected state field.
Returns a list of plists:
  (:from :source :to :target :via rule-name :guards (guard-forms...))
Returns NIL if no state field is found."
  (let ((field-kw (or field
                      (first (detect-state-fields entity-name)))))
    (unless field-kw (return-from extract-transitions nil))
    (let ((transitions nil))
      (dolist (rule-name (list-rules))
        (let ((rule (describe-rule rule-name)))
          (multiple-value-bind (_ekey fkw source-states)
              (parse-when-source (getf rule :when) entity-name)
            (declare (ignore _ekey))
            (when (eq fkw field-kw)
              (let ((target (scan-ensures-for-target
                             (getf rule :ensures) entity-name field-kw))
                    (guards (extract-guards (getf rule :requires))))
                (when target
                  (dolist (src source-states)
                    (push (list :from src
                                :to target
                                :via (intern (string-upcase rule-name))
                                :guards guards)
                          transitions))))))))
      (nreverse transitions))))

;;; ---------------------------------------------------------------------------
;;; Static analysis
;;; ---------------------------------------------------------------------------

(defun all-member-values (entity-name field-keyword)
  "Return the full set of member values for FIELD-KEYWORD in ENTITY-NAME."
  (let ((entry (assoc field-keyword (entity-member-fields entity-name))))
    (when entry (cdr entry))))

(defun transition-sources (transitions)
  "Return deduplicated list of :from states."
  (remove-duplicates (mapcar (lambda (tr) (getf tr :from)) transitions)))

(defun transition-targets (transitions)
  "Return deduplicated list of :to states."
  (remove-duplicates (mapcar (lambda (tr) (getf tr :to)) transitions)))

(defun terminal-states (entity-name &optional field)
  "Return states with no outgoing edges.
These are absorbing/final states (e.g. :filled, :cancelled)."
  (let* ((field-kw (or field (first (detect-state-fields entity-name))))
         (transitions (extract-transitions entity-name field-kw))
         (all-values (all-member-values entity-name field-kw))
         (sources (transition-sources transitions)))
    (set-difference all-values sources)))

(defun unreachable-states (entity-name &optional field)
  "Return states with no incoming edges, excluding the initial (default) state.
An unreachable state other than the initial state is likely a bug."
  (let* ((field-kw (or field (first (detect-state-fields entity-name))))
         (transitions (extract-transitions entity-name field-kw))
         (all-values (all-member-values entity-name field-kw))
         (targets (transition-targets transitions))
         (default (field-default entity-name field-kw))
         (no-incoming (set-difference all-values targets)))
    ;; The default/initial state is expected to have no incoming edges
    (if default
        (remove default no-incoming)
        no-incoming)))

(defun dead-end-states (entity-name &optional field)
  "Return non-terminal states from which no terminal state is reachable.
These represent states stuck in a cycle with no exit."
  (let* ((field-kw (or field (first (detect-state-fields entity-name))))
         (transitions (extract-transitions entity-name field-kw))
         (terminals (terminal-states entity-name field-kw))
         (all-values (all-member-values entity-name field-kw))
         ;; Build adjacency: state → list of reachable next-states
         (adj (make-hash-table :test #'eq)))
    (dolist (tr transitions)
      (pushnew (getf tr :to) (gethash (getf tr :from) adj)))
    ;; BFS/DFS from each non-terminal state to see if a terminal is reachable
    (let ((can-reach-terminal (make-hash-table :test #'eq)))
      ;; Terminals trivially reach a terminal
      (dolist (t-state terminals)
        (setf (gethash t-state can-reach-terminal) t))
      ;; Iterate until stable (simple fixpoint)
      (loop for changed = nil
            do (dolist (state all-values)
                 (unless (gethash state can-reach-terminal)
                   (dolist (next (gethash state adj))
                     (when (gethash next can-reach-terminal)
                       (setf (gethash state can-reach-terminal) t
                             changed t)))))
            while changed)
      ;; Dead-ends: non-terminal states that cannot reach a terminal
      (loop for state in all-values
            unless (or (member state terminals)
                       (gethash state can-reach-terminal))
              collect state))))

(defun analyze-state-machine (entity-name &optional field)
  "Full analysis of the state machine for ENTITY-NAME's FIELD.
Returns a plist with:
  :field        — the state field keyword
  :states       — all possible state values
  :initial      — the default/initial state (or NIL)
  :terminal     — states with no outgoing edges
  :unreachable  — states with no incoming edges (minus initial)
  :dead-ends    — non-terminal states that can't reach a terminal
  :transitions  — the full transition list"
  (let* ((field-kw (or field (first (detect-state-fields entity-name))))
         (transitions (extract-transitions entity-name field-kw)))
    (when field-kw
      (list :field field-kw
            :states (all-member-values entity-name field-kw)
            :initial (field-default entity-name field-kw)
            :terminal (terminal-states entity-name field-kw)
            :unreachable (unreachable-states entity-name field-kw)
            :dead-ends (dead-end-states entity-name field-kw)
            :transitions transitions))))

;;; ---------------------------------------------------------------------------
;;; Validation
;;; ---------------------------------------------------------------------------

(defun validate-transitions ()
  "Check all entities for state machine issues.
Returns a list of warning strings (same format as validate-specs).
Empty list = all clear.

Warns about:
- Unreachable states: member values with no incoming transition and not
  the initial/default state.
- Dead-end states: non-terminal states from which no terminal state is
  reachable (stuck in a cycle with no exit)."
  (let ((warnings nil))
    (dolist (entity-name (list-entities))
      (dolist (field-kw (detect-state-fields entity-name))
        (let ((label (format nil "~A:~A" entity-name
                             (string-downcase (symbol-name field-kw)))))
          (dolist (state (unreachable-states entity-name field-kw))
            (push (format nil "~A: state ~S is unreachable (no incoming transition, not the initial state)"
                          label state)
                  warnings))
          (dolist (state (dead-end-states entity-name field-kw))
            (push (format nil "~A: state ~S is a dead end (cannot reach any terminal state)"
                          label state)
                  warnings)))))
    (nreverse warnings)))
