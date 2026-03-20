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
           ;; Macros
           #:defentity
           #:defrule
           #:definvariant
           ;; Introspection
           #:list-entities
           #:describe-entity
           #:entity-fields
           #:entity-relations
           #:list-rules
           #:describe-rule
           #:list-invariants
           #:describe-invariant
           ;; Utilities
           #:clear-specs
           #:validate-specs
           ;; JSON
           #:specs-to-json
           #:json-to-specs
           #:spec-json-schema))

(in-package #:mcp-lisp/src/spec/spec)

;;; ---------------------------------------------------------------------------
;;; Registries
;;; ---------------------------------------------------------------------------

(defvar *entities* (make-hash-table :test #'equal))
(defvar *rules* (make-hash-table :test #'equal))
(defvar *invariants* (make-hash-table :test #'equal))

;;; ---------------------------------------------------------------------------
;;; Known keywords for validation at macroexpand time
;;; ---------------------------------------------------------------------------

(defparameter +known-field-keys+ '(:required :default :unique :min :max :derived-from))
(defparameter +relation-types+ '(:has-many :has-one :belongs-to))

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
         ',name))))

;;; ---------------------------------------------------------------------------
;;; defrule
;;; ---------------------------------------------------------------------------

(defmacro defrule (name &key when let requires ensures)
  "Define a behavioral rule. Metadata-only — nothing is compiled or executed.

  (defrule place-order
    :when (order :state :draft)
    :let ((customer (order-customer order)))
    :requires ((active-account-p customer)
               (pos (account-balance customer)))
    :ensures ((eq (order-state order) :placed)
              (order-placed-at order)))"
  (let ((key (string-downcase (string name))))
    `(progn
       (setf (gethash ,key *rules*)
             (list :name ',name
                   :when ',when
                   :let ',let
                   :requires ',requires
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
       ',name)))

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

;;; ---------------------------------------------------------------------------
;;; Utilities
;;; ---------------------------------------------------------------------------

(defun clear-specs ()
  "Reset all spec registries."
  (clrhash *entities*)
  (clrhash *rules*)
  (clrhash *invariants*)
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

(defun collect-called-symbols (form)
  "Walk FORM and collect every symbol that appears in function-call position."
  (let ((syms nil))
    (labels ((walk (f)
               (when (consp f)
                 (let ((head (car f)))
                   (cond
                     ;; (quote ...) — skip entirely
                     ((eq head 'quote) nil)
                     ;; (lambda ...) — walk body, skip params
                     ((eq head 'lambda)
                      (dolist (body-form (cddr f))
                        (walk body-form)))
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
                      ((eq head 'lambda)
                       ;; bind params, walk body
                       (let ((params (remove-if (lambda (s) (member s '(&optional &rest &key &body)))
                                                (second f))))
                         (dolist (body-form (cddr f))
                           (walk body-form (append params env)))))
                      ((member head '(let let*))
                       ;; walk init forms, then body with bindings
                       (let ((bindings (second f))
                             (new-env env))
                         (dolist (b bindings)
                           (let ((var (if (consp b) (car b) b))
                                 (init (when (consp b) (second b))))
                             (when init (walk init (if (eq head 'let*) new-env env)))
                             (push var new-env)))
                         (dolist (body-form (cddr f))
                           (walk body-form new-env))))
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
  "Check that all rules/invariants reference known entities and that
forms in :check/:requires/:ensures/:let use resolvable symbols.
Returns a list of warning strings. Empty list = all clear."
  (let ((entity-keys (loop for k being the hash-keys of *entities* collect k))
        (warnings nil))
    (flet ((known-entity-p (sym)
             (member (string-downcase (string sym)) entity-keys :test #'string=)))
      ;; Check rules — :when car should name an entity
      (maphash (lambda (key plist)
                 (let ((when-clause (getf plist :when)))
                   (when (and when-clause (symbolp (car when-clause)))
                     (unless (known-entity-p (car when-clause))
                       (push (format nil "rule ~A: :when references unknown entity ~A"
                                     key (car when-clause))
                             warnings)))))
               *rules*)
      ;; Check invariants — :on should name an entity
      (maphash (lambda (key plist)
                 (let ((on (getf plist :on)))
                   (when on
                     (unless (known-entity-p on)
                       (push (format nil "invariant ~A: :on references unknown entity ~A"
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
                     (setf warnings
                           (check-form-free-variables
                            (getf plist :check)
                            (list (getf plist :on))
                            (format nil "invariant ~A" key)
                            warnings)))))
               *invariants*)
      ;; Check forms in rule :requires, :ensures, and :let clauses
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
                 (dolist (binding (getf plist :let))
                   (when (and (consp binding) (second binding))
                     (setf warnings
                           (check-form-symbols (second binding)
                                               (format nil "rule ~A :let" key)
                                               warnings)))))
               *rules*))
    (nreverse warnings)))

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
               (:derived-from (setf (gethash "derived-from" ht) (form-to-string v)))))
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
        "expression" (form-to-string (third derived-spec))))

(defun entity-to-ht (plist)
  (dict "name" (string-downcase (symbol-name (getf plist :name)))
        "supers" (coerce (mapcar (lambda (s) (string-downcase (symbol-name s)))
                                 (getf plist :supers))
                         'vector)
        "fields" (coerce (mapcar #'field-to-ht (getf plist :fields)) 'vector)
        "relations" (coerce (mapcar #'relation-to-ht (getf plist :relations)) 'vector)
        "derived" (coerce (mapcar #'derived-to-ht (getf plist :derived)) 'vector)))

(defun rule-to-ht (plist)
  (let ((ht (dict "name" (string-downcase (symbol-name (getf plist :name))))))
    (when (getf plist :when)
      (setf (gethash "when" ht) (form-to-string (getf plist :when))))
    (when (getf plist :let)
      (setf (gethash "let" ht)
            (coerce (mapcar #'form-to-string (getf plist :let)) 'vector)))
    (when (getf plist :requires)
      (setf (gethash "requires" ht)
            (coerce (mapcar #'form-to-string (getf plist :requires)) 'vector)))
    (when (getf plist :ensures)
      (setf (gethash "ensures" ht)
            (coerce (mapcar #'form-to-string (getf plist :ensures)) 'vector)))
    ht))

(defun invariant-to-ht (plist)
  (let ((ht (dict "name" (string-downcase (symbol-name (getf plist :name))))))
    (when (getf plist :on)
      (setf (gethash "on" ht) (string-downcase (symbol-name (getf plist :on)))))
    (when (getf plist :check)
      (setf (gethash "check" ht) (form-to-string (getf plist :check))))
    ht))

(defun specs-to-json ()
  "Serialize all spec registries to a JSON string."
  (let ((entities (dict))
        (rules (dict))
        (invariants (dict)))
    (maphash (lambda (k v) (setf (gethash k entities) (entity-to-ht v))) *entities*)
    (maphash (lambda (k v) (setf (gethash k rules) (rule-to-ht v))) *rules*)
    (maphash (lambda (k v) (setf (gethash k invariants) (invariant-to-ht v))) *invariants*)
    (encode-json (dict "entities" entities
                       "rules" rules
                       "invariants" invariants))))

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
      (setf spec (append spec (list :derived-from (read-from-string (gethash "derived-from" ht))))))
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
        (read-from-string (gethash "expression" ht))))

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
                               (read-from-string (gethash "when" ht)))
                       :let (when (gethash "let" ht)
                              (map 'list #'read-from-string (gethash "let" ht)))
                       :requires (when (gethash "requires" ht)
                                   (map 'list #'read-from-string (gethash "requires" ht)))
                       :ensures (when (gethash "ensures" ht)
                                  (map 'list #'read-from-string (gethash "ensures" ht))))))
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
                                (read-from-string (gethash "check" ht))))))
         invariants)))
    (values)))

;;; ---------------------------------------------------------------------------
;;; JSON Schema
;;; ---------------------------------------------------------------------------

(defun spec-json-schema ()
  "Return the JSON Schema for the behavioral spec format as a hash table."
  (let ((field-schema
          (dict "type" "object"
                "required" (vector "name" "type")
                "properties"
                (dict "name" (dict "type" "string")
                      "type" (dict "type" "string"
                                   "description" "CL type specifier")
                      "required" (dict "type" "boolean")
                      "default" (dict "type" "string"
                                      "description" "Default value as CL form")
                      "unique" (dict "type" "boolean")
                      "min" (dict "type" "number"
                                  "description" "Minimum value for generator")
                      "max" (dict "type" "number"
                                  "description" "Maximum value for generator")
                      "derived-from" (dict "type" "string"
                                           "description" "CL form to compute from other fields"))))
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
                      "expression" (dict "type" "string"
                                         "description" "CL lambda form")))))
    (dict
     "$schema" "https://json-schema.org/draft/2020-12/schema"
     "title" "Behavioral Specification"
     "type" "object"
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
                        "when" (dict "type" "string"
                                     "description" "Trigger condition as CL form")
                        "let" (dict "type" "array"
                                    "items" (dict "type" "string")
                                    "description" "Binding forms")
                        "requires" (dict "type" "array"
                                         "items" (dict "type" "string")
                                         "description" "Precondition forms")
                        "ensures" (dict "type" "array"
                                        "items" (dict "type" "string")
                                        "description" "Postcondition forms"))))
      "invariants"
      (dict "type" "object"
            "additionalProperties"
            (dict "type" "object"
                  "required" (vector "name")
                  "properties"
                  (dict "name" (dict "type" "string")
                        "on" (dict "type" "string"
                                   "description" "Entity this invariant applies to")
                        "check" (dict "type" "string"
                                      "description" "Predicate as CL form"))))))))
