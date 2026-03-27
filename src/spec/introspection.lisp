;;;; src/spec/introspection.lisp
;;;;
;;;; Query functions for inspecting spec registries.

(defpackage #:mcp-lisp/src/spec/introspection
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/registry
                #:*entities*
                #:*rules*
                #:*invariants*
                #:*variants*
                #:*config*
                #:*current-config*
                #:*scenarios*
                #:*requirements*
                #:*dsl-docs*)
  (:export #:list-entities
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
           #:list-scenarios
           #:describe-scenario
           #:compliance-matrix
           #:entity-accessor-p
           #:config-accessor-p
           #:variant-accessor-p
           #:decompose-accessor
           #:list-dsl-forms
           #:describe-dsl
           #:spec-reference))

(in-package #:mcp-lisp/src/spec/introspection)

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

(defun compliance-matrix ()
  "Return a requirement-to-invariant mapping from :reqs metadata on invariants
and rules, and :id from defreq entries.
Each entry is (:req REQ-ID :invariants (inv-name1 ...) :rules (rule-name1 ...) :status :covered/:not-expressible).
Invariants without :reqs are collected under :uncategorized."
  (let ((req-map (make-hash-table :test #'equal))
        (rule-map (make-hash-table :test #'equal))
        (uncategorized nil))
    (maphash (lambda (key plist)
               (let ((reqs (getf plist :reqs)))
                 (if reqs
                     (dolist (req reqs)
                       (push key (gethash req req-map)))
                     (push key uncategorized))))
             *invariants*)
    (maphash (lambda (key plist)
               (let ((reqs (getf plist :reqs)))
                 (when reqs
                   (dolist (req reqs)
                     (push key (gethash req rule-map))))))
             *rules*)
    (let ((result nil))
      (maphash (lambda (req invs)
                 (push (list :req req :invariants (nreverse invs) :status :covered) result))
               req-map)
      (maphash (lambda (req rules)
                 (let ((existing (find req result
                                       :key (lambda (e) (getf e :req))
                                       :test #'string-equal)))
                   (if existing
                       (nconc existing (list :rules (nreverse rules)))
                       (push (list :req req :invariants nil
                                   :rules (nreverse rules) :status :covered)
                             result))))
               rule-map)
      (maphash (lambda (key plist)
                 (declare (ignore key))
                 (let* ((id (string (getf plist :id)))
                        (existing (find id result
                                        :key (lambda (e) (getf e :req))
                                        :test #'string-equal))
                        (defreq-status (getf plist :status)))
                   (if existing
                       (progn
                         (when (getf plist :description)
                           (nconc existing (list :description (getf plist :description))))
                         (when (getf plist :category)
                           (nconc existing (list :category (getf plist :category))))
                         (when defreq-status
                           (setf (getf existing :status)
                                 (if (and (getf existing :invariants)
                                          (member defreq-status '(:partial :not-expressible)))
                                     :partial
                                     defreq-status))))
                       (push (list :req id
                                   :description (getf plist :description)
                                   :category (getf plist :category)
                                   :invariants nil
                                   :status (or defreq-status :not-expressible))
                             result))))
               *requirements*)
      (setf result (sort result #'string<
                         :key (lambda (e) (let ((r (getf e :req)))
                                            (if (keywordp r)
                                                "~~~"
                                                r)))))
      (when uncategorized
        (setf result (append result
                             (list (list :req :uncategorized
                                         :invariants (nreverse uncategorized))))))
      result)))

;;; ---------------------------------------------------------------------------
;;; Accessor predicates
;;; ---------------------------------------------------------------------------

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

;;; ---------------------------------------------------------------------------
;;; DSL reflection
;;; ---------------------------------------------------------------------------

(defun list-dsl-forms ()
  "Return registered DSL form names sorted by section and order."
  (let ((entries nil))
    (maphash (lambda (k v) (declare (ignore k)) (push v entries)) *dsl-docs*)
    (sort entries (lambda (a b)
                    (let ((sa (or (getf a :section) ""))
                          (sb (or (getf b :section) "")))
                      (if (string= sa sb)
                          (< (or (getf a :order) 0) (or (getf b :order) 0))
                          (string< sa sb)))))))

(defun describe-dsl (name)
  "Return the documentation plist for DSL form NAME, or NIL."
  (gethash (string-downcase (string name)) *dsl-docs*))

(defun spec-reference ()
  "Generate a markdown spec DSL reference from live system metadata.
Covers all registered DSL forms with synopsis, example, and options."
  (with-output-to-string (out)
    (format out "## Spec DSL Reference~%~%")
    (format out "All macros and functions are available in the `eval_lisp` sandbox with no imports.~%~%")
    (let ((current-section nil))
      (dolist (entry (list-dsl-forms))
        (let ((name (getf entry :name))
              (synopsis (getf entry :synopsis))
              (example (getf entry :example))
              (options (getf entry :options))
              (section (getf entry :section)))
          (when (and section (not (equal section current-section)))
            (format out "### ~A~%~%" section)
            (setf current-section section))
          (format out "#### `~A`~%~%" name)
          (when synopsis
            (format out "~A~%~%" synopsis))
          (when example
            (format out "```lisp~%~A~%```~%~%" example))
          (when options
            (dolist (opt options)
              (format out "- **~A**: ~A~%" (first opt) (second opt)))
            (format out "~%")))))
    ;; Querying specs section
    (format out "### Querying specs~%~%")
    (format out "- `(list-entities)`, `(describe-entity name)`, `(entity-fields name)`, `(entity-relations name)`~%")
    (format out "- `(list-rules)`, `(describe-rule name)`~%")
    (format out "- `(list-invariants)`, `(describe-invariant name)`~%")
    (format out "- `(list-variants)`, `(describe-variant name)`, `(entity-variants entity-name)`~%")
    (format out "- `(list-valuesets)` — named value sets from `defvalueset`~%")
    (format out "- `(list-requirements)` — non-invariant requirements from `defreq`~%")
    (format out "- `(list-scenarios)`, `(describe-scenario name)`~%")
    (format out "- `(describe-config)`, `(config-fields)`~%")
    (format out "- `(validate-specs)` — structural validation~%")
    (format out "- `(suggest-invariants)` — propose missing invariants~%")
    (format out "- `(compliance-matrix)` — requirement-to-invariant mapping~%")
    (format out "- `(invariant-coverage-summary)` — coverage ratio per entity~%")
    (format out "- `(clear-specs)` — reset all registries~%")
    (format out "~%### Spec analysis~%~%")
    (format out "- `(invariant-coverage \"entity\")` — fields covered by invariants~%")
    (format out "- `(field-index \"entity\" :field)` — reverse lookup: what invariants/rules touch a field~%")
    (format out "- `(generation-feasibility \"entity\")` — can the default generator produce valid instances?~%")
    (format out "- `(scenario-feasibility \"scenario\")` — does a scenario need a custom generator?~%")
    (format out "- `(simulate-trace \"entity\" instance '(\"rule1\" \"rule2\"))` — step through rules~%")
    (format out "~%### State machine analysis~%~%")
    (format out "- `(detect-state-fields \"entity\")` — find member fields used in rules~%")
    (format out "- `(extract-transitions \"entity\")` — transition graph~%")
    (format out "- `(analyze-state-machine \"entity\")` — full analysis: states, terminal, unreachable, dead-ends~%")
    (format out "- `(validate-transitions)` — warn about unreachable states and dead ends~%")
    (format out "~%### Property-based testing~%~%")
    (format out "```lisp~%(run-pbt :trials 200)~%(run-pbt :trials 100 :config-trials 5)~%(run-pbt :scenario \"name\" :trials 50)~%(run-pbt :trials 200 :negative-trials 100)~%```~%~%")
    (format out "- `(generate-instance \"entity\")` — constraint-aware random instance~%")
    (format out "- `(check-invariants \"entity\" instance)` — targeted checking~%")
    (format out "- `(extract-generation-constraints \"entity\")` — inspect extracted constraints~%")
    (format out "- `(generate-config)` — random config within declared bounds~%")
    (format out "- `(generate-scenario \"scenario\")` — generate scenario instance~%")
    (format out "- `(check-scenario \"scenario\" instance)` — debug a scenario generator~%")
    (format out "~%### Rule execution~%~%")
    (format out "- `(apply-rule \"entity\" instance \"rule\")` — apply a single rule~%")
    (format out "- `(applicable-rules \"entity\" instance)` — which rules can fire~%")
    (format out "- `(random-walk \"entity\" :steps 20 :trials 50)` — random walk PBT~%")
    (format out "~%### Code generation~%~%")
    (format out "- `(specs-to-sql)` — PostgreSQL DDL~%")
    (format out "- `(specs-to-sql-seed :rows-per-entity 20)` — INSERT statements~%")
    (format out "- `(specs-to-lisp)` — loadable .lisp file~%")
    (format out "~%### Serialization~%~%")
    (format out "- `(specs-to-json)` — export as JSON~%")
    (format out "- `(json-to-specs json-string)` — import from JSON~%")
    (format out "- `(spec-json-schema)` — JSON Schema~%")
    (format out "- `(write-specs #p\"/path/to/file.sexp\")` — write s-expression~%")
    (format out "- `(read-specs #p\"/path/to/file.sexp\")` — read s-expression~%")))
