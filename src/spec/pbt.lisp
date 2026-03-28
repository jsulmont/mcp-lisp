;;;; src/spec/pbt.lisp
;;;;
;;;; PBT runner: trial execution, negative testing, shrinking, and reporting.

(defpackage #:mcp-lisp/src/spec/pbt
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/registry
                #:*entities*
                #:*rules*
                #:*invariants*
                #:*variants*
                #:*config*
                #:*current-config*
                #:*scenarios*
                #:*scenario-generators*
                #:*scenario-negative-generators*
                #:*compiled-fn-cache*)
  (:import-from #:mcp-lisp/src/spec/introspection
                #:describe-entity
                #:list-entities
                #:describe-invariant
                #:list-invariants
                #:describe-variant
                #:entity-variants
                #:list-variants
                #:describe-scenario
                #:list-scenarios
                #:entity-fields
                #:entity-relations
                #:config)
  (:import-from #:mcp-lisp/src/spec/helpers
                #:all-pairs-check
                #:consecutive-pairs-check
                #:distribute-values
                #:partition-into
                #:haversine-distance-nm
                #:initial-bearing-deg
                #:heading-difference-deg
                #:point-in-polygon-p
                #:intervals-overlap-p
                #:interval-contains-p
                #:interval-before-p
                #:elapsed-since
                #:duration-at-least-p
                #:within-retention-period-p)
  (:import-from #:mcp-lisp/src/spec/pbt-util
                #:get-compiled-fn
                #:generate-value
                #:field-keyword
                #:field-constraints
                #:member-type-p
                #:override-val
                #:override-present-p
                #:getf-field-p)
  (:import-from #:mcp-lisp/src/spec/checking
                #:invariants-for
                #:variant-invariants-for
                #:check-invariants
                #:scenario-invariants-for
                #:check-scenario-invariants
                #:config-invariants
                #:check-config-invariants)
  (:import-from #:mcp-lisp/src/spec/constraints
                #:extract-generation-constraints)
  (:import-from #:mcp-lisp/src/spec/generation
                #:generate-instance
                #:default-generate-instance
                #:generate-config
                #:generate-scenario
                #:default-generate-scenario
                #:defgenerator
                #:defscenario-generator
                #:defscenario-negative-generator
                #:current-config
                #:ensure-entity-accessors
                #:ensure-variant-accessors
                #:ensure-config-accessor
                #:*generation-depth*
                #:*max-generation-depth*)
  (:import-from #:mcp-lisp/src/spec/rules
                #:apply-rule
                #:applicable-rules
                #:random-walk
                #:random-walk-scenario)
  (:export ;; Re-exports from sub-modules
           #:generate-value
           #:generate-instance
           #:default-generate-instance
           #:defgenerator
           #:override-val
           #:override-present-p
           #:ensure-entity-accessors
           #:ensure-variant-accessors
           #:generate-config
           #:config-invariants
           #:check-config-invariants
           #:check-invariants
           #:check-scenario-invariants
           #:invariants-for
           #:scenario-invariants-for
           #:generate-scenario
           #:default-generate-scenario
           #:defscenario-generator
           #:defscenario-negative-generator
           #:current-config
           #:extract-generation-constraints
           #:getf-field-p
           #:apply-rule
           #:applicable-rules
           #:random-walk
           #:random-walk-scenario
           #:all-pairs-check
           #:consecutive-pairs-check
           #:distribute-values
           #:partition-into
           #:haversine-distance-nm
           #:initial-bearing-deg
           #:heading-difference-deg
           #:point-in-polygon-p
           #:intervals-overlap-p
           #:interval-contains-p
           #:interval-before-p
           #:elapsed-since
           #:duration-at-least-p
           #:within-retention-period-p
           ;; Own exports
           #:shrink-scenario
           #:run-pbt
           #:check-scenario))

(in-package #:mcp-lisp/src/spec/pbt)

;;; ---------------------------------------------------------------------------
;;; PBT runner
;;; ---------------------------------------------------------------------------

(defun generate-raw-instance (entity-name)
  "Generate a random instance of ENTITY-NAME WITHOUT constraint-aware generation.
All fields are independently random — used for negative testing."
  (let* ((entity (describe-entity entity-name))
         (fields (getf entity :fields))
         (relations (getf entity :relations))
         (instance nil))
    (dolist (field fields)
      (let* ((fname (first field))
             (ftype (second field))
             (key (field-keyword fname))
             (fc (field-constraints field)))
        (push (generate-value ftype :min (getf fc :min) :max (getf fc :max))
              instance)
        (push key instance)))
    (dolist (rel relations)
      (when (eq (first rel) :belongs-to)
        (let ((fk-kw (intern (format nil "~A-ID"
                                     (string-upcase (symbol-name (second rel))))
                             :keyword)))
          (unless (getf instance fk-kw)
            (push (generate-value 'string) instance)
            (push fk-kw instance)))))
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
                     all-bounded))))
             (referenced-fields-bounded-p ()
               (when entity-name
                 (let ((fields (entity-fields entity-name))
                       (entity-sym (intern (string-upcase (string entity-name)))))
                   (labels ((collect-refs (form)
                              (cond
                                ((getf-field-p form entity-sym)
                                 (list (getf-field-p form entity-sym)))
                                ((consp form)
                                 (mapcan #'collect-refs (cdr form)))
                                (t nil))))
                     (let ((refs (remove-duplicates (collect-refs check-form))))
                       (when refs
                         (every (lambda (ref-kw)
                                  (let ((field (find ref-kw fields
                                                     :key (lambda (f)
                                                            (field-keyword (first f))))))
                                    (when field
                                      (let ((ftype (second field))
                                            (kwargs (cddr field)))
                                        (or (getf kwargs :min) (getf kwargs :max)
                                            (member-type-p ftype))))))
                                refs))))))))
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
              (or (all-fields-bounded-p) (referenced-fields-bounded-p)))
         "enforced by field bounds — :min/:max or :required constraints")
        ((or (uses-p '("/=" "STRING/=") check-form)
             (labels ((has-not-eq (f)
                        (and (consp f)
                             (or (and (symbolp (first f))
                                      (string= (symbol-name (first f)) "NOT")
                                      (consp (second f))
                                      (symbolp (first (second f)))
                                      (member (symbol-name (first (second f)))
                                              '("EQ" "EQL" "EQUAL" "STRING=")
                                              :test #'string=))
                                 (some #'has-not-eq (cdr f))))))
               (has-not-eq check-form)))
         "inequality over high-entropy fields — negative generator forces equality")
        ((and (uses-p '("IF" "WHEN" "COND") check-form)
              (uses-p '("EQ" "MEMBER") check-form))
         "conditional — needs targeted negative generator (defscenario-negative-generator)")
        (t nil)))))

(defun extract-inequality-field-pairs (invariant-entries)
  "Extract field keyword pairs from inequality comparisons across INVARIANT-ENTRIES.
Returns a list of (field-kw-1 field-kw-2) pairs for targeted negative generation."
  (let ((pairs nil))
    (dolist (entry invariant-entries)
      (let* ((inv (second entry))
             (on-sym (getf inv :on))
             (check-form (getf inv :check)))
        (labels ((walk (form)
                   (when (consp form)
                     (let* ((op (first form))
                            (op-name (when (symbolp op) (symbol-name op))))
                       (when op-name
                         (cond
                           ((and (or (string= op-name "/=")
                                     (string= op-name "STRING/="))
                                 (= (length form) 3))
                            (let ((fa (getf-field-p (second form) on-sym))
                                  (fb (getf-field-p (third form) on-sym)))
                              (when (and fa fb)
                                (pushnew (list fa fb) pairs :test #'equal))))
                           ((and (string= op-name "NOT") (= (length form) 2)
                                 (consp (second form)))
                            (let* ((inner (second form))
                                   (iop (first inner))
                                   (iop-name (when (symbolp iop)
                                               (symbol-name iop))))
                              (when (and iop-name
                                         (member iop-name
                                                 '("EQ" "EQL" "EQUAL" "STRING=")
                                                 :test #'string=)
                                         (= (length inner) 3))
                                (let ((fa (getf-field-p (second inner) on-sym))
                                      (fb (getf-field-p (third inner) on-sym)))
                                  (when (and fa fb)
                                    (pushnew (list fa fb) pairs
                                             :test #'equal))))))))
                       (unless (and (symbolp (first form))
                                    (string= (symbol-name (first form)) "QUOTE"))
                         (dolist (sub (cdr form))
                           (walk sub)))))))
          (walk check-form))))
    pairs))

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
          (let ((ineq-pairs (extract-inequality-field-pairs relevant)))
            (dotimes (i trials)
              (let ((instance (generate-raw-instance entity-name)))
                (when (and ineq-pairs (zerop (random 3)))
                  (let ((pair (nth (random (length ineq-pairs)) ineq-pairs)))
                    (setf (getf instance (second pair))
                          (getf instance (first pair)))))
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
                          (incf (getf stats :rejected)))))))))))))
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
