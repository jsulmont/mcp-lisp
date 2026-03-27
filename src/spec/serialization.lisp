;;;; src/spec/serialization.lisp
;;;;
;;;; Serialization / deserialization for behavioral specs:
;;;; JSON, Lisp source, and s-expression data formats.

(defpackage #:mcp-lisp/src/spec/serialization
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:dict
                #:encode-json
                #:decode-json)
  (:import-from #:mcp-lisp/src/spec/registry
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
                #:*helpers*
                #:*helper-sources*
                #:*valuesets*
                #:*requirements*)
  (:import-from #:mcp-lisp/src/spec/introspection
                #:entity-accessor-p
                #:decompose-accessor
                #:describe-entity
                #:describe-scenario
                #:entity-fields
                #:entity-relations
                #:entity-variants
                #:describe-variant
                #:list-scenarios)
  (:export #:form-to-string
           #:form-to-ast
           #:ast-to-form
           #:specs-to-json
           #:json-to-specs
           #:spec-json-schema
           #:specs-to-lisp
           #:specs-to-data
           #:data-to-specs
           #:write-specs
           #:read-specs
           #:form-to-compact-string))

(in-package #:mcp-lisp/src/spec/serialization)

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
the function is already defined. Checks the CL package, the PBT package,
and the helpers package before falling back to *PACKAGE*."
  (let ((uname (string-upcase name-string)))
    (or (multiple-value-bind (sym status) (find-symbol uname :cl)
          (when (and status (fboundp sym)) sym))
        (let ((pbt-pkg (find-package '#:mcp-lisp/src/spec/pbt)))
          (when pbt-pkg
            (multiple-value-bind (sym status) (find-symbol uname pbt-pkg)
              (when (and status (fboundp sym)) sym))))
        (let ((helpers-pkg (find-package '#:mcp-lisp/src/spec/helpers)))
          (when helpers-pkg
            (multiple-value-bind (sym status) (find-symbol uname helpers-pkg)
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
               (:derived-from (setf (gethash "derived-from" ht) (form-to-ast v)))
               (:immutable    (when v (setf (gethash "immutable" ht) t)))
               (:nullable     (when v (setf (gethash "nullable" ht) t)))))
    ht))

(defun relation-to-ht (rel-spec)
  "Convert a relation spec like (:HAS-MANY ORDERS :OF ORDER) to a hash table."
  (let ((kind (string-downcase (symbol-name (first rel-spec))))
        (name (string-downcase (symbol-name (second rel-spec))))
        (of (getf (cddr rel-spec) :of))
        (card (getf (cddr rel-spec) :cardinality)))
    (let ((ht (dict "kind" kind
                    "name" name
                    "of" (when of (string-downcase (symbol-name of))))))
      (when card
        (setf (gethash "cardinality" ht)
              (coerce card 'vector)))
      ht)))

(defun derived-to-ht (derived-spec)
  "Convert (:DERIVED NAME EXPR) to a hash table."
  (dict "name" (string-downcase (symbol-name (second derived-spec)))
        "expression" (form-to-ast (third derived-spec))))

(defun entity-to-ht (plist)
  (let ((ht (dict "name" (string-downcase (symbol-name (getf plist :name)))
                  "supers" (coerce (mapcar (lambda (s) (string-downcase (symbol-name s)))
                                           (getf plist :supers))
                                   'vector)
                  "fields" (coerce (mapcar #'field-to-ht (getf plist :fields)) 'vector)
                  "relations" (coerce (mapcar #'relation-to-ht (getf plist :relations)) 'vector)
                  "derived" (coerce (mapcar #'derived-to-ht (getf plist :derived)) 'vector))))
    (when (getf plist :constraints)
      (setf (gethash "constraints" ht)
            (coerce (mapcar (lambda (c)
                              (coerce (mapcar (lambda (s) (string-downcase (symbol-name s))) c)
                                      'vector))
                            (getf plist :constraints))
                    'vector)))
    ht))

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
    (when (getf plist :reqs)
      (setf (gethash "reqs" ht) (coerce (getf plist :reqs) 'vector)))
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
    (when (getf espec :singular)
      (setf (gethash "singular" ht) t))
    (when (getf espec :refs)
      (setf (gethash "refs" ht)
            (coerce (mapcar (lambda (ref)
                              (dict "local-field" (string-downcase (symbol-name (getf ref :local-field)))
                                    "from" (string-downcase (symbol-name (getf ref :from)))
                                    "field" (string-downcase (symbol-name (getf ref :field)))))
                            (getf espec :refs))
                    'vector)))
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
      ;; Valuesets
      (maphash (lambda (k _v)
                 (declare (ignore _v))
                 (let ((name (intern (string-upcase k)))
                       (values (gethash k *valuesets*)))
                   (emit `(defvalueset ,name ,values))))
               *valuesets*)
      ;; Requirements
      (maphash (lambda (k _v)
                 (declare (ignore _v))
                 (let ((plist (gethash k *requirements*)))
                   (let ((form `(defreq ,(string (getf plist :id))
                                  ,(getf plist :description))))
                     (when (getf plist :category)
                       (setf form (append form `(:category ,(getf plist :category)))))
                     (when (getf plist :status)
                       (setf form (append form `(:status ,(getf plist :status)))))
                     (when (getf plist :notes)
                       (setf form (append form `(:notes ,(getf plist :notes)))))
                     (emit form))))
               *requirements*)
      ;; Entities
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (let ((name (getf v :name))
                       (supers (getf v :supers))
                       (fields (mapcar #'field-to-form (getf v :fields)))
                       (relations (mapcar #'relation-to-form (getf v :relations)))
                       (derived (mapcar #'derived-to-form (getf v :derived)))
                       (constraints (mapcar (lambda (c) `(:unique-together ,@c))
                                            (getf v :constraints))))
                   (emit `(defentity ,name (,@supers) ,@fields ,@relations ,@constraints ,@derived))))
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
                   (when (getf v :reqs) (setf form (append form `(:reqs ,(getf v :reqs)))))
                   (emit form)))
               *rules*)
      ;; Invariants (non-scenario)
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (let ((on-name (string-downcase (symbol-name (getf v :on)))))
                   (unless (gethash on-name *scenarios*)
                     (let ((form `(definvariant ,(getf v :name)
                                    :on ,(getf v :on)
                                    ,@(when (getf v :reqs)
                                        `(:reqs ,(getf v :reqs)))
                                    :check ,(getf v :check))))
                       (emit form)))))
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
                                                 (per (getf e :per))
                                                 (refs (getf e :refs)))
                                             (let* ((singular (getf e :singular))
                                                   (card (cond (singular mn)
                                                               ((= mn mx) `(,mn ,mx))
                                                               (t `(,mn ,mx))))
                                                   (base `(,binding ,nil ,entity)))
                                               (setf (second base) card)
                                               (when per
                                                 (setf base (append base `(:per ,(intern (string per))))))
                                               (when refs
                                                 (setf base (append base
                                                                    `(:refs ,(mapcar (lambda (r)
                                                                                       (list (intern (string (getf r :local-field)))
                                                                                             :from (intern (string (getf r :from)))
                                                                                             :field (intern (string (getf r :field)))))
                                                                                     refs)))))
                                               base)))
                                         (getf v :entities))))
                   (emit `(defscenario ,name :entities ,entities))))
               *scenarios*)
      ;; Scenario invariants
      (maphash (lambda (k v)
                 (declare (ignore k))
                 (let ((on-name (string-downcase (symbol-name (getf v :on)))))
                   (when (gethash on-name *scenarios*)
                     (let ((form `(definvariant ,(getf v :name)
                                    :on ,(getf v :on)
                                    ,@(when (getf v :reqs)
                                        `(:reqs ,(getf v :reqs)))
                                    :check ,(getf v :check))))
                       (emit form)))))
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
    (when (gethash "immutable" ht)
      (setf spec (append spec (list :immutable t))))
    spec))

(defun ht-to-relation (ht)
  "Convert a JSON relation hash table back to a relation spec list."
  (let ((kind (intern (string-upcase (gethash "kind" ht)) :keyword))
        (name (intern (string-upcase (gethash "name" ht))))
        (of (gethash "of" ht))
        (card (gethash "cardinality" ht)))
    (let ((rel (list kind name :of (when of (intern (string-upcase of))))))
      (when card
        (setf rel (append rel (list :cardinality (coerce card 'list)))))
      rel)))

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
           (let ((inv (list :name (intern (string-upcase (gethash "name" ht)))
                           :on (when (gethash "on" ht)
                                 (intern (string-upcase (gethash "on" ht))))
                           :check (when (gethash "check" ht)
                                    (ast-to-form (gethash "check" ht))))))
             (when (gethash "reqs" ht)
               (setf (getf inv :reqs) (coerce (gethash "reqs" ht) 'list)))
             (setf (gethash key *invariants*) inv)))
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
                              (let ((per (gethash "per" eht))
                                    (singular (gethash "singular" eht)))
                                (list :binding (intern (string-upcase (gethash "binding" eht))
                                                       :keyword)
                                      :entity (gethash "entity" eht)
                                      :min (gethash "min" eht)
                                      :max (gethash "max" eht)
                                      :per (when per
                                             (intern (string-upcase per) :keyword))
                                      :singular singular)))
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
