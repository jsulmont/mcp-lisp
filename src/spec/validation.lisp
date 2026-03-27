;;;; src/spec/validation.lisp
;;;;
;;;; Spec validation and invariant suggestion.

(defpackage #:mcp-lisp/src/spec/validation
  (:use #:cl)
  (:import-from #:alexandria
                #:ends-with-subseq
                #:flatten)
  (:import-from #:mcp-lisp/src/spec/registry
                #:*entities*
                #:*rules*
                #:*invariants*
                #:*variants*
                #:*config*
                #:*scenarios*
                #:*scenario-generators*
                #:*scenario-generator-sources*
                #:*compiled-fn-cache*
                #:*requirements*)
  (:import-from #:mcp-lisp/src/spec/introspection
                #:entity-accessor-p
                #:config-accessor-p
                #:variant-accessor-p
                #:decompose-accessor
                #:describe-scenario)
  (:export #:validate-specs
           #:suggest-invariants
           #:collect-called-symbols
           #:check-form-symbols
           #:collect-free-symbols
           #:check-form-free-variables))

(in-package #:mcp-lisp/src/spec/validation)

(defun collect-called-symbols (form)
  "Walk FORM and collect every symbol that appears in function-call position."
  (let ((syms nil))
    (labels ((walk (f)
               (when (consp f)
                 (let ((head (car f)))
                   (cond
                     ;; (quote ...) — skip entirely
                     ((eq head 'quote) nil)
                     ;; #'fn / (function fn) — not a call
                     ((eq head 'function) nil)
                     ;; (lambda ...) — walk body, skip params and declares
                     ((eq head 'lambda)
                      (dolist (body-form (cddr f))
                        (unless (and (consp body-form) (eq (car body-form) 'declare))
                          (walk body-form))))
                     ;; (let/let* ((var init)...) body) — walk inits and body, skip var names
                     ((member head '(let let*))
                      (dolist (b (second f))
                        (when (consp b) (walk (second b))))
                      (dolist (body-form (cddr f))
                        (unless (and (consp body-form) (eq (car body-form) 'declare))
                          (walk body-form))))
                     ;; (dolist (var list [result]) body...) — walk list, result, body
                     ((eq head 'dolist)
                      (let ((spec (second f)))
                        (walk (second spec))
                        (when (third spec) (walk (third spec))))
                      (dolist (body-form (cddr f))
                        (walk body-form)))
                     ;; (cond (test body...)...) — walk all test and body forms
                     ((eq head 'cond)
                      (dolist (clause (cdr f))
                        (when (consp clause)
                          (dolist (form clause)
                            (walk form)))))
                     ;; (declare ...) — metadata, skip entirely
                     ((eq head 'declare) nil)
                     ;; (return-from name value) — walk value, skip block name
                     ((eq head 'return-from)
                      (when (cddr f) (walk (third f))))
                     ;; (block name body...) — walk body, skip block name
                     ((eq head 'block)
                      (dolist (body-form (cddr f))
                        (walk body-form)))
                     ;; loop — walk sub-forms, skip keywords and bound vars
                     ((eq head 'loop)
                      (let ((tokens (cdr f))
                            (destructuring-patterns nil)
                            (kw-names '("FOR" "AS" "WITH" "INTO" "USING" "NAMED"
                                        "IN" "ON" "ACROSS" "FROM" "TO" "BELOW"
                                        "ABOVE" "DOWNTO" "DOWNFROM" "UPFROM" "BY"
                                        "BEING" "THE" "EACH"
                                        "HASH-KEY" "HASH-KEYS" "HASH-VALUE" "HASH-VALUES" "OF"
                                        "=" "THEN"
                                        "COLLECT" "COLLECTING" "APPEND" "APPENDING"
                                        "NCONC" "NCONCING" "COUNT" "COUNTING"
                                        "SUM" "SUMMING" "MAXIMIZE" "MAXIMIZING"
                                        "MINIMIZE" "MINIMIZING" "DO" "DOING"
                                        "WHILE" "UNTIL" "WHEN" "IF" "UNLESS"
                                        "ALWAYS" "NEVER" "THEREIS"
                                        "REPEAT" "RETURN" "INITIALLY" "FINALLY"
                                        "END" "ELSE"))
                            (binding-names '("FOR" "AS" "WITH" "INTO")))
                        (do ((rest tokens (cdr rest)))
                            ((null rest))
                          (let ((tok (car rest)))
                            (when (and (symbolp tok)
                                       (member (symbol-name tok) binding-names
                                               :test #'string=)
                                       (cdr rest) (consp (cadr rest)))
                              (push (cadr rest) destructuring-patterns))))
                        (dolist (tok tokens)
                          (unless (or (and (symbolp tok)
                                           (member (symbol-name tok) kw-names
                                                   :test #'string=))
                                      (member tok destructuring-patterns :test #'eq))
                            (walk tok)))))
                     (t
                      (when (symbolp head)
                        (pushnew head syms :test #'eq))
                      (dolist (sub (cdr f))
                        (walk sub))))))))
      (walk form))
    syms))

(defun check-form-symbols (form context-label warnings)
  "Check that every called symbol in FORM is resolvable. Push warnings for undefined ones."
  (dolist (sym (collect-called-symbols form))
    (unless (or (special-operator-p sym)
                (macro-function sym)
                (fboundp sym)
                (entity-accessor-p sym)
                (variant-accessor-p sym)
                (config-accessor-p sym)
                (keywordp sym))
      (push (format nil "~A: undefined function ~A" context-label sym)
            warnings)))
  warnings)

(defun collect-free-symbols (form &optional bound)
  "Walk FORM collecting symbols in variable position not in BOUND list.
Handles QUOTE, LAMBDA, LET, LET* binding forms."
  (let ((syms nil))
    (labels ((walk (f env)
               (cond
                 ((null f) nil)
                 ((and (symbolp f)
                       (not (keywordp f))
                       (not (eq f t))
                       (not (member f env :test #'eq)))
                  (pushnew f syms :test #'eq))
                 ((consp f)
                  (let ((head (car f)))
                    (cond
                      ((eq head 'quote) nil)
                      ;; #'fn / (function fn) — not a variable reference
                      ((eq head 'function) nil)
                      ((eq head 'lambda)
                       ;; bind params, walk body (skip declares)
                       (let ((params (remove-if (lambda (s) (member s '(&optional &rest &key &body)))
                                                (second f))))
                         (dolist (body-form (cddr f))
                           (unless (and (consp body-form) (eq (car body-form) 'declare))
                             (walk body-form (append params env))))))
                      ((member head '(let let*))
                       ;; walk init forms, then body with bindings (skip declares)
                       (let ((bindings (second f))
                             (new-env env))
                         (dolist (b bindings)
                           (let ((var (if (consp b) (car b) b))
                                 (init (when (consp b) (second b))))
                             (when init (walk init (if (eq head 'let*) new-env env)))
                             (push var new-env)))
                         (dolist (body-form (cddr f))
                           (unless (and (consp body-form) (eq (car body-form) 'declare))
                             (walk body-form new-env)))))
                      ;; (dolist (var list [result]) body...) — bind loop var
                      ((eq head 'dolist)
                       (let* ((spec (second f))
                              (var (first spec)))
                         (walk (second spec) env)
                         (when (third spec) (walk (third spec) (cons var env)))
                         (dolist (body-form (cddr f))
                           (walk body-form (cons var env)))))
                      ;; (cond (test body...)...) — walk all test and body forms
                      ((eq head 'cond)
                       (dolist (clause (cdr f))
                         (when (consp clause)
                           (dolist (form clause)
                             (walk form env)))))
                      ;; (declare ...) — metadata, skip entirely
                      ((eq head 'declare) nil)
                      ;; (return-from name value) — skip block name, walk value
                      ((eq head 'return-from)
                       (when (cddr f) (walk (third f) env)))
                      ;; (block name body...) — skip block name, walk body
                      ((eq head 'block)
                       (dolist (body-form (cddr f))
                         (walk body-form env)))
                      ;; loop — extract bound vars, walk expression sub-forms
                      ((eq head 'loop)
                       (let ((tokens (cdr f))
                             (loop-vars nil)
                             (kw-names '("FOR" "AS" "WITH" "INTO" "USING" "NAMED"
                                         "IN" "ON" "ACROSS" "FROM" "TO" "BELOW"
                                         "ABOVE" "DOWNTO" "DOWNFROM" "UPFROM" "BY"
                                         "BEING" "THE" "EACH"
                                         "HASH-KEY" "HASH-KEYS" "HASH-VALUE" "HASH-VALUES" "OF"
                                         "=" "THEN"
                                         "COLLECT" "COLLECTING" "APPEND" "APPENDING"
                                         "NCONC" "NCONCING" "COUNT" "COUNTING"
                                         "SUM" "SUMMING" "MAXIMIZE" "MAXIMIZING"
                                         "MINIMIZE" "MINIMIZING" "DO" "DOING"
                                         "WHILE" "UNTIL" "WHEN" "IF" "UNLESS"
                                         "ALWAYS" "NEVER" "THEREIS"
                                         "REPEAT" "RETURN" "INITIALLY" "FINALLY"
                                         "END" "ELSE"))
                             (binding-names '("FOR" "AS" "WITH" "INTO")))
                         (let ((destructuring-patterns nil))
                           (do ((rest tokens (cdr rest)))
                               ((null rest))
                             (let ((tok (car rest)))
                               (when (and (symbolp tok)
                                          (member (symbol-name tok) binding-names
                                                  :test #'string=)
                                          (cdr rest))
                                 (let ((binding (cadr rest)))
                                   (cond ((symbolp binding)
                                          (push binding loop-vars))
                                         ((consp binding)
                                          (push binding destructuring-patterns)
                                          (dolist (s (alexandria:flatten binding))
                                            (when (symbolp s)
                                              (push s loop-vars)))))))
                               (when (and (symbolp tok)
                                          (string= (symbol-name tok) "USING")
                                          (cdr rest) (consp (cadr rest))
                                          (cdadr rest) (symbolp (cadadr rest)))
                                 (push (cadadr rest) loop-vars))))
                           (let ((loop-env (append loop-vars env)))
                             (dolist (tok tokens)
                               (unless (or (and (symbolp tok)
                                                (or (member (symbol-name tok) kw-names
                                                            :test #'string=)
                                                    (member tok loop-vars :test #'eq)))
                                           (member tok destructuring-patterns :test #'eq))
                                 (walk tok loop-env)))))))
                      (t
                       ;; head is function position — skip it, walk args
                       (dolist (arg (cdr f))
                         (walk arg env)))))))))
      (walk form bound))
    syms))

(defun check-form-free-variables (form bound-vars context-label warnings)
  "Check that every free variable in FORM is among BOUND-VARS. Push warnings otherwise."
  (dolist (sym (collect-free-symbols form bound-vars))
    (push (format nil "~A: free variable ~A is not bound (expected one of: ~{~A~^, ~})"
                  context-label sym bound-vars)
          warnings))
  warnings)

(defun validate-specs ()
  "Check that all rules/invariants reference known entities (or variants) and that
forms in :check/:requires/:ensures/:let use resolvable symbols.
Also warns about non-exhaustive variant handling in rules.
Returns a list of warning strings. Empty list = all clear."
  (let ((entity-keys (loop for k being the hash-keys of *entities* collect k))
        (variant-keys (loop for k being the hash-keys of *variants* collect k))
        (scenario-keys (loop for k being the hash-keys of *scenarios* collect k))
        (warnings nil))
    (flet ((known-entity-p (sym)
             (member (string-downcase (string sym)) entity-keys :test #'string=))
           (known-variant-p (sym)
             (member (string-downcase (string sym)) variant-keys :test #'string=))
           (known-scenario-p (sym)
             (member (string-downcase (string sym)) scenario-keys :test #'string=)))
      ;; Check rules — :when car should name an entity
      (maphash (lambda (key plist)
                 (let ((when-clause (getf plist :when)))
                   (when (and when-clause (symbolp (car when-clause)))
                     (unless (known-entity-p (car when-clause))
                       (push (format nil "rule ~A: :when references unknown entity ~A"
                                     key (car when-clause))
                             warnings)))))
               *rules*)
      ;; Check invariants — :on should name an entity, variant, scenario, or :config
      (maphash (lambda (key plist)
                 (let ((on (getf plist :on)))
                   (when on
                     (unless (or (known-entity-p on) (known-variant-p on)
                                 (known-scenario-p on)
                                 (and (keywordp on)
                                      (string-equal (symbol-name on) "CONFIG")))
                       (push (format nil "invariant ~A: :on references unknown entity/scenario ~A"
                                     key on)
                             warnings)))))
               *invariants*)
      ;; Check relations — :of target should name an entity
      (maphash (lambda (key plist)
                 (dolist (rel (getf plist :relations))
                   (let ((of-target (getf (cddr rel) :of)))
                     (when (and of-target (not (known-entity-p of-target)))
                       (push (format nil "entity ~A: relation ~S references unknown entity ~A"
                                     key rel of-target)
                             warnings)))))
               *entities*)
      ;; Check forms in invariant :check clauses — functions and free variables
      (let ((config-keys (mapcar (lambda (f)
                                   (intern (string-upcase (symbol-name (first f)))
                                           :keyword))
                                 *config*)))
        (maphash (lambda (key plist)
                   (when (getf plist :check)
                     (setf warnings
                           (check-form-symbols (getf plist :check)
                                               (format nil "invariant ~A" key)
                                               warnings))
                     (when (getf plist :on)
                       (let ((on-sym (getf plist :on)))
                         (if (and (keywordp on-sym)
                                  (string-equal (symbol-name on-sym) "CONFIG"))
                             ;; Config invariant: no bound entity var, validate config key refs
                             (labels ((check-config-refs (form)
                                        (when (consp form)
                                          (if (and (symbolp (first form))
                                                   (string-equal (symbol-name (first form)) "CONFIG")
                                                   (= (length form) 2)
                                                   (keywordp (second form)))
                                              (unless (member (second form) config-keys)
                                                (push (format nil "invariant ~A: (config ~S) references unknown config key"
                                                              key (second form))
                                                      warnings))
                                              (dolist (sub form)
                                                (check-config-refs sub))))))
                               (check-config-refs (getf plist :check)))
                             ;; Entity/variant/scenario invariant: check free variables
                             (let* ((scenario (describe-scenario on-sym))
                                    (bound-vars
                                      (if scenario
                                          (mapcar (lambda (e)
                                                    (intern (symbol-name (getf e :binding))))
                                                  (getf scenario :entities))
                                          (list on-sym))))
                               (setf warnings
                                     (check-form-free-variables
                                      (getf plist :check)
                                      bound-vars
                                      (format nil "invariant ~A" key)
                                      warnings))))))))
                 *invariants*))
      ;; Check forms in rule :requires, :ensures, :sets, and :let clauses
      (maphash (lambda (key plist)
                 (dolist (form (getf plist :requires))
                   (setf warnings
                         (check-form-symbols form
                                             (format nil "rule ~A :requires" key)
                                             warnings)))
                 (dolist (form (getf plist :ensures))
                   (setf warnings
                         (check-form-symbols form
                                             (format nil "rule ~A :ensures" key)
                                             warnings)))
                 (loop for (accessor value) on (getf plist :sets) by #'cddr
                       do (setf warnings
                                (check-form-symbols accessor
                                                    (format nil "rule ~A :sets" key)
                                                    warnings))
                          (setf warnings
                                (check-form-symbols value
                                                    (format nil "rule ~A :sets" key)
                                                    warnings)))
                 (dolist (binding (getf plist :let))
                   (when (and (consp binding) (second binding))
                     (setf warnings
                           (check-form-symbols (second binding)
                                               (format nil "rule ~A :let" key)
                                               warnings)))))
               *rules*)
      ;; Check variant exhaustiveness in rules
      ;; Build map: entity-key → (discriminator . list-of-variant-values)
      (let ((entity-disc (make-hash-table :test #'equal)))
        (maphash (lambda (vkey vplist)
                   (declare (ignore vkey))
                   (let* ((parent (getf vplist :parent))
                          (disc (getf vplist :discriminator))
                          (val (getf vplist :value))
                          (entry (gethash parent entity-disc)))
                     (if entry
                         (push val (cdr entry))
                         (setf (gethash parent entity-disc)
                               (cons disc (list val))))))
                 *variants*)
        (maphash (lambda (ekey disc-entry)
                   (let ((disc-field (car disc-entry))
                         (all-values (cdr disc-entry))
                         (handled-values nil))
                     ;; Find rules referencing this entity's discriminator
                     (maphash (lambda (rkey rplist)
                                (declare (ignore rkey))
                                (let ((when-clause (getf rplist :when)))
                                  (when (and when-clause (consp when-clause)
                                             (symbolp (car when-clause))
                                             (string= (string-downcase
                                                        (symbol-name (car when-clause)))
                                                       ekey))
                                    (let ((disc-val (getf (cdr when-clause) disc-field)))
                                      (when disc-val
                                        (pushnew disc-val handled-values :test #'eq))))))
                              *rules*)
                     ;; Warn only if at least one variant is handled
                     (when handled-values
                       (dolist (val all-values)
                         (unless (member val handled-values :test #'eq)
                           (push (format nil "rule exhaustiveness: entity ~A variant ~A (~A = ~A) not handled by any rule"
                                         ekey val disc-field val)
                                 warnings))))))
                 entity-disc))
      ;; Check scenarios — entity refs exist, :per bindings valid
      (maphash (lambda (key plist)
                 (let ((binding-names nil))
                   (dolist (espec (getf plist :entities))
                     (let ((binding (getf espec :binding))
                           (entity (getf espec :entity))
                           (per (getf espec :per)))
                       (push binding binding-names)
                       (unless (known-entity-p entity)
                         (push (format nil "scenario ~A: entity ~A not defined"
                                       key entity)
                               warnings))
                       (when (and per (not (member per binding-names)))
                         (push (format nil "scenario ~A: :per ~A references unknown binding (must be declared before use)"
                                       key per)
                               warnings))))))
               *scenarios*)
      ;; Check generator coverage — warn when custom generators are likely needed
      ;; Scenarios with aggregate invariants need custom scenario generators
      (maphash (lambda (skey _splist)
                 (declare (ignore _splist))
                 (unless (gethash skey *scenario-generators*)
                   (maphash (lambda (_ikey iplist)
                              (declare (ignore _ikey))
                              (when (and (getf iplist :on)
                                         (string-equal (string-downcase
                                                         (symbol-name (getf iplist :on)))
                                                        skey))
                                (let ((check (getf iplist :check)))
                                  (when (and (consp check)
                                             (labels ((uses-aggregate (f)
                                                        (when (consp f)
                                                          (or (member (first f)
                                                                      '(reduce mapcar every some
                                                                        count remove-if remove-if-not
                                                                        loop length))
                                                              (some #'uses-aggregate (cdr f))))))
                                               (uses-aggregate check)))
                                    (push (format nil "scenario ~A: invariant uses aggregates but no defscenario-generator is registered"
                                                  skey)
                                          warnings)))))
                            *invariants*)))
               *scenarios*)
      ;; Entity-level invariants referencing has-many relation accessors
      (maphash (lambda (ekey eplist)
                 (let* ((relations (getf eplist :relations))
                        (has-many-accessors
                          (loop for rel in relations
                                when (eq (first rel) :has-many)
                                  collect (format nil "~A-~A"
                                                  ekey
                                                  (string-downcase
                                                    (symbol-name (second rel)))))))
                   (when has-many-accessors
                     (maphash (lambda (ikey iplist)
                                (when (and (getf iplist :on)
                                           (string-equal (string-downcase
                                                           (symbol-name (getf iplist :on)))
                                                         ekey)
                                           (not (gethash ekey *scenarios*)))
                                  (labels ((mentions-accessor-p (form)
                                             (cond
                                               ((and (symbolp form)
                                                     (member (string-downcase
                                                               (symbol-name form))
                                                             has-many-accessors
                                                             :test #'string=))
                                                t)
                                               ((consp form)
                                                (some #'mentions-accessor-p form)))))
                                    (when (mentions-accessor-p (getf iplist :check))
                                      (push (format nil "invariant ~A: references has-many accessor on entity ~A — only testable via scenario"
                                                    ikey ekey)
                                            warnings)))))
                              *invariants*))))
               *entities*)
      ;; Warn about trivially-true/false invariant :check forms
      (maphash (lambda (key plist)
                 (let ((check (getf plist :check)))
                   (when (or (eq check t)
                             (numberp check)
                             (stringp check))
                     (push (format nil "invariant ~A: :check is a constant (~S), trivially ~A"
                                   key check (if check "true" "false"))
                           warnings))))
               *invariants*)
      ;; Flag entities with non-identifier fields but zero invariants
      (maphash (lambda (ekey eplist)
                 (let* ((fields (getf eplist :fields))
                        (non-id-fields
                          (remove-if (lambda (f)
                                       (let ((n (string-downcase (symbol-name (first f)))))
                                         (or (string= n "id")
                                             (alexandria:ends-with-subseq "-mrid" n)
                                             (string= n "mrid"))))
                                     fields)))
                   (when (> (length non-id-fields) 0)
                     (let ((has-invariant nil))
                       (maphash (lambda (_ik iplist)
                                  (declare (ignore _ik))
                                  (when (and (getf iplist :on)
                                             (string-equal (string-downcase
                                                             (symbol-name (getf iplist :on)))
                                                           ekey))
                                    (setf has-invariant t)))
                                *invariants*)
                       (unless has-invariant
                         (push (format nil "entity ~A: ~A non-identifier fields but zero invariants"
                                       ekey (length non-id-fields))
                               warnings))))))
               *entities*)
      ;; Detect FK-like fields not covered by any scenario invariant
      (let ((fk-patterns '("-id" "-lfdi" "-mrid"))
            (scenario-inv-symbols nil))
        ;; Collect all symbols referenced in scenario invariant :check forms
        (maphash (lambda (_ik iplist)
                   (declare (ignore _ik))
                   (when (and (getf iplist :on)
                              (gethash (string-downcase (symbol-name (getf iplist :on)))
                                       *scenarios*))
                     (labels ((collect-syms (form)
                                (cond
                                  ((symbolp form) (push (string-downcase (symbol-name form))
                                                        scenario-inv-symbols))
                                  ((consp form) (mapc #'collect-syms form)))))
                       (collect-syms (getf iplist :check)))))
                 *invariants*)
        (maphash (lambda (ekey eplist)
                   (dolist (field (getf eplist :fields))
                     (let ((fname (string-downcase (symbol-name (first field)))))
                       (when (some (lambda (suffix)
                                     (and (> (length fname) (length suffix))
                                          (alexandria:ends-with-subseq suffix fname)))
                                   fk-patterns)
                         ;; Only flag if the prefix before the suffix matches a known entity
                         (let* ((matching-suffix
                                  (find-if (lambda (suffix)
                                             (and (> (length fname) (length suffix))
                                                  (alexandria:ends-with-subseq suffix fname)))
                                           fk-patterns))
                                (prefix (when matching-suffix
                                          (subseq fname 0 (- (length fname) (length matching-suffix)))))
                                (accessor (format nil "~A-~A" ekey fname)))
                           (when (and prefix
                                      (or (member prefix entity-keys :test #'string=)
                                          ;; Also match belongs-to relations on this entity
                                          (some (lambda (rel)
                                                  (and (eq (first rel) :belongs-to)
                                                       (string= prefix
                                                                (string-downcase
                                                                  (symbol-name (second rel))))))
                                                (getf eplist :relations))))
                             (unless (or (member accessor scenario-inv-symbols :test #'string=)
                                         (member fname scenario-inv-symbols :test #'string=))
                               (push (format nil "entity ~A: FK-like field ~A has no scenario invariant coverage"
                                             ekey fname)
                                     warnings))))))))
                 *entities*))
      ;; Detect belongs-to relations not covered by scenario invariants
      (maphash (lambda (ekey eplist)
                 (dolist (rel (getf eplist :relations))
                   (when (eq (first rel) :belongs-to)
                     (let ((accessor (format nil "~A-~A"
                                             ekey
                                             (string-downcase (symbol-name (second rel)))))
                           (rel-id (format nil "~A-id"
                                           (string-downcase (symbol-name (second rel))))))
                       (let ((covered nil))
                         (maphash (lambda (_ik iplist)
                                    (declare (ignore _ik))
                                    (when (and (getf iplist :on)
                                               (gethash (string-downcase
                                                          (symbol-name (getf iplist :on)))
                                                        *scenarios*))
                                      (labels ((mentions-p (form)
                                                 (cond
                                                   ((and (symbolp form)
                                                         (or (string-equal (symbol-name form) accessor)
                                                             (string-equal (symbol-name form) rel-id)))
                                                    t)
                                                   ((consp form) (some #'mentions-p form)))))
                                        (when (mentions-p (getf iplist :check))
                                          (setf covered t)))))
                                  *invariants*)
                         (unless covered
                           (push (format nil "entity ~A: belongs-to ~A has no scenario invariant coverage"
                                         ekey (second rel))
                                 warnings)))))))
               *entities*)
      ;; Config-aware scenario generator validation
      ;; When a scenario invariant references (config :key), warn if the
      ;; scenario's custom generator doesn't also reference that key.
      (labels ((config-ref-p (form)
                 (when (and (consp form) (= (length form) 2)
                            (symbolp (first form))
                            (string-equal (symbol-name (first form)) "CONFIG")
                            (keywordp (second form)))
                   (second form)))
               (collect-config-keys (form)
                 (cond
                   ((config-ref-p form) (list (config-ref-p form)))
                   ((consp form) (mapcan #'collect-config-keys form)))))
        (maphash (lambda (skey _splist)
                   (declare (ignore _splist))
                   (let ((gen-src (gethash skey *scenario-generator-sources*))
                         (inv-config-keys nil))
                     (maphash (lambda (_ik iplist)
                                (declare (ignore _ik))
                                (when (and (getf iplist :on)
                                           (string-equal (string-downcase
                                                           (symbol-name (getf iplist :on)))
                                                         skey))
                                  (setf inv-config-keys
                                        (union inv-config-keys
                                               (collect-config-keys (getf iplist :check))))))
                              *invariants*)
                     (when (and gen-src inv-config-keys)
                       (let ((gen-config-keys (collect-config-keys gen-src)))
                         (dolist (ck inv-config-keys)
                           (unless (member ck gen-config-keys)
                             (push (format nil "scenario ~A: invariant references (config ~S) but generator does not"
                                           skey ck)
                                   warnings)))))))
                 *scenarios*))
      ;; Warn about rules whose :sets touch immutable fields
      (let ((immutable-fields (make-hash-table :test #'equal)))
        (maphash (lambda (ekey eplist)
                   (dolist (field (getf eplist :fields))
                     (when (getf (cddr field) :immutable)
                       (let ((fname (string-downcase (symbol-name (first field)))))
                         (setf (gethash (cons ekey fname) immutable-fields) t)))))
                 *entities*)
        (when (plusp (hash-table-count immutable-fields))
          (maphash (lambda (rkey rplist)
                     (let* ((when-clause (getf rplist :when))
                            (entity-name (when (and when-clause (symbolp (car when-clause)))
                                           (string-downcase (symbol-name (car when-clause)))))
                            (sets-clause (getf rplist :sets)))
                       (when (and entity-name sets-clause)
                         (loop for (accessor-form _value-form) on sets-clause by #'cddr
                               do (let ((field-name
                                          (cond
                                            ((and (consp accessor-form) (eq (first accessor-form) 'getf)
                                                  (= (length accessor-form) 3) (keywordp (third accessor-form)))
                                             (string-downcase (symbol-name (third accessor-form))))
                                            ((and (consp accessor-form) (= (length accessor-form) 2)
                                                  (symbolp (first accessor-form)))
                                             (multiple-value-bind (ekey fname) (decompose-accessor (first accessor-form))
                                               (when (and ekey (string= ekey entity-name)) fname))))))
                                    (when (and field-name
                                              (gethash (cons entity-name field-name) immutable-fields))
                                      (push (format nil "rule ~A: :sets touches immutable field ~A on ~A"
                                                    rkey field-name entity-name)
                                            warnings)))))))
                   *rules*))))
      ;; Validate :unique-together constraints reference existing fields
      (maphash (lambda (ekey eplist)
                 (let ((field-names (mapcar (lambda (f) (string-downcase (symbol-name (first f))))
                                           (getf eplist :fields))))
                   (dolist (constraint (getf eplist :constraints))
                     (dolist (field-sym constraint)
                       (unless (member (string-downcase (symbol-name field-sym))
                                       field-names :test #'string=)
                         (push (format nil "entity ~A: :unique-together references unknown field ~A"
                                       ekey field-sym)
                               warnings))))))
               *entities*)
    (nreverse warnings)))

;;; ---------------------------------------------------------------------------
;;; suggest-invariants
;;; ---------------------------------------------------------------------------

(defun suggest-invariants ()
  "Scan entity relations and config fields to suggest missing invariants.
Returns a list of suggestion strings (defscenario + definvariant skeletons)."
  (let ((suggestions nil))
    (maphash
     (lambda (ekey eplist)
       (dolist (rel (getf eplist :relations))
         (let ((rel-type (first rel))
               (rel-name (second rel))
               (target (getf (cddr rel) :of)))
           (when target
             (let ((target-key (string-downcase (string target)))
                   (entity-name (string-downcase (symbol-name (getf eplist :name))))
                   (rel-str (string-downcase (symbol-name rel-name))))
               (cond
                 ((eq rel-type :has-one)
                  (push (format nil ";; ~A has-one ~A~%(defscenario ~A-~A-check~%  :entities ((parents (1 5) ~A)~%            (children (1 1) ~A :per parents)))~%~%(definvariant ~A-has-exactly-one-~A~%  :on ~A-~A-check~%  :check (= (length children) (length parents)))"
                                entity-name rel-str
                                entity-name rel-str
                                entity-name target-key
                                entity-name rel-str
                                entity-name rel-str)
                        suggestions))
                 ((eq rel-type :has-many)
                  (let ((bound-config-key
                          (when *config*
                            (loop for field in *config*
                                  for fname = (string-downcase (symbol-name (first field)))
                                  when (or (search rel-str fname)
                                           (search target-key fname))
                                    return (intern (string-upcase fname) :keyword)))))
                    (if bound-config-key
                        (push (format nil ";; ~A has-many ~A, bounded by (config ~S)~%(defscenario ~A-~A-bounds~%  :entities ((parents (1 5) ~A)~%            (children (1 10) ~A :per parents)))~%~%(definvariant ~A-count-within-~A-limit~%  :on ~A-~A-bounds~%  :check (every (lambda (p)~%           (<= (count-if (lambda (c) (= (... c) (... p))) children)~%               (config ~S)))~%         parents))"
                                      entity-name rel-str bound-config-key
                                      entity-name rel-str
                                      entity-name target-key
                                      entity-name rel-str
                                      entity-name rel-str
                                      bound-config-key)
                              suggestions)
                        (push (format nil ";; ~A has-many ~A~%(defscenario ~A-~A-check~%  :entities ((parents (1 5) ~A)~%            (children (1 10) ~A :per parents)))~%~%(definvariant ~A-has-~A~%  :on ~A-~A-check~%  :check (every (lambda (p)~%           (some (lambda (c) (= (... c) (... p))) children))~%         parents))"
                                      entity-name rel-str
                                      entity-name rel-str
                                      entity-name target-key
                                      entity-name rel-str
                                      entity-name rel-str)
                              suggestions))))))))))
     *entities*)
    (nreverse suggestions)))
