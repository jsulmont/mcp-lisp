;;;; src/spec/spec.lisp
;;;;
;;;; Behavioral specification DSL — entity definitions, rules, and invariants
;;;; stored as structured metadata. Inspired by JUXT Allium but delivered as
;;;; an in-process CL service rather than a file format.

(defpackage #:mcp-lisp/src/spec/spec
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:dict
                #:encode-json
                #:decode-json)
  (:export ;; Registries
           #:*entities*
           #:*rules*
           #:*invariants*
           #:*generators*
           #:*generator-sources*
           #:*variants*
           #:*config*
           #:*current-config*
           ;; Macros
           #:defentity
           #:defrule
           #:definvariant
           #:defvariant
           #:defconfig
           ;; Introspection
           #:list-entities
           #:describe-entity
           #:entity-fields
           #:entity-relations
           #:list-rules
           #:describe-rule
           #:list-invariants
           #:describe-invariant
           #:list-variants
           #:describe-variant
           #:entity-variants
           #:describe-config
           #:config-fields
           #:config
           ;; Scenarios
           #:*scenarios*
           #:*scenario-generators*
           #:*scenario-generator-sources*
           #:*scenario-negative-generators*
           #:*scenario-negative-generator-sources*
           #:*compiled-fn-cache*
           #:*helpers*
           #:*helper-sources*
           #:defscenario
           #:defhelper
           #:list-scenarios
           #:describe-scenario
           ;; Utilities
           #:register-entity-accessors
           #:clear-specs
           #:validate-specs
           #:suggest-invariants
           ;; AST
           #:form-to-ast
           #:ast-to-form
           ;; JSON
           #:specs-to-json
           #:json-to-specs
           #:spec-json-schema
           ;; Lisp serialization
           #:specs-to-lisp
           ;; S-expression data serialization
           #:specs-to-data
           #:data-to-specs
           #:write-specs
           #:read-specs))

(in-package #:mcp-lisp/src/spec/spec)

;;; ---------------------------------------------------------------------------
;;; Registries
;;; ---------------------------------------------------------------------------

(defvar *entities* (make-hash-table :test #'equal))
(defvar *rules* (make-hash-table :test #'equal))
(defvar *invariants* (make-hash-table :test #'equal))
(defvar *generators* (make-hash-table :test #'equal))
(defvar *generator-sources* (make-hash-table :test #'equal))
(defvar *variants* (make-hash-table :test #'equal))
(defvar *config* nil
  "Config field specs — a list of (NAME TYPE &key ...) forms set by DEFCONFIG.")
(defvar *current-config* nil
  "Currently active config plist, bound dynamically during PBT.")
(defvar *scenarios* (make-hash-table :test #'equal))
(defvar *scenario-generators* (make-hash-table :test #'equal))
(defvar *scenario-generator-sources* (make-hash-table :test #'equal))
(defvar *scenario-negative-generators* (make-hash-table :test #'equal))
(defvar *scenario-negative-generator-sources* (make-hash-table :test #'equal))
(defvar *compiled-fn-cache* (make-hash-table :test #'equal))
(defvar *helpers* (make-hash-table :test #'equal))
(defvar *helper-sources* (make-hash-table :test #'equal))

;;; ---------------------------------------------------------------------------
;;; Known keywords for validation at macroexpand time
;;; ---------------------------------------------------------------------------

(defparameter +known-field-keys+ '(:required :default :unique :min :max :derived-from))
(defparameter +relation-types+ '(:has-many :has-one :belongs-to))

;;; ---------------------------------------------------------------------------
;;; Entity accessor generation
;;; ---------------------------------------------------------------------------

(defun register-entity-accessors (name fields relations)
  "Define accessor functions for an entity's fields and relations.
Accessor names follow the pattern ENTITY-FIELD, e.g. ACCOUNT-BALANCE.
Called automatically by DEFENTITY so accessors exist immediately."
  (let ((entity-name (string name)))
    (dolist (field fields)
      (let* ((field-sym (first field))
             (accessor (intern (format nil "~A-~A" entity-name (symbol-name field-sym))))
             (key (intern (symbol-name field-sym) :keyword)))
        (setf (symbol-function accessor)
              (let ((k key)) (lambda (instance) (getf instance k))))))
    (dolist (rel relations)
      (let* ((rel-name (second rel))
             (accessor (intern (format nil "~A-~A" entity-name (symbol-name rel-name))))
             (key (intern (symbol-name rel-name) :keyword)))
        (unless (fboundp accessor)
          (setf (symbol-function accessor)
                (let ((k key)) (lambda (instance) (getf instance k)))))))))

;;; ---------------------------------------------------------------------------
;;; defentity
;;; ---------------------------------------------------------------------------

(defun parse-entity-slots (slots)
  "Classify SLOTS into fields, relations, and derived entries.
Returns (values fields relations derived)."
  (let (fields relations derived)
    (dolist (slot slots)
      (let ((head (car slot)))
        (cond
          ((member head +relation-types+)
           (push slot relations))
          ((eq head :derived)
           (push slot derived))
          (t
           ;; Regular field: (name type &key ...)
           (let ((kwargs (cddr slot)))
             (loop for (k) on kwargs by #'cddr
                   unless (member k +known-field-keys+)
                     do (error "defentity: unknown field keyword ~S in slot ~S" k slot)))
           (push slot fields)))))
    (values (nreverse fields) (nreverse relations) (nreverse derived))))

(defmacro defentity (name (&rest supers) &body slots)
  "Define a specification entity. Stores metadata in *entities* — no class generation.

  (defentity user ()
    (id string :required t)
    (email string :required t)
    (role (member :admin :member :guest) :default :member)
    (:has-many orders :of order)
    (:derived display-name (lambda (u) (or (name u) (email u)))))"
  (multiple-value-bind (fields relations derived)
      (parse-entity-slots slots)
    (let ((key (string-downcase (string name))))
      `(progn
         (setf (gethash ,key *entities*)
               (list :name ',name
                     :supers ',supers
                     :fields ',fields
                     :relations ',relations
                     :derived ',derived))
         (register-entity-accessors ',name ',fields ',relations)
         ',name))))

;;; ---------------------------------------------------------------------------
;;; defrule
;;; ---------------------------------------------------------------------------

(defmacro defrule (name &key when let requires sets ensures)
  "Define a behavioral rule. Metadata-only — nothing is compiled or executed.

  (defrule place-order
    :when (order :state :draft)
    :let ((customer (order-customer order)))
    :requires ((active-account-p customer)
               (pos (account-balance customer)))
    :sets ((order-placed-at order) (get-universal-time))
    :ensures ((eq (order-state order) :placed)))"
  (let ((key (string-downcase (string name))))
    `(progn
       (setf (gethash ,key *rules*)
             (list :name ',name
                   :when ',when
                   :let ',let
                   :requires ',requires
                   :sets ',sets
                   :ensures ',ensures))
       ',name)))

;;; ---------------------------------------------------------------------------
;;; definvariant
;;; ---------------------------------------------------------------------------

(defmacro definvariant (name &key on check)
  "Define a spec invariant. Stored as quoted form, not compiled.

  (definvariant positive-balance
    :on account
    :check (>= (account-balance account) 0))"
  (let ((key (string-downcase (string name))))
    `(progn
       (setf (gethash ,key *invariants*)
             (list :name ',name
                   :on ',on
                   :check ',check))
       (clrhash *compiled-fn-cache*)
       ',name)))

;;; ---------------------------------------------------------------------------
;;; defvariant
;;; ---------------------------------------------------------------------------

(defmacro defvariant (name (parent discriminator value) &body fields)
  "Define a variant of an entity (sum type arm). Stores metadata in *variants*.

  (defvariant branch (node :kind :branch)
    (children list :required t))"
  (let ((key (string-downcase (string name)))
        (parent-key (string-downcase (string parent))))
    ;; Validate field keywords at macroexpand time
    (dolist (field fields)
      (let ((kwargs (cddr field)))
        (loop for (k) on kwargs by #'cddr
              unless (member k +known-field-keys+)
                do (error "defvariant: unknown field keyword ~S in field ~S" k field))))
    `(progn
       (setf (gethash ,key *variants*)
             (list :name ',name
                   :parent ,parent-key
                   :discriminator ',discriminator
                   :value ',value
                   :fields ',fields))
       ',name)))

;;; ---------------------------------------------------------------------------
;;; defconfig
;;; ---------------------------------------------------------------------------

(defmacro defconfig (&body fields)
  "Define a global typed configuration. Single config per spec set.

  (defconfig
    (max-leverage number :default 10.0 :min 1.0 :max 100.0)
    (margin-call-threshold number :default 0.5 :min 0.0 :max 1.0)
    (allow-short-selling boolean :default t))"
  ;; Validate field keywords at macroexpand time
  (dolist (field fields)
    (let ((kwargs (cddr field)))
      (loop for (k) on kwargs by #'cddr
            unless (member k +known-field-keys+)
              do (error "defconfig: unknown field keyword ~S in field ~S" k field))))
  `(progn
     (setf *config* ',fields)
     (values)))

;;; ---------------------------------------------------------------------------
;;; defscenario
;;; ---------------------------------------------------------------------------

(defun parse-scenario-cardinality (card)
  "Parse cardinality spec: N → (N N), (MIN MAX) → (MIN MAX)."
  (if (consp card)
      (list (first card) (second card))
      (list card card)))

(defmacro defscenario (name &key entities)
  "Define a multi-entity test scenario for cross-entity PBT.

  (defscenario grid-dispatch
    :entities ((zones   (1 3) grid-zone)
               (gens    (3 8) generator :per zones)
               (storage (0 2) storage-unit :per zones)
               (interval 1 dispatch-interval)))"
  (let ((key (string-downcase (string name)))
        (parsed-entities
          (mapcar (lambda (spec)
                    (destructuring-bind (binding card entity-name &key per) spec
                      (let ((minmax (parse-scenario-cardinality card)))
                        (list :binding (intern (string binding) :keyword)
                              :entity (string-downcase (string entity-name))
                              :min (first minmax)
                              :max (second minmax)
                              :per (when per
                                     (intern (string per) :keyword))))))
                  entities)))
    `(progn
       (setf (gethash ,key *scenarios*)
             (list :name ',name
                   :entities ',parsed-entities))
       ',name)))

;;; ---------------------------------------------------------------------------
;;; defhelper — persistent utility functions
;;; ---------------------------------------------------------------------------

(defmacro defhelper (name lambda-list &body body)
  "Define a helper function that persists across JSON round-trips.
Use for utility functions referenced by invariant check forms.

  (defhelper haversine-distance-nm (lat1 lon1 lat2 lon2)
    ...)"
  (let ((key (string-downcase (string name))))
    `(progn
       (defun ,name ,lambda-list ,@body)
       (setf (gethash ,key *helpers*) #',name)
       (setf (gethash ,key *helper-sources*)
             '(defhelper ,name ,lambda-list ,@body))
       ',name)))

;;; ---------------------------------------------------------------------------
;;; Config accessor
;;; ---------------------------------------------------------------------------

(defun config (key)
  "Read config parameter KEY from the current config instance.
During PBT, reads from *CURRENT-CONFIG*. Outside PBT, returns the
field's :default value from the defconfig spec."
  (if *current-config*
      (getf *current-config* key)
      (let ((field (find key *config*
                         :key (lambda (f) (intern (symbol-name (first f)) :keyword)))))
        (when field (getf (cddr field) :default)))))

;;; ---------------------------------------------------------------------------
;;; Introspection
;;; ---------------------------------------------------------------------------

(defun list-entities ()
  "Return a list of registered entity name strings."
  (loop for k being the hash-keys of *entities* collect k))

(defun describe-entity (name)
  "Return the plist for entity NAME (string-downcased), or NIL."
  (gethash (string-downcase (string name)) *entities*))

(defun entity-fields (name)
  "Return just the field specs for entity NAME."
  (getf (describe-entity name) :fields))

(defun entity-relations (name)
  "Return just the relation specs for entity NAME."
  (getf (describe-entity name) :relations))

(defun list-rules ()
  "Return a list of registered rule name strings."
  (loop for k being the hash-keys of *rules* collect k))

(defun describe-rule (name)
  "Return the plist for rule NAME (string-downcased), or NIL."
  (gethash (string-downcase (string name)) *rules*))

(defun list-invariants ()
  "Return a list of registered invariant name strings."
  (loop for k being the hash-keys of *invariants* collect k))

(defun describe-invariant (name)
  "Return the plist for invariant NAME (string-downcased), or NIL."
  (gethash (string-downcase (string name)) *invariants*))

(defun list-variants ()
  "Return a list of registered variant name strings."
  (loop for k being the hash-keys of *variants* collect k))

(defun describe-variant (name)
  "Return the plist for variant NAME (string-downcased), or NIL."
  (gethash (string-downcase (string name)) *variants*))

(defun entity-variants (entity-name)
  "Return variant name strings for entity ENTITY-NAME."
  (let ((key (string-downcase (string entity-name)))
        (result nil))
    (maphash (lambda (vkey vplist)
               (when (string= key (getf vplist :parent))
                 (push vkey result)))
             *variants*)
    (nreverse result)))

(defun describe-config ()
  "Return the config field specs, or NIL if no config defined."
  *config*)

(defun config-fields ()
  "Return the config field specs (alias for DESCRIBE-CONFIG)."
  *config*)

(defun list-scenarios ()
  "Return a list of registered scenario name strings."
  (loop for k being the hash-keys of *scenarios* collect k))

(defun describe-scenario (name)
  "Return the plist for scenario NAME (string-downcased), or NIL."
  (gethash (string-downcase (string name)) *scenarios*))

;;; ---------------------------------------------------------------------------
;;; Utilities
;;; ---------------------------------------------------------------------------

(defun clear-specs ()
  "Reset all spec registries."
  (clrhash *entities*)
  (clrhash *rules*)
  (clrhash *invariants*)
  (clrhash *generators*)
  (clrhash *generator-sources*)
  (clrhash *variants*)
  (clrhash *scenarios*)
  (clrhash *scenario-generators*)
  (clrhash *scenario-generator-sources*)
  (clrhash *scenario-negative-generators*)
  (clrhash *scenario-negative-generator-sources*)
  (clrhash *helpers*)
  (clrhash *helper-sources*)
  (setf *config* nil)
  (setf *current-config* nil)
  (clrhash *compiled-fn-cache*)
  (values))

(defun entity-accessor-p (sym)
  "Return T if SYM looks like an entity accessor (ENTITY-FIELD or ENTITY-RELATION)."
  (let ((name (string-downcase (symbol-name sym))))
    (maphash (lambda (ekey plist)
               (let ((prefix (concatenate 'string ekey "-")))
                 (when (and (> (length name) (length prefix))
                            (string= prefix name :end2 (length prefix)))
                   (let ((suffix (subseq name (length prefix))))
                     (when (or (some (lambda (f)
                                       (string= suffix
                                                (string-downcase (symbol-name (first f)))))
                                     (getf plist :fields))
                               (some (lambda (r)
                                       (string= suffix
                                                (string-downcase (symbol-name (second r)))))
                                     (getf plist :relations)))
                       (return-from entity-accessor-p t))))))
             *entities*)
    nil))

(defun config-accessor-p (sym)
  "Return T if SYM is the CONFIG accessor function (any package)."
  (string-equal (symbol-name sym) "CONFIG"))

(defun variant-accessor-p (sym)
  "Return T if SYM looks like a variant accessor (VARIANT-FIELD)."
  (let ((name (string-downcase (symbol-name sym))))
    (maphash (lambda (vkey vplist)
               (let ((prefix (concatenate 'string vkey "-")))
                 (when (and (> (length name) (length prefix))
                            (string= prefix name :end2 (length prefix)))
                   (let ((suffix (subseq name (length prefix))))
                     (when (some (lambda (f)
                                   (string= suffix
                                            (string-downcase (symbol-name (first f)))))
                                 (getf vplist :fields))
                       (return-from variant-accessor-p t))))))
             *variants*)
    nil))

(defun decompose-accessor (sym)
  "If SYM names an entity accessor like ACCOUNT-BALANCE, return
\(values entity-key field-name) where both are lowercase strings.
Returns NIL if SYM is not a recognized accessor."
  (let ((name (string-downcase (symbol-name sym))))
    (maphash (lambda (ekey plist)
               (let ((prefix (concatenate 'string ekey "-")))
                 (when (and (> (length name) (length prefix))
                            (string= prefix name :end2 (length prefix)))
                   (let ((suffix (subseq name (length prefix))))
                     (when (or (some (lambda (f)
                                       (string= suffix
                                                (string-downcase (symbol-name (first f)))))
                                     (getf plist :fields))
                               (some (lambda (r)
                                       (string= suffix
                                                (string-downcase (symbol-name (second r)))))
                                     (getf plist :relations)))
                       (return-from decompose-accessor
                         (values ekey suffix)))))))
             *entities*)
    nil))

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
                                        "END" "ELSE")))
                        (dolist (tok tokens)
                          (unless (and (symbolp tok)
                                       (member (symbol-name tok) kw-names
                                               :test #'string=))
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
                         (do ((rest tokens (cdr rest)))
                             ((null rest))
                           (let ((tok (car rest)))
                             (when (and (symbolp tok)
                                        (member (symbol-name tok) binding-names
                                                :test #'string=)
                                        (cdr rest) (symbolp (cadr rest)))
                               (push (cadr rest) loop-vars))
                             (when (and (symbolp tok)
                                        (string= (symbol-name tok) "USING")
                                        (cdr rest) (consp (cadr rest))
                                        (cdadr rest) (symbolp (cadadr rest)))
                               (push (cadadr rest) loop-vars))))
                         (let ((loop-env (append loop-vars env)))
                           (dolist (tok tokens)
                             (unless (and (symbolp tok)
                                          (or (member (symbol-name tok) kw-names
                                                      :test #'string=)
                                              (member tok loop-vars :test #'eq)))
                               (walk tok loop-env))))))
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
      ;; Check invariants — :on should name an entity, variant, or scenario
      (maphash (lambda (key plist)
                 (let ((on (getf plist :on)))
                   (when on
                     (unless (or (known-entity-p on) (known-variant-p on)
                                 (known-scenario-p on))
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
      (maphash (lambda (key plist)
                 (when (getf plist :check)
                   (setf warnings
                         (check-form-symbols (getf plist :check)
                                             (format nil "invariant ~A" key)
                                             warnings))
                   (when (getf plist :on)
                     (let* ((on-sym (getf plist :on))
                            (scenario (describe-scenario on-sym))
                            (bound-vars
                              (if scenario
                                  ;; Scenario invariant: bindings are the variable names
                                  (mapcar (lambda (e)
                                            (intern (symbol-name (getf e :binding))))
                                          (getf scenario :entities))
                                  ;; Entity/variant invariant: entity name is the variable
                                  (list on-sym))))
                       (setf warnings
                             (check-form-free-variables
                              (getf plist :check)
                              bound-vars
                              (format nil "invariant ~A" key)
                              warnings))))))
               *invariants*)
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
      ;; Entities with conditional invariants (if/when on member fields) need custom generators
      (maphash (lambda (ekey _eplist)
                 (declare (ignore _eplist))
                 (unless (gethash ekey *generators*)
                   (let ((has-conditional nil))
                     (maphash (lambda (_ikey iplist)
                                (declare (ignore _ikey))
                                (when (and (getf iplist :on)
                                           (string-equal (string-downcase
                                                           (symbol-name (getf iplist :on)))
                                                          ekey))
                                  (let ((check (getf iplist :check)))
                                    (when (and (consp check)
                                               (member (first check) '(if when cond)))
                                      (setf has-conditional t)))))
                              *invariants*)
                     (when has-conditional
                       (push (format nil "entity ~A: has conditional invariants but no defgenerator is registered"
                                     ekey)
                             warnings)))))
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
                         ;; Check if any scenario invariant mentions an accessor for this field
                         (let ((accessor (format nil "~A-~A" ekey fname)))
                           (unless (member accessor scenario-inv-symbols :test #'string=)
                             (push (format nil "entity ~A: FK-like field ~A has no scenario invariant coverage"
                                           ekey fname)
                                   warnings)))))))
                 *entities*))
      ;; Detect belongs-to relations not covered by scenario invariants
      (maphash (lambda (ekey eplist)
                 (dolist (rel (getf eplist :relations))
                   (when (eq (first rel) :belongs-to)
                     (let ((accessor (format nil "~A-~A"
                                             ekey
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
                                                         (string-equal (symbol-name form) accessor))
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
                 *scenarios*)))
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

;;; ---------------------------------------------------------------------------
;;; JSON serialization
;;; ---------------------------------------------------------------------------

(defun form-to-string (form)
  "Serialize FORM to a clean lowercase string without package prefixes."
  (labels ((emit (x stream)
             (cond
               ((null x) (write-string "nil" stream))
               ((eq x t) (write-string "t" stream))
               ((keywordp x)
                (write-char #\: stream)
                (write-string (string-downcase (symbol-name x)) stream))
               ((symbolp x)
                (write-string (string-downcase (symbol-name x)) stream))
               ((stringp x)
                (write x :stream stream :escape t))
               ((numberp x)
                (write x :stream stream))
               ((consp x)
                (write-char #\( stream)
                (loop for rest on x
                      for first = t then nil
                      do (unless first (write-char #\Space stream))
                         (if (consp rest)
                             (emit (car rest) stream)
                             ;; dotted pair tail
                             (progn (write-string ". " stream)
                                    (emit rest stream))))
                (write-char #\) stream))
               (t (write x :stream stream)))))
    (with-output-to-string (s)
      (emit form s))))

;;; ---------------------------------------------------------------------------
;;; Portable AST for JSON interchange
;;; ---------------------------------------------------------------------------

(defun form-to-ast (form)
  "Convert a CL form to a portable AST hash table.
Node types: literal, keyword, var, field, compare, eq, and, or, not,
if, member, lambda, let, call."
  (cond
    ((null form)
     (dict "node" "literal" "value" nil))
    ((eq form t)
     (dict "node" "literal" "value" t))
    ((keywordp form)
     (dict "node" "keyword" "name" (string-downcase (symbol-name form))))
    ((numberp form)
     (dict "node" "literal" "value" form))
    ((stringp form)
     (dict "node" "literal" "value" form))
    ((characterp form)
     (dict "node" "literal" "type" "char" "value" (char-code form)))
    ((symbolp form)
     (dict "node" "var" "name" (string-downcase (symbol-name form))))
    ((consp form)
     (let ((head (car form)))
       (cond
         ;; (quote x) — rare at top level; member handler unquotes inline
         ((eq head 'quote)
          (let ((val (second form)))
            (cond
              ((keywordp val)
               (dict "node" "keyword" "name" (string-downcase (symbol-name val))))
              ((symbolp val)
               (dict "node" "literal" "value" (string-downcase (symbol-name val))))
              ((listp val)
               (dict "node" "quote"
                     "elements" (coerce (mapcar #'form-to-ast
                                                (mapcar (lambda (x) (list 'quote x)) val))
                                        'vector)))
              (t (dict "node" "literal" "value" val)))))
         ;; (and ...)
         ((eq head 'and)
          (dict "node" "and"
                "args" (coerce (mapcar #'form-to-ast (cdr form)) 'vector)))
         ;; (or ...)
         ((eq head 'or)
          (dict "node" "or"
                "args" (coerce (mapcar #'form-to-ast (cdr form)) 'vector)))
         ;; (not x)
         ((eq head 'not)
          (dict "node" "not" "arg" (form-to-ast (second form))))
         ;; (if test then else)
         ((eq head 'if)
          (dict "node" "if"
                "test" (form-to-ast (second form))
                "then" (form-to-ast (third form))
                "else" (form-to-ast (fourth form))))
         ;; comparison: >= <= > < =
         ((member head '(>= <= > < =))
          (dict "node" "compare"
                "op" (symbol-name head)
                "left" (form-to-ast (second form))
                "right" (form-to-ast (third form))))
         ;; (eq a b)
         ((eq head 'eq)
          (dict "node" "eq"
                "left" (form-to-ast (second form))
                "right" (form-to-ast (third form))))
         ;; (member val '(items...)) — only for literal quoted sets
         ;; with no extra keyword args; other forms fall through to call
         ((and (eq head 'member)
               (= (length form) 3)
               (let ((set-form (third form)))
                 (and (consp set-form) (eq (car set-form) 'quote))))
          (let ((set-items (second (third form))))
            (dict "node" "member"
                  "value" (form-to-ast (second form))
                  "set" (coerce (mapcar #'form-to-ast
                                        (if (listp set-items) set-items
                                            (list set-items)))
                                'vector))))
         ;; (getf obj :key) → field node
         ((eq head 'getf)
          (dict "node" "field"
                "object" (form-to-ast (second form))
                "field" (string-downcase (symbol-name (third form)))))
         ;; (lambda (params...) body)
         ((eq head 'lambda)
          (dict "node" "lambda"
                "params" (coerce (mapcar (lambda (p) (string-downcase (symbol-name p)))
                                         (second form))
                                 'vector)
                "body" (form-to-ast (if (cdddr form)
                                        `(progn ,@(cddr form))
                                        (third form)))))
         ;; (let/let* ((var init)...) body)
         ((member head '(let let*))
          (dict "node" (if (eq head 'let*) "let*" "let")
                "bindings" (coerce
                            (mapcar (lambda (b)
                                      (if (consp b)
                                          (dict "name" (string-downcase (symbol-name (car b)))
                                                "value" (form-to-ast (second b)))
                                          (dict "name" (string-downcase (symbol-name b))
                                                "value" (form-to-ast nil))))
                                    (second form))
                            'vector)
                "body" (form-to-ast (if (cdddr form)
                                        `(progn ,@(cddr form))
                                        (third form)))))
         ;; (cond (test1 body1) ... [(t else)]) → nested if
         ((eq head 'cond)
          (labels ((cond-to-if (clauses)
                     (cond
                       ((null clauses) (form-to-ast nil))
                       ((eq (caar clauses) t)
                        (form-to-ast (if (cddar clauses)
                                         `(progn ,@(cdar clauses))
                                         (cadar clauses))))
                       ((null (cdr clauses))
                        (dict "node" "if"
                              "test" (form-to-ast (caar clauses))
                              "then" (form-to-ast (if (cddar clauses)
                                                      `(progn ,@(cdar clauses))
                                                      (cadar clauses)))
                              "else" (form-to-ast nil)))
                       (t
                        (dict "node" "if"
                              "test" (form-to-ast (caar clauses))
                              "then" (form-to-ast (if (cddar clauses)
                                                      `(progn ,@(cdar clauses))
                                                      (cadar clauses)))
                              "else" (cond-to-if (cdr clauses)))))))
            (cond-to-if (cdr form))))
         ;; entity accessor: (entity-field entity) → field node
         ((and (symbolp head) (= (length form) 2) (decompose-accessor head))
          (multiple-value-bind (entity-key field-name) (decompose-accessor head)
            (declare (ignore entity-key))
            (dict "node" "field"
                  "object" (form-to-ast (second form))
                  "field" field-name)))
         ;; default: function call
         ((symbolp head)
          (dict "node" "call"
                "fn" (string-downcase (symbol-name head))
                "args" (coerce (mapcar #'form-to-ast (cdr form)) 'vector)))
         ;; fallback
         (t (dict "node" "call"
                  "fn" (format nil "~S" head)
                  "args" (coerce (mapcar #'form-to-ast (cdr form)) 'vector))))))
    (t (dict "node" "literal" "value" nil))))

(defun resolve-fn-symbol (name-string)
  "Resolve a function name string to a symbol, preferring packages where
the function is already defined. Checks the CL package and the PBT package
before falling back to *PACKAGE*."
  (let ((uname (string-upcase name-string)))
    (or (multiple-value-bind (sym status) (find-symbol uname :cl)
          (when (and status (fboundp sym)) sym))
        (let ((pbt-pkg (find-package '#:mcp-lisp/src/spec/pbt)))
          (when pbt-pkg
            (multiple-value-bind (sym status) (find-symbol uname pbt-pkg)
              (when (and status (fboundp sym)) sym))))
        (intern uname))))

(defun ast-to-form (ast)
  "Convert a portable AST hash table back to a CL form."
  (cond
    ((null ast) nil)
    ((and (vectorp ast) (not (stringp ast))) (map 'list #'ast-to-form ast))
    ((hash-table-p ast)
     (let ((node (gethash "node" ast)))
       (cond
         ((string= node "literal")
          (let ((typ (gethash "type" ast))
                (val (gethash "value" ast)))
            (cond
              ((and typ (string= typ "char")) (code-char val))
              ((and (vectorp val) (not (stringp val))) (coerce val 'list))
              (t val))))

         ((string= node "keyword")
          (intern (string-upcase (gethash "name" ast)) :keyword))

         ((string= node "var")
          (intern (string-upcase (gethash "name" ast))))

         ((string= node "field")
          (let* ((obj (ast-to-form (gethash "object" ast)))
                 (field (gethash "field" ast))
                 (accessor (when (symbolp obj)
                             (intern (format nil "~A-~A"
                                             (symbol-name obj) (string-upcase field))))))
            (if (and accessor (entity-accessor-p accessor))
                (list accessor obj)
                (list 'getf obj (intern (string-upcase field) :keyword)))))

         ((string= node "compare")
          (list (find-symbol (gethash "op" ast) :cl)
                (ast-to-form (gethash "left" ast))
                (ast-to-form (gethash "right" ast))))

         ((string= node "eq")
          (list 'eq
                (ast-to-form (gethash "left" ast))
                (ast-to-form (gethash "right" ast))))

         ((string= node "and")
          (cons 'and (map 'list #'ast-to-form (gethash "args" ast))))

         ((string= node "or")
          (cons 'or (map 'list #'ast-to-form (gethash "args" ast))))

         ((string= node "not")
          (list 'not (ast-to-form (gethash "arg" ast))))

         ((string= node "if")
          (list 'if
                (ast-to-form (gethash "test" ast))
                (ast-to-form (gethash "then" ast))
                (ast-to-form (gethash "else" ast))))

         ((string= node "member")
          (list 'member
                (ast-to-form (gethash "value" ast))
                (list 'quote (map 'list #'ast-to-form (gethash "set" ast)))))

         ((string= node "quote")
          (list 'quote (map 'list #'ast-to-form (gethash "elements" ast))))

         ((string= node "lambda")
          (list 'lambda
                (map 'list (lambda (p) (intern (string-upcase p)))
                     (gethash "params" ast))
                (ast-to-form (gethash "body" ast))))

         ((or (string= node "let") (string= node "let*"))
          (list (if (string= node "let*") 'let* 'let)
                (map 'list (lambda (b)
                             (list (intern (string-upcase (gethash "name" b)))
                                   (ast-to-form (gethash "value" b))))
                     (gethash "bindings" ast))
                (ast-to-form (gethash "body" ast))))

         ((string= node "call")
          (cons (resolve-fn-symbol (gethash "fn" ast))
                (map 'list #'ast-to-form (gethash "args" ast))))

         (t (error "Unknown AST node type: ~A" node)))))
    (t ast)))

(defun field-to-ht (field-spec)
  "Convert a field spec like (ID STRING :REQUIRED T) to a hash table."
  (let* ((name (string-downcase (symbol-name (first field-spec))))
         (type (form-to-string (second field-spec)))
         (ht (dict "name" name "type" type)))
    (loop for (k v) on (cddr field-spec) by #'cddr
          do (case k
               (:required     (when v (setf (gethash "required" ht) t)))
               (:unique       (when v (setf (gethash "unique" ht) t)))
               (:default      (setf (gethash "default" ht) (form-to-string v)))
               (:min          (setf (gethash "min" ht) v))
               (:max          (setf (gethash "max" ht) v))
               (:derived-from (setf (gethash "derived-from" ht) (form-to-ast v)))))
    ht))

(defun relation-to-ht (rel-spec)
  "Convert a relation spec like (:HAS-MANY ORDERS :OF ORDER) to a hash table."
  (let ((kind (string-downcase (symbol-name (first rel-spec))))
        (name (string-downcase (symbol-name (second rel-spec))))
        (of (getf (cddr rel-spec) :of)))
    (dict "kind" kind
          "name" name
          "of" (when of (string-downcase (symbol-name of))))))

(defun derived-to-ht (derived-spec)
  "Convert (:DERIVED NAME EXPR) to a hash table."
  (dict "name" (string-downcase (symbol-name (second derived-spec)))
        "expression" (form-to-ast (third derived-spec))))

(defun entity-to-ht (plist)
  (dict "name" (string-downcase (symbol-name (getf plist :name)))
        "supers" (coerce (mapcar (lambda (s) (string-downcase (symbol-name s)))
                                 (getf plist :supers))
                         'vector)
        "fields" (coerce (mapcar #'field-to-ht (getf plist :fields)) 'vector)
        "relations" (coerce (mapcar #'relation-to-ht (getf plist :relations)) 'vector)
        "derived" (coerce (mapcar #'derived-to-ht (getf plist :derived)) 'vector)))

(defun binding-to-ast (binding)
  "Convert a rule :let binding form (VAR INIT) to a structured AST object."
  (if (consp binding)
      (dict "name" (string-downcase (symbol-name (first binding)))
            "value" (form-to-ast (second binding)))
      (dict "name" (string-downcase (symbol-name binding))
            "value" (form-to-ast nil))))

(defun ast-to-binding (ht)
  "Convert a structured AST binding object back to a CL binding form (VAR INIT)."
  (list (intern (string-upcase (gethash "name" ht)))
        (ast-to-form (gethash "value" ht))))

(defun rule-to-ht (plist)
  (let ((ht (dict "name" (string-downcase (symbol-name (getf plist :name))))))
    (when (getf plist :when)
      (setf (gethash "when" ht) (form-to-ast (getf plist :when))))
    (when (getf plist :let)
      (setf (gethash "let" ht)
            (coerce (mapcar #'binding-to-ast (getf plist :let)) 'vector)))
    (when (getf plist :requires)
      (setf (gethash "requires" ht)
            (coerce (mapcar #'form-to-ast (getf plist :requires)) 'vector)))
    (when (getf plist :sets)
      (setf (gethash "sets" ht)
            (form-to-compact-string (getf plist :sets))))
    (when (getf plist :ensures)
      (setf (gethash "ensures" ht)
            (coerce (mapcar #'form-to-ast (getf plist :ensures)) 'vector)))
    ht))

(defun invariant-to-ht (plist)
  (let ((ht (dict "name" (string-downcase (symbol-name (getf plist :name))))))
    (when (getf plist :on)
      (setf (gethash "on" ht) (string-downcase (symbol-name (getf plist :on)))))
    (when (getf plist :check)
      (setf (gethash "check" ht) (form-to-ast (getf plist :check))))
    ht))

(defun variant-to-ht (plist)
  "Convert a variant plist to a hash table for JSON serialization."
  (dict "name" (string-downcase (symbol-name (getf plist :name)))
        "parent" (getf plist :parent)
        "discriminator" (string-downcase (symbol-name (getf plist :discriminator)))
        "value" (string-downcase (symbol-name (getf plist :value)))
        "fields" (coerce (mapcar #'field-to-ht (getf plist :fields)) 'vector)))

(defun scenario-entity-to-ht (espec)
  "Convert a scenario entity spec plist to a hash table."
  (let ((ht (dict "binding" (string-downcase (symbol-name (getf espec :binding)))
                  "entity" (getf espec :entity)
                  "min" (getf espec :min)
                  "max" (getf espec :max))))
    (when (getf espec :per)
      (setf (gethash "per" ht)
            (string-downcase (symbol-name (getf espec :per)))))
    ht))

(defun scenario-to-ht (plist)
  "Convert a scenario plist to a hash table for JSON serialization."
  (dict "name" (string-downcase (symbol-name (getf plist :name)))
        "entities" (coerce (mapcar #'scenario-entity-to-ht
                                   (getf plist :entities))
                           'vector)))

(defun form-to-compact-string (form)
  "Serialize a Lisp form to a minimal string with no extra whitespace."
  (let ((*print-pretty* nil)
        (*print-right-margin* most-positive-fixnum)
        (*print-case* :downcase))
    (prin1-to-string form)))

(defun specs-to-json ()
  "Serialize all spec registries to a JSON string.
Includes generator source forms as compact s-expression strings."
  (let ((entities (dict))
        (rules (dict))
        (invariants (dict))
        (variants (dict))
        (scenarios (dict))
        (generators (dict))
        (scenario-generators (dict))
        (scenario-negative-generators (dict))
        (helpers (dict)))
    (maphash (lambda (k v) (setf (gethash k entities) (entity-to-ht v))) *entities*)
    (maphash (lambda (k v) (setf (gethash k rules) (rule-to-ht v))) *rules*)
    (maphash (lambda (k v) (setf (gethash k invariants) (invariant-to-ht v))) *invariants*)
    (maphash (lambda (k v) (setf (gethash k variants) (variant-to-ht v))) *variants*)
    (maphash (lambda (k v) (setf (gethash k scenarios) (scenario-to-ht v))) *scenarios*)
    (maphash (lambda (k v)
               (declare (ignore v))
               (let ((src (gethash k *generator-sources*)))
                 (when src
                   (setf (gethash k generators) (form-to-compact-string src)))))
             *generators*)
    (maphash (lambda (k v)
               (declare (ignore v))
               (let ((src (gethash k *scenario-generator-sources*)))
                 (when src
                   (setf (gethash k scenario-generators) (form-to-compact-string src)))))
             *scenario-generators*)
    (maphash (lambda (k v)
               (declare (ignore v))
               (let ((src (gethash k *scenario-negative-generator-sources*)))
                 (when src
                   (setf (gethash k scenario-negative-generators) (form-to-compact-string src)))))
             *scenario-negative-generators*)
    (let ((result (dict "entities" entities
                        "rules" rules
                        "invariants" invariants
                        "variants" variants
                        "scenarios" scenarios)))
      (when *config*
        (setf (gethash "config" result)
              (dict "fields" (coerce (mapcar #'field-to-ht *config*) 'vector))))
      (when (plusp (hash-table-count generators))
        (setf (gethash "generators" result) generators))
      (when (plusp (hash-table-count scenario-generators))
        (setf (gethash "scenario-generators" result) scenario-generators))
      (when (plusp (hash-table-count scenario-negative-generators))
        (setf (gethash "scenario-negative-generators" result) scenario-negative-generators))
      (maphash (lambda (k v)
                 (declare (ignore v))
                 (let ((src (gethash k *helper-sources*)))
                   (when src
                     (setf (gethash k helpers) (form-to-compact-string src)))))
               *helpers*)
      (when (plusp (hash-table-count helpers))
        (setf (gethash "helpers" result) helpers))
      (encode-json result))))

;;; ---------------------------------------------------------------------------
;;; Lisp serialization
;;; ---------------------------------------------------------------------------

(defun specs-to-lisp ()
  "Serialize all spec registries to evaluable Lisp source.
Returns a string of (defentity ...), (defrule ...), etc. forms."
  (let ((*print-pretty* t)
        (*print-right-margin* 100)
        (*print-case* :downcase)
        (out (make-string-output-stream)))
    (labels ((emit (form) (prin1 form out) (terpri out) (terpri out))
             (field-to-form (f)
               (let ((name (first f))
                     (type (second f))
                     (rest (cddr f)))
                 `(,name ,type ,@rest)))
             (relation-to-form (r) r)
             (derived-to-form (d) `(:derived ,(second d) ,(third d))))
      ;; Helpers first — everything else may reference them
      (maphash (lambda (k v)
                 (declare (ignore k v))
                 nil)
               *helper-sources*)
      (let ((helper-forms nil))
        (maphash (lambda (k v)
                   (declare (ignore k))
                   (push v helper-forms))
                 *helper-sources*)
        (dolist (form (nreverse helper-forms))
          (emit form)))
      ;; Entities
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (let ((name (getf v :name))
                       (supers (getf v :supers))
                       (fields (mapcar #'field-to-form (getf v :fields)))
                       (relations (mapcar #'relation-to-form (getf v :relations)))
                       (derived (mapcar #'derived-to-form (getf v :derived))))
                   (emit `(defentity ,name (,@supers) ,@fields ,@relations ,@derived))))
               *entities*)
      ;; Config
      (when *config*
        (emit `(defconfig ,@(mapcar #'field-to-form *config*))))
      ;; Variants
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (let ((name (getf v :name))
                       (parent (getf v :parent))
                       (disc (getf v :discriminator))
                       (val (getf v :value))
                       (fields (mapcar #'field-to-form (getf v :fields))))
                   (emit `(defvariant ,name (,(intern (string-upcase parent)) ,disc ,val) ,@fields))))
               *variants*)
      ;; Rules
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (let ((form `(defrule ,(getf v :name))))
                   (when (getf v :when) (setf form (append form `(:when ,(getf v :when)))))
                   (when (getf v :let) (setf form (append form `(:let ,(getf v :let)))))
                   (when (getf v :requires) (setf form (append form `(:requires ,(getf v :requires)))))
                   (when (getf v :sets) (setf form (append form `(:sets ,(getf v :sets)))))
                   (when (getf v :ensures) (setf form (append form `(:ensures ,(getf v :ensures)))))
                   (emit form)))
               *rules*)
      ;; Invariants (non-scenario)
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (let ((on-name (string-downcase (symbol-name (getf v :on)))))
                   (unless (gethash on-name *scenarios*)
                     (emit `(definvariant ,(getf v :name)
                              :on ,(getf v :on)
                              :check ,(getf v :check))))))
               *invariants*)
      ;; Scenarios
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (let ((name (getf v :name))
                       (entities (mapcar (lambda (e)
                                           (let ((binding (intern (string (getf e :binding))))
                                                 (entity (intern (string-upcase (getf e :entity))))
                                                 (mn (getf e :min))
                                                 (mx (getf e :max))
                                                 (per (getf e :per)))
                                             (let ((card (if (= mn mx) mn `(,mn ,mx)))
                                                   (base `(,binding ,nil ,entity)))
                                               (setf (second base) card)
                                               (when per
                                                 (setf base (append base `(:per ,(intern (string per))))))
                                               base)))
                                         (getf v :entities))))
                   (emit `(defscenario ,name :entities ,entities))))
               *scenarios*)
      ;; Scenario invariants
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (let ((on-name (string-downcase (symbol-name (getf v :on)))))
                   (when (gethash on-name *scenarios*)
                     (emit `(definvariant ,(getf v :name)
                              :on ,(getf v :on)
                              :check ,(getf v :check))))))
               *invariants*)
      ;; Generators
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (emit v))
               *generator-sources*)
      ;; Scenario generators
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (emit v))
               *scenario-generator-sources*)
      ;; Scenario negative generators
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (emit v))
               *scenario-negative-generator-sources*))
    (get-output-stream-string out)))

;;; ---------------------------------------------------------------------------
;;; S-expression data serialization
;;; ---------------------------------------------------------------------------

(defun specs-to-data ()
  "Serialize all spec registries to a plist suitable for PRINT/READ round-trip.
No code execution needed on load — use DATA-TO-SPECS to reconstruct."
  (let ((entities nil) (rules nil) (invariants nil) (variants nil)
        (scenarios nil) (generators nil) (scenario-generators nil)
        (scenario-negative-generators nil) (helpers nil))
    (maphash (lambda (k v) (push (cons k v) entities)) *entities*)
    (maphash (lambda (k v) (push (cons k v) rules)) *rules*)
    (maphash (lambda (k v) (push (cons k v) invariants)) *invariants*)
    (maphash (lambda (k v) (push (cons k v) variants)) *variants*)
    (maphash (lambda (k v) (push (cons k v) scenarios)) *scenarios*)
    (maphash (lambda (k v)
               (declare (ignore v))
               (let ((src (gethash k *generator-sources*)))
                 (when src (push (cons k src) generators))))
             *generators*)
    (maphash (lambda (k v)
               (declare (ignore v))
               (let ((src (gethash k *scenario-generator-sources*)))
                 (when src (push (cons k src) scenario-generators))))
             *scenario-generators*)
    (maphash (lambda (k v)
               (declare (ignore v))
               (let ((src (gethash k *scenario-negative-generator-sources*)))
                 (when src (push (cons k src) scenario-negative-generators))))
             *scenario-negative-generators*)
    (maphash (lambda (k v)
               (declare (ignore v))
               (let ((src (gethash k *helper-sources*)))
                 (when src (push (cons k src) helpers))))
             *helpers*)
    (list :entities entities :rules rules :invariants invariants
          :variants variants :scenarios scenarios
          :config *config*
          :generators generators :scenario-generators scenario-generators
          :scenario-negative-generators scenario-negative-generators
          :helpers helpers)))

(defun data-to-specs (data)
  "Reconstruct spec registries from a plist produced by SPECS-TO-DATA.
Uses EVAL only for generator/helper source forms (which are defmacro calls)."
  ;; Helpers first — generators may reference them
  (dolist (entry (getf data :helpers))
    (eval (cdr entry)))
  ;; Entities
  (dolist (entry (getf data :entities))
    (setf (gethash (car entry) *entities*) (cdr entry)))
  ;; Rules
  (dolist (entry (getf data :rules))
    (setf (gethash (car entry) *rules*) (cdr entry)))
  ;; Invariants
  (dolist (entry (getf data :invariants))
    (setf (gethash (car entry) *invariants*) (cdr entry)))
  ;; Variants
  (dolist (entry (getf data :variants))
    (setf (gethash (car entry) *variants*) (cdr entry)))
  ;; Scenarios
  (dolist (entry (getf data :scenarios))
    (setf (gethash (car entry) *scenarios*) (cdr entry)))
  ;; Config
  (setf *config* (getf data :config))
  ;; Generators — must eval source forms
  (dolist (entry (getf data :generators))
    (eval (cdr entry)))
  ;; Scenario generators
  (dolist (entry (getf data :scenario-generators))
    (eval (cdr entry)))
  ;; Scenario negative generators
  (dolist (entry (getf data :scenario-negative-generators))
    (eval (cdr entry)))
  (clrhash *compiled-fn-cache*)
  (values))

(defun write-specs (pathname)
  "Write specs to PATHNAME as readable s-expression data."
  (with-open-file (out pathname :direction :output :if-exists :supersede)
    (let ((*print-pretty* t)
          (*print-right-margin* 100)
          (*print-case* :downcase)
          (*print-circle* nil))
      (prin1 (specs-to-data) out)
      (terpri out)))
  pathname)

(defun read-specs (pathname)
  "Read specs from PATHNAME (written by WRITE-SPECS). Merges into current registries."
  (let ((data (with-open-file (in pathname)
                (let ((*read-eval* nil))
                  (read in)))))
    (data-to-specs data)))

;;; ---------------------------------------------------------------------------
;;; JSON deserialization
;;; ---------------------------------------------------------------------------

(defun ht-to-field (ht)
  "Convert a JSON field hash table back to a field spec list."
  (let* ((name (intern (string-upcase (gethash "name" ht))))
         (type (read-from-string (gethash "type" ht)))
         (spec (list name type)))
    (when (gethash "required" ht)
      (setf spec (append spec (list :required t))))
    (when (gethash "default" ht)
      (setf spec (append spec (list :default (read-from-string (gethash "default" ht))))))
    (when (gethash "unique" ht)
      (setf spec (append spec (list :unique t))))
    (when (gethash "min" ht)
      (setf spec (append spec (list :min (gethash "min" ht)))))
    (when (gethash "max" ht)
      (setf spec (append spec (list :max (gethash "max" ht)))))
    (when (gethash "derived-from" ht)
      (setf spec (append spec (list :derived-from (ast-to-form (gethash "derived-from" ht))))))
    spec))

(defun ht-to-relation (ht)
  "Convert a JSON relation hash table back to a relation spec list."
  (let ((kind (intern (string-upcase (gethash "kind" ht)) :keyword))
        (name (intern (string-upcase (gethash "name" ht))))
        (of (gethash "of" ht)))
    (list kind name :of (when of (intern (string-upcase of))))))

(defun ht-to-derived (ht)
  "Convert a JSON derived hash table back to a derived spec list."
  (list :derived
        (intern (string-upcase (gethash "name" ht)))
        (ast-to-form (gethash "expression" ht))))

(defun json-to-specs (json-string)
  "Import specs from a JSON string, populating the registries.
Merges with existing specs — call CLEAR-SPECS first for a clean import."
  (let ((data (decode-json json-string)))
    ;; Entities
    (let ((entities (gethash "entities" data)))
      (when entities
        (maphash
         (lambda (key ht)
           (setf (gethash key *entities*)
                 (list :name (intern (string-upcase (gethash "name" ht)))
                       :supers (map 'list (lambda (s) (intern (string-upcase s)))
                                    (or (gethash "supers" ht) #()))
                       :fields (map 'list #'ht-to-field
                                    (or (gethash "fields" ht) #()))
                       :relations (map 'list #'ht-to-relation
                                       (or (gethash "relations" ht) #()))
                       :derived (map 'list #'ht-to-derived
                                     (or (gethash "derived" ht) #())))))
         entities)))
    ;; Rules
    (let ((rules (gethash "rules" data)))
      (when rules
        (maphash
         (lambda (key ht)
           (setf (gethash key *rules*)
                 (list :name (intern (string-upcase (gethash "name" ht)))
                       :when (when (gethash "when" ht)
                               (ast-to-form (gethash "when" ht)))
                       :let (when (gethash "let" ht)
                              (map 'list #'ast-to-binding (gethash "let" ht)))
                       :requires (when (gethash "requires" ht)
                                   (map 'list #'ast-to-form (gethash "requires" ht)))
                       :sets (when (gethash "sets" ht)
                               (read-from-string (gethash "sets" ht)))
                       :ensures (when (gethash "ensures" ht)
                                  (map 'list #'ast-to-form (gethash "ensures" ht))))))
         rules)))
    ;; Invariants
    (let ((invariants (gethash "invariants" data)))
      (when invariants
        (maphash
         (lambda (key ht)
           (setf (gethash key *invariants*)
                 (list :name (intern (string-upcase (gethash "name" ht)))
                       :on (when (gethash "on" ht)
                             (intern (string-upcase (gethash "on" ht))))
                       :check (when (gethash "check" ht)
                                (ast-to-form (gethash "check" ht))))))
         invariants)))
    ;; Variants
    (let ((variants (gethash "variants" data)))
      (when variants
        (maphash
         (lambda (key ht)
           (setf (gethash key *variants*)
                 (list :name (intern (string-upcase (gethash "name" ht)))
                       :parent (gethash "parent" ht)
                       :discriminator (intern (string-upcase (gethash "discriminator" ht))
                                              :keyword)
                       :value (intern (string-upcase (gethash "value" ht)) :keyword)
                       :fields (map 'list #'ht-to-field
                                    (or (gethash "fields" ht) #())))))
         variants)))
    ;; Config
    (let ((config-ht (gethash "config" data)))
      (when config-ht
        (setf *config*
              (map 'list #'ht-to-field
                   (or (gethash "fields" config-ht) #())))))
    ;; Scenarios
    (let ((scenarios (gethash "scenarios" data)))
      (when scenarios
        (maphash
         (lambda (key ht)
           (setf (gethash key *scenarios*)
                 (list :name (intern (string-upcase (gethash "name" ht)))
                       :entities
                       (map 'list
                            (lambda (eht)
                              (let ((per (gethash "per" eht)))
                                (list :binding (intern (string-upcase (gethash "binding" eht))
                                                       :keyword)
                                      :entity (gethash "entity" eht)
                                      :min (gethash "min" eht)
                                      :max (gethash "max" eht)
                                      :per (when per
                                             (intern (string-upcase per) :keyword)))))
                            (or (gethash "entities" ht) #())))))
         scenarios)))
    ;; Helpers first — generators/invariants may reference them
    (let ((helpers-ht (gethash "helpers" data)))
      (when helpers-ht
        (maphash (lambda (key src-string)
                   (declare (ignore key))
                   (eval (read-from-string src-string)))
                 helpers-ht)))
    ;; Generators — eval stringified source forms
    (let ((gens (gethash "generators" data)))
      (when gens
        (maphash (lambda (key src-string)
                   (declare (ignore key))
                   (eval (read-from-string src-string)))
                 gens)))
    (let ((sgens (gethash "scenario-generators" data)))
      (when sgens
        (maphash (lambda (key src-string)
                   (declare (ignore key))
                   (eval (read-from-string src-string)))
                 sgens)))
    (let ((sngens (gethash "scenario-negative-generators" data)))
      (when sngens
        (maphash (lambda (key src-string)
                   (declare (ignore key))
                   (eval (read-from-string src-string)))
                 sngens)))
    (clrhash *compiled-fn-cache*)
    (values)))

;;; ---------------------------------------------------------------------------
;;; JSON Schema
;;; ---------------------------------------------------------------------------

(defun expr-schema-ref ()
  "Return a $ref to the expression schema."
  (dict "$ref" "#/$defs/expr"))

(defun binding-schema ()
  "Return the JSON Schema for a let-binding."
  (dict "type" "object"
        "required" (vector "name" "value")
        "properties"
        (dict "name" (dict "type" "string")
              "value" (expr-schema-ref))))

(defun expr-node-schemas ()
  "Return a hash table of AST node type schemas keyed by node name."
  (dict
   "literal"
   (dict "type" "object"
         "required" (vector "node")
         "properties"
         (dict "node" (dict "const" "literal")
               "value" (dict "description" "Atomic value: number, string, boolean, or null")))
   "keyword"
   (dict "type" "object"
         "required" (vector "node" "name")
         "properties"
         (dict "node" (dict "const" "keyword")
               "name" (dict "type" "string" "description" "Keyword name without colon prefix")))
   "var"
   (dict "type" "object"
         "required" (vector "node" "name")
         "properties"
         (dict "node" (dict "const" "var")
               "name" (dict "type" "string" "description" "Variable name")))
   "field"
   (dict "type" "object"
         "required" (vector "node" "object" "field")
         "properties"
         (dict "node" (dict "const" "field")
               "object" (expr-schema-ref)
               "field" (dict "type" "string" "description" "Field name on the entity")))
   "compare"
   (dict "type" "object"
         "required" (vector "node" "op" "left" "right")
         "properties"
         (dict "node" (dict "const" "compare")
               "op" (dict "type" "string" "enum" (vector ">=" "<=" ">" "<" "="))
               "left" (expr-schema-ref)
               "right" (expr-schema-ref)))
   "eq"
   (dict "type" "object"
         "required" (vector "node" "left" "right")
         "properties"
         (dict "node" (dict "const" "eq")
               "left" (expr-schema-ref)
               "right" (expr-schema-ref)))
   "and"
   (dict "type" "object"
         "required" (vector "node" "args")
         "properties"
         (dict "node" (dict "const" "and")
               "args" (dict "type" "array" "items" (expr-schema-ref))))
   "or"
   (dict "type" "object"
         "required" (vector "node" "args")
         "properties"
         (dict "node" (dict "const" "or")
               "args" (dict "type" "array" "items" (expr-schema-ref))))
   "not"
   (dict "type" "object"
         "required" (vector "node" "arg")
         "properties"
         (dict "node" (dict "const" "not")
               "arg" (expr-schema-ref)))
   "if"
   (dict "type" "object"
         "required" (vector "node" "test" "then" "else")
         "properties"
         (dict "node" (dict "const" "if")
               "test" (expr-schema-ref)
               "then" (expr-schema-ref)
               "else" (expr-schema-ref)))
   "member"
   (dict "type" "object"
         "required" (vector "node" "value" "set")
         "properties"
         (dict "node" (dict "const" "member")
               "value" (expr-schema-ref)
               "set" (dict "type" "array" "items" (expr-schema-ref))))
   "lambda"
   (dict "type" "object"
         "required" (vector "node" "params" "body")
         "properties"
         (dict "node" (dict "const" "lambda")
               "params" (dict "type" "array" "items" (dict "type" "string"))
               "body" (expr-schema-ref)))
   "let"
   (dict "type" "object"
         "required" (vector "node" "bindings" "body")
         "properties"
         (dict "node" (dict "const" "let")
               "bindings" (dict "type" "array" "items" (binding-schema))
               "body" (expr-schema-ref)))
   "call"
   (dict "type" "object"
         "required" (vector "node" "fn" "args")
         "properties"
         (dict "node" (dict "const" "call")
               "fn" (dict "type" "string" "description" "Function name")
               "args" (dict "type" "array" "items" (expr-schema-ref))))))

(defun spec-json-schema ()
  "Return the JSON Schema for the behavioral spec format as a hash table."
  (let* ((node-schemas (expr-node-schemas))
         (one-of (coerce (loop for v being the hash-values of node-schemas
                               collect v)
                         'vector))
         (expr-schema (dict "oneOf" one-of
                            "discriminator" (dict "propertyName" "node")))
         (field-schema
           (dict "type" "object"
                 "required" (vector "name" "type")
                 "properties"
                 (dict "name" (dict "type" "string")
                       "type" (dict "type" "string"
                                    "description" "Type specifier")
                       "required" (dict "type" "boolean")
                       "default" (dict "type" "string"
                                       "description" "Default value as string")
                       "unique" (dict "type" "boolean")
                       "min" (dict "type" "number"
                                   "description" "Minimum value for generator")
                       "max" (dict "type" "number"
                                   "description" "Maximum value for generator")
                       "derived-from" (dict "$ref" "#/$defs/expr"
                                            "description" "Expression to compute from other fields"))))
         (relation-schema
           (dict "type" "object"
                 "required" (vector "kind" "name" "of")
                 "properties"
                 (dict "kind" (dict "type" "string"
                                    "enum" (vector "has-many" "has-one" "belongs-to"))
                       "name" (dict "type" "string")
                       "of" (dict "type" "string"
                                  "description" "Target entity name"))))
         (derived-schema
           (dict "type" "object"
                 "required" (vector "name" "expression")
                 "properties"
                 (dict "name" (dict "type" "string")
                       "expression" (dict "$ref" "#/$defs/expr"
                                          "description" "Expression AST")))))
    (dict
     "$schema" "https://json-schema.org/draft/2020-12/schema"
     "title" "Behavioral Specification"
     "type" "object"
     "$defs" (dict "expr" expr-schema
                   "binding" (binding-schema))
     "properties"
     (dict
      "entities"
      (dict "type" "object"
            "additionalProperties"
            (dict "type" "object"
                  "required" (vector "name")
                  "properties"
                  (dict "name" (dict "type" "string")
                        "supers" (dict "type" "array"
                                       "items" (dict "type" "string"))
                        "fields" (dict "type" "array" "items" field-schema)
                        "relations" (dict "type" "array" "items" relation-schema)
                        "derived" (dict "type" "array" "items" derived-schema))))
      "rules"
      (dict "type" "object"
            "additionalProperties"
            (dict "type" "object"
                  "required" (vector "name")
                  "properties"
                  (dict "name" (dict "type" "string")
                        "when" (dict "$ref" "#/$defs/expr"
                                     "description" "Trigger condition")
                        "let" (dict "type" "array"
                                    "items" (dict "$ref" "#/$defs/binding")
                                    "description" "Variable bindings")
                        "requires" (dict "type" "array"
                                         "items" (dict "$ref" "#/$defs/expr")
                                         "description" "Preconditions")
                        "ensures" (dict "type" "array"
                                        "items" (dict "$ref" "#/$defs/expr")
                                        "description" "Postconditions"))))
      "invariants"
      (dict "type" "object"
            "additionalProperties"
            (dict "type" "object"
                  "required" (vector "name")
                  "properties"
                  (dict "name" (dict "type" "string")
                        "on" (dict "type" "string"
                                   "description" "Entity this invariant applies to")
                        "check" (dict "$ref" "#/$defs/expr"
                                      "description" "Predicate expression"))))
      "variants"
      (dict "type" "object"
            "additionalProperties"
            (dict "type" "object"
                  "required" (vector "name" "parent" "discriminator" "value")
                  "properties"
                  (dict "name" (dict "type" "string")
                        "parent" (dict "type" "string"
                                       "description" "Parent entity name")
                        "discriminator" (dict "type" "string"
                                              "description" "Field that selects this variant")
                        "value" (dict "type" "string"
                                      "description" "Discriminator value for this variant")
                        "fields" (dict "type" "array" "items" field-schema))))
      "config"
      (dict "type" "object"
            "properties"
            (dict "fields" (dict "type" "array" "items" field-schema)))))))
