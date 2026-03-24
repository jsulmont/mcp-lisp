;;;; src/spec/codegen.lisp
;;;;
;;;; Code generation from behavioral specs. Currently supports PostgreSQL DDL.

(defpackage #:mcp-lisp/src/spec/codegen
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/spec
                #:*entities*
                #:*rules*
                #:*invariants*
                #:*variants*
                #:*config*
                #:*scenarios*
                #:describe-entity
                #:list-entities
                #:describe-rule
                #:list-rules
                #:describe-invariant
                #:list-invariants
                #:describe-variant
                #:list-variants
                #:entity-fields
                #:entity-relations
                #:entity-variants
                #:list-scenarios
                #:describe-scenario
                #:decompose-accessor)
  (:import-from #:mcp-lisp/src/spec/transitions
                #:detect-state-fields
                #:extract-transitions)
  (:import-from #:mcp-lisp/src/spec/pbt
                #:invariants-for
                #:getf-field-p
                #:generate-instance
                #:generate-scenario
                #:ensure-entity-accessors
                #:ensure-variant-accessors
                #:check-invariants)
  (:export #:specs-to-sql
           #:specs-to-sql-seed))

(in-package #:mcp-lisp/src/spec/codegen)

;;; ---------------------------------------------------------------------------
;;; Name conversion
;;; ---------------------------------------------------------------------------

(defun lisp-to-sql (name)
  "Convert kebab-case NAME (string or symbol) to snake_case SQL identifier."
  (substitute #\_ #\- (string-downcase (string name))))

(defun belongs-to-target (rel)
  "Extract the target entity name (lowercase string) from a :belongs-to relation.
Handles both short form (:belongs-to target) and long form (:belongs-to name :of target)."
  (let ((len (length rel)))
    (cond
      ((and (>= len 4) (eq (third rel) :of))
       (string-downcase (string (fourth rel))))
      ((>= len 2)
       (string-downcase (string (second rel))))
      (t nil))))

;;; ---------------------------------------------------------------------------
;;; Enum collection
;;; ---------------------------------------------------------------------------

(defun member-type-p (type-spec)
  (and (consp type-spec) (eq (car type-spec) 'member)))

(defun member-values (type-spec)
  (when (member-type-p type-spec)
    (mapcar (lambda (v) (lisp-to-sql (princ-to-string v))) (cdr type-spec))))

(defun collect-enums ()
  "Collect all (member ...) type specs across entities and variants.
Returns alist of ((sql-type-name . (val1 val2 ...)) ...)."
  (let ((enums nil)
        (seen (make-hash-table :test #'equal)))
    (flet ((register (entity-name field-name type-spec)
             (when (member-type-p type-spec)
               (let* ((vals (member-values type-spec))
                      (val-key (format nil "~{~A~^,~}" vals)))
                 (unless (gethash val-key seen)
                   (setf (gethash val-key seen) t)
                   (push (cons (format nil "~A_~A"
                                       (lisp-to-sql entity-name)
                                       (lisp-to-sql field-name))
                               vals)
                         enums))))))
      (dolist (ename (list-entities))
        (dolist (field (entity-fields ename))
          (register ename (first field) (second field))))
      (dolist (vname (list-variants))
        (let ((variant (describe-variant vname)))
          (dolist (field (getf variant :fields))
            (register (getf variant :parent) (first field) (second field))))))
    (nreverse enums)))

(defun enum-type-name (entity-name field-name enums)
  "Look up the SQL enum type name for a (member ...) field."
  (let* ((type-spec (second (find (intern (string-upcase (string field-name)))
                                  (entity-fields entity-name)
                                  :key #'first)))
         (vals (when (member-type-p type-spec) (member-values type-spec)))
         (val-key (when vals (format nil "~{~A~^,~}" vals))))
    (when val-key
      (car (find val-key enums :key (lambda (e) (format nil "~{~A~^,~}" (cdr e)))
                                :test #'string=)))))

;;; ---------------------------------------------------------------------------
;;; Type mapping
;;; ---------------------------------------------------------------------------

(defun sql-type (type-spec entity-name field-name enums)
  "Map a spec type to a SQL type string."
  (cond
    ((eq type-spec 'string)  "TEXT")
    ((eq type-spec 'number)  "NUMERIC")
    ((eq type-spec 'integer) "INTEGER")
    ((eq type-spec 'boolean) "BOOLEAN")
    ((eq type-spec 'list)    "JSONB")
    ((member-type-p type-spec)
     (or (enum-type-name entity-name field-name enums)
         "TEXT"))
    (t "TEXT")))

;;; ---------------------------------------------------------------------------
;;; Invariant → SQL CHECK constraint translation
;;; ---------------------------------------------------------------------------

(defun field-type-for (entity-name field-sql-name)
  "Look up the type spec for FIELD-SQL-NAME in ENTITY-NAME. Returns NIL if not found."
  (dolist (f (entity-fields entity-name))
    (when (string= (lisp-to-sql (string (first f))) field-sql-name)
      (return (second f)))))

(defun form-to-sql (form entity-name)
  "Translate a Lisp invariant check form to a SQL expression string.
Returns the SQL string or NIL if the form can't be translated."
  (let ((ename (string-downcase (string entity-name))))
    (labels
        ((field-ref (f)
           (cond
             ((and (consp f) (eq (first f) 'getf) (= (length f) 3)
                   (symbolp (second f)) (keywordp (third f))
                   (string-equal (symbol-name (second f)) ename))
              (lisp-to-sql (symbol-name (third f))))
             ((and (consp f) (= (length f) 2) (symbolp (first f)) (symbolp (second f))
                   (string-equal (symbol-name (second f)) ename))
              (multiple-value-bind (ekey fname) (decompose-accessor (first f))
                (when (and ekey (string-equal ekey ename))
                  (lisp-to-sql fname))))
             (t nil)))
         (xlate (f)
           (cond
             ((null f) nil)
             ((eq f t) nil)
             ((numberp f) (format nil "~A" f))
             ((keywordp f)
              (format nil "'~A'" (lisp-to-sql (symbol-name f))))
             ((stringp f) (format nil "'~A'" f))
             ((symbolp f)
              (let ((fr (field-ref (list f (intern (string-upcase ename))))))
                (when fr fr)))
             ((not (consp f)) nil)
             ;; Field access
             ((field-ref f) (field-ref f))
             ;; Comparisons
             ((and (member (first f) '(>= <= > < =)) (= (length f) 3))
              (let ((l (xlate (second f)))
                    (r (xlate (third f)))
                    (op (case (first f) (>= ">=") (<= "<=") (> ">") (< "<") (= "="))))
                (when (and l r) (format nil "~A ~A ~A" l op r))))
             ;; eq / equal / string= for equality
             ((and (member (first f) '(eq equal string= string-equal)) (= (length f) 3))
              (let ((l (xlate (second f)))
                    (r (xlate (third f))))
                (when (and l r) (format nil "~A = ~A" l r))))
             ;; /= for numeric not-equal
             ((and (eq (first f) '/=) (= (length f) 3))
              (let ((l (xlate (second f)))
                    (r (xlate (third f))))
                (when (and l r) (format nil "~A <> ~A" l r))))
             ;; and
             ((eq (first f) 'and)
              (let ((parts (mapcar #'xlate (cdr f))))
                (when (every #'identity parts)
                  (format nil "(~{~A~^ AND ~})" parts))))
             ;; or
             ((eq (first f) 'or)
              (let ((parts (mapcar #'xlate (cdr f))))
                (when (every #'identity parts)
                  (format nil "(~{~A~^ OR ~})" parts))))
             ;; not — special-case (not (eq/equal a b)) → a <> b
             ;;        special-case (not (field entity)) → field IS NULL
             ((and (eq (first f) 'not) (= (length f) 2))
              (let ((inner (second f)))
                (cond
                  ;; (not (eq a b)) → a <> b
                  ((and (consp inner)
                        (member (first inner) '(eq equal string= string-equal =))
                        (= (length inner) 3))
                   (let ((l (xlate (second inner)))
                         (r (xlate (third inner))))
                     (when (and l r) (format nil "~A <> ~A" l r))))
                  ;; (not (accessor entity)) where accessor is a field ref → field IS NULL
                  ((field-ref inner)
                   (format nil "NOT (~A)" (field-ref inner)))
                  (t
                   (let ((sql (xlate inner)))
                     (when sql (format nil "NOT (~A)" sql)))))))
             ;; if with T else → conditional invariant: (if test consequent t)
             ;; → NOT (test) OR (consequent)
             ((and (eq (first f) 'if) (= (length f) 4))
              (let* ((test-form (second f))
                     (test (xlate test-form))
                     (then (xlate (third f)))
                     (else-form (fourth f))
                     ;; When test is a bare field accessor on a non-boolean field,
                     ;; negate as "field IS NULL" instead of "NOT (field)"
                     (test-field (when (consp test-form) (field-ref test-form)))
                     (test-ftype (when test-field
                                   (field-type-for entity-name test-field)))
                     (negated-test
                       (when test
                         (if (and test-field test-ftype (not (eq test-ftype 'boolean)))
                             (format nil "~A IS NULL" test-field)
                             (format nil "NOT (~A)" test)))))
                (cond
                  ;; (if test consequent t) → negated-test OR (consequent)
                  ((and negated-test then (eq else-form t))
                   (format nil "(~A OR (~A))" negated-test then))
                  ;; (if test t else) → (test) OR (else)
                  ((and test (eq (third f) t) (xlate else-form))
                   (format nil "((~A) OR (~A))" test (xlate else-form)))
                  ;; Both branches translatable
                  ((and test then (xlate else-form))
                   (format nil "(CASE WHEN ~A THEN (~A) ELSE (~A) END)"
                           test then (xlate else-form)))
                  (t nil))))
             ;; member check: (member field '(vals...))
             ((and (eq (first f) 'member) (= (length f) 3))
              (let ((field (xlate (second f)))
                    (vals (when (and (consp (third f)) (eq (car (third f)) 'quote))
                            (mapcar (lambda (v) (format nil "'~A'" (lisp-to-sql (princ-to-string v))))
                                    (cadr (third f))))))
                (when (and field vals)
                  (format nil "~A IN (~{~A~^, ~})" field vals))))
             ;; Arithmetic
             ((and (member (first f) '(+ - * /)) (= (length f) 3))
              (let ((l (xlate (second f)))
                    (r (xlate (third f)))
                    (op (string (first f))))
                (when (and l r) (format nil "(~A ~A ~A)" l op r))))
             ((and (eq (first f) 'abs) (= (length f) 2))
              (let ((inner (xlate (second f))))
                (when inner (format nil "abs(~A)" inner))))
             ;; length — use jsonb_array_length for list/JSONB fields
             ((and (eq (first f) 'length) (= (length f) 2))
              (let* ((inner (xlate (second f)))
                     (inner-field (when (consp (second f)) (field-ref (second f))))
                     (inner-ftype (when inner-field
                                    (field-type-for entity-name inner-field)))
                     (fn (if (eq inner-ftype 'list) "jsonb_array_length" "length")))
                (when inner (format nil "~A(~A)" fn inner))))
             (t nil))))
      (xlate form))))

;;; ---------------------------------------------------------------------------
;;; Table dependency ordering
;;; ---------------------------------------------------------------------------

(defun entity-dependencies (entity-name)
  "Return list of entity names that ENTITY-NAME depends on (via :belongs-to)."
  (let ((deps nil))
    (dolist (rel (entity-relations entity-name))
      (when (eq (first rel) :belongs-to)
        (let ((target (belongs-to-target rel)))
          (unless (string= target entity-name)
            (pushnew target deps :test #'string=)))))
    deps))

(defun toposort-entities ()
  "Return entity names in dependency order (parents before children)."
  (let* ((names (list-entities))
         (sorted nil)
         (visited (make-hash-table :test #'equal))
         (visiting (make-hash-table :test #'equal)))
    (labels ((visit (name)
               (when (gethash name visiting)
                 (return-from visit))
               (when (gethash name visited)
                 (return-from visit))
               (setf (gethash name visiting) t)
               (dolist (dep (entity-dependencies name))
                 (when (member dep names :test #'string=)
                   (visit dep)))
               (remhash name visiting)
               (setf (gethash name visited) t)
               (push name sorted)))
      (dolist (name names)
        (visit name)))
    (nreverse sorted)))

;;; ---------------------------------------------------------------------------
;;; SQL emission
;;; ---------------------------------------------------------------------------

(defun emit-enums (enums out)
  (when enums
    (format out "-- Enum types~%")
    (dolist (enum enums)
      (format out "CREATE TYPE ~A AS ENUM (~{~A~^, ~});~%"
              (car enum)
              (mapcar (lambda (v) (format nil "'~A'" v)) (cdr enum))))
    (format out "~%")))

(defun emit-config (out)
  (when *config*
    (format out "-- Config~%")
    (format out "CREATE TABLE config (~%")
    (format out "    key   TEXT    PRIMARY KEY,~%")
    (format out "    value NUMERIC NOT NULL~%");
    (format out ");~%~%")
    (let ((defaults nil))
      (dolist (field *config*)
        (let* ((name (first field))
               (kwargs (cddr field))
               (default (getf kwargs :default))
               (mn (getf kwargs :min))
               (mx (getf kwargs :max)))
          (when default
            (push (list (lisp-to-sql (string name))
                        (cond ((eq default t) 1)
                              ((eq default nil) 0)
                              (t default))
                        mn mx)
                  defaults))))
      (when defaults
        (format out "INSERT INTO config (key, value) VALUES~%")
        (let ((items (nreverse defaults)))
          (loop for (name default mn mx) in items
                for i from 0
                do (format out "    ('~A', ~A)~A"
                           name default
                           (if (= i (1- (length items))) ";" ","))
                   (when (and mn mx)
                     (format out "  -- [~A, ~A]" mn mx))
                   (format out "~%")))
        (format out "~%")))))

(defun field-comment (field)
  "Build an inline comment string from field metadata, or NIL."
  (let* ((ftype (second field))
         (kwargs (cddr field))
         (mn (getf kwargs :min))
         (mx (getf kwargs :max))
         (parts nil))
    (when (member-type-p ftype)
      (push (format nil "~{~A~^, ~}"
                    (mapcar (lambda (v) (string-downcase (princ-to-string v)))
                            (cdr ftype)))
            parts))
    (when (or mn mx)
      (push (format nil "[~A, ~A]"
                    (or mn "")
                    (or mx ""))
            parts))
    (when parts
      (format nil "~{~A~^; ~}" (nreverse parts)))))

(defun infer-fk-constraints (entity-name)
  "Infer foreign key constraints for ENTITY-NAME by scanning has-many/has-one
relations from other entities that point at this entity. Returns a list of
(fk-col-sql parent-table-sql parent-col-sql) triples."
  (let ((result nil)
        (ename-down (string-downcase (string entity-name))))
    (dolist (other-name (list-entities))
      (dolist (rel (entity-relations other-name))
        (when (and (member (first rel) '(:has-many :has-one))
                   (>= (length rel) 4)
                   (eq (third rel) :of))
          (let ((target (string-downcase (string (fourth rel)))))
            (when (string= target ename-down)
              ;; Find the unique fields of the parent entity
              (let ((parent-unique-fields
                      (loop for f in (entity-fields other-name)
                            for fname = (string-downcase (string (first f)))
                            for kwargs = (cddr f)
                            when (or (string= fname "id")
                                     (getf kwargs :unique))
                              collect fname)))
                ;; For each unique field, look for a matching FK field in this entity
                (dolist (puf parent-unique-fields)
                  (let* ((expected-fk (format nil "~A-~A"
                                              (string-downcase (string other-name))
                                              puf))
                         (match (find expected-fk (entity-fields entity-name)
                                      :key (lambda (f) (string-downcase (string (first f))))
                                      :test #'string=)))
                    (when match
                      (pushnew (list (lisp-to-sql expected-fk)
                                     (lisp-to-sql other-name)
                                     (lisp-to-sql puf))
                               result :test #'equal))))))))))
    (nreverse result)))

(defun emit-table (entity-name enums out)
  (let* ((entity (describe-entity entity-name))
         (fields (entity-fields entity-name))
         (relations (entity-relations entity-name))
         (variants (entity-variants entity-name))
         (invariants (invariants-for entity-name))
         (table-name (lisp-to-sql entity-name))
         (lines nil))
    ;; Columns from fields
    (dolist (field fields)
      (let* ((fname (first field))
             (ftype (second field))
             (kwargs (cddr field))
             (col-name (lisp-to-sql (string fname)))
             (col-type (sql-type ftype entity-name (string fname) enums))
             (modifiers nil)
             (comment (field-comment field)))
        (when (string= col-name "id")
          (push "PRIMARY KEY" modifiers))
        (when (getf kwargs :required)
          (push "NOT NULL" modifiers))
        (when (getf kwargs :unique)
          (push "UNIQUE" modifiers))
        (when (getf kwargs :default)
          (let ((default (getf kwargs :default)))
            (push (format nil "DEFAULT ~A"
                          (cond
                            ((keywordp default) (format nil "'~A'" (lisp-to-sql (symbol-name default))))
                            ((eq default t) "TRUE")
                            ((eq default nil) "FALSE")
                            ((stringp default) (format nil "'~A'" default))
                            (t (format nil "~A" default))))
                  modifiers)))
        (push (list (format nil "    ~A ~A~{~^ ~A~}" col-name col-type (nreverse modifiers))
                    comment)
              lines)))
    ;; Foreign keys from :belongs-to
    (dolist (rel relations)
      (when (eq (first rel) :belongs-to)
        (let* ((target (belongs-to-target rel))
               (fk-col (format nil "~A_id" (lisp-to-sql target))))
          (push (list (format nil "    ~A TEXT REFERENCES ~A(id)" fk-col (lisp-to-sql target))
                      nil)
                lines))))
    ;; Foreign keys inferred from has-many/has-one relations on other entities
    (dolist (fk (infer-fk-constraints entity-name))
      (destructuring-bind (fk-col parent-table parent-col) fk
        ;; Only add REFERENCES if the column is already declared (from fields above)
        ;; We emit it as a standalone CONSTRAINT to avoid duplicating the column definition
        (let ((constraint-name (format nil "fk_~A_~A" table-name fk-col)))
          (push (list (format nil "    CONSTRAINT ~A FOREIGN KEY (~A) REFERENCES ~A(~A)"
                              constraint-name fk-col parent-table parent-col)
                      nil)
                lines))))
    ;; Variant fields (nullable — only valid for matching discriminator)
    (dolist (vname variants)
      (let ((variant (describe-variant vname)))
        (dolist (field (getf variant :fields))
          (let* ((fname (first field))
                 (ftype (second field))
                 (col-name (lisp-to-sql (string fname)))
                 (col-type (sql-type ftype entity-name (string fname) enums))
                 (comment (field-comment field))
                 (vcomment (if comment
                               (format nil "~A (variant: ~A)" comment vname)
                               (format nil "variant: ~A" vname))))
            (push (list (format nil "    ~A ~A" col-name col-type)
                        vcomment)
                  lines)))))
    ;; CHECK constraints from invariants
    (let ((comments nil))
      (dolist (entry invariants)
        (destructuring-bind (inv-name inv) entry
          (let* ((check-form (getf inv :check))
                 (sql-expr (form-to-sql check-form entity-name))
                 (constraint-name (lisp-to-sql inv-name)))
            (if sql-expr
                (push (list (format nil "    CONSTRAINT ~A CHECK (~A)" constraint-name sql-expr)
                            nil)
                      lines)
                (push (format nil "    -- inv: ~A (not translatable to SQL)" inv-name)
                      comments)))))
      ;; Emit
      (format out "CREATE TABLE ~A (~%" table-name)
      (let ((rlines (nreverse lines)))
        (loop for entry in rlines
              for i from 0
              for sql = (first entry)
              for cmt = (second entry)
              for comma = (if (= i (1- (length rlines))) "" ",")
              do (if cmt
                     (format out "~A~A  -- ~A~%" sql comma cmt)
                     (format out "~A~A~%" sql comma))))
      (when comments
        (dolist (c (nreverse comments))
          (format out "~A~%" c)))
      (format out ");~%~%"))))

(defun emit-indexes (entity-name out)
  (let ((table-name (lisp-to-sql entity-name)))
    ;; Foreign key indexes from :belongs-to
    (dolist (rel (entity-relations entity-name))
      (when (eq (first rel) :belongs-to)
        (let* ((target (belongs-to-target rel))
               (fk-col (format nil "~A_id" (lisp-to-sql target))))
          (format out "CREATE INDEX idx_~A_~A ON ~A(~A);~%"
                  table-name (lisp-to-sql target) table-name fk-col))))
    ;; Foreign key indexes from inferred has-many/has-one relations
    (dolist (fk (infer-fk-constraints entity-name))
      (let ((fk-col (first fk)))
        (format out "CREATE INDEX idx_~A_~A ON ~A(~A);~%"
                table-name fk-col table-name fk-col)))
    ;; State field indexes
    (dolist (state-field (detect-state-fields entity-name))
      (let ((col-name (lisp-to-sql (symbol-name state-field))))
        (format out "CREATE INDEX idx_~A_~A ON ~A(~A);~%"
                table-name col-name table-name col-name)))))

(defun emit-triggers (entity-name out)
  (dolist (state-field (detect-state-fields entity-name))
    (let* ((transitions (extract-transitions entity-name state-field))
           (table-name (lisp-to-sql entity-name))
           (col-name (lisp-to-sql (symbol-name state-field)))
           (fn-name (format nil "check_~A_~A_transition" table-name col-name)))
      (when transitions
        (format out "CREATE OR REPLACE FUNCTION ~A()~%" fn-name)
        (format out "RETURNS TRIGGER AS $$~%")
        (format out "BEGIN~%")
        (format out "    IF OLD.~A = NEW.~A THEN~%" col-name col-name)
        (format out "        RETURN NEW;~%")
        (format out "    END IF;~%")
        (format out "    IF NOT (~%")
        (loop for tr in transitions
              for i from 0
              do (format out "        (OLD.~A = '~A' AND NEW.~A = '~A')~A~%"
                         col-name (lisp-to-sql (symbol-name (getf tr :from)))
                         col-name (lisp-to-sql (symbol-name (getf tr :to)))
                         (if (= i (1- (length transitions))) "" " OR")))
        (format out "    ) THEN~%")
        (format out "        RAISE EXCEPTION 'invalid ~A transition: % → %', OLD.~A, NEW.~A;~%"
                table-name col-name col-name)
        (format out "    END IF;~%")
        (format out "    RETURN NEW;~%")
        (format out "END;~%")
        (format out "$$ LANGUAGE plpgsql;~%~%")
        (format out "CREATE TRIGGER trg_~A_~A~%" table-name col-name)
        (format out "    BEFORE UPDATE OF ~A ON ~A~%" col-name table-name)
        (format out "    FOR EACH ROW EXECUTE FUNCTION ~A();~%~%" fn-name)))))

;;; ---------------------------------------------------------------------------
;;; Top-level
;;; ---------------------------------------------------------------------------

(defun specs-to-sql (&key (dialect :postgresql))
  "Generate SQL DDL from the current spec registries.
Returns a string containing CREATE TYPE, CREATE TABLE, and trigger statements.
Only :postgresql dialect is currently supported."
  (declare (ignore dialect))
  (let ((out (make-string-output-stream))
        (enums (collect-enums))
        (entities (toposort-entities)))
    (format out "BEGIN;~%~%")
    (emit-enums enums out)
    (emit-config out)
    (dolist (ename entities)
      (emit-table ename enums out))
    ;; Indexes
    (let ((has-indexes nil))
      (dolist (ename entities)
        (let ((s (make-string-output-stream)))
          (emit-indexes ename s)
          (let ((idx-str (get-output-stream-string s)))
            (when (plusp (length idx-str))
              (unless has-indexes
                (setf has-indexes t))
              (write-string idx-str out)))))
      (when has-indexes (format out "~%")))
    ;; Triggers
    (let ((has-triggers nil))
      (dolist (ename entities)
        (when (detect-state-fields ename)
          (unless has-triggers
            (setf has-triggers t))
          (emit-triggers ename out))))
    (format out "COMMIT;~%")
    (get-output-stream-string out)))

;;; ---------------------------------------------------------------------------
;;; Seed data generation
;;; ---------------------------------------------------------------------------

(defvar *seed-id-counter* 0)

(defun generate-seed-id (entity-name)
  "Generate a unique ID string for seed data: entity-name prefix + counter."
  (format nil "~A-~A" (lisp-to-sql entity-name) (incf *seed-id-counter*)))

(defun unique-string-fields (entity-name)
  "Return list of field keywords that are string type with :unique t or named ID."
  (let ((result nil))
    (dolist (f (entity-fields entity-name))
      (let* ((fname (first f))
             (ftype (second f))
             (kwargs (cddr f))
             (kw (intern (string fname) :keyword)))
        (when (and (eq ftype 'string)
                   (or (string-equal (string fname) "ID")
                       (getf kwargs :unique)))
          (push kw result))))
    (nreverse result)))

(defun stamp-unique-ids (entity-name instances)
  "Replace unique string fields with collision-free IDs. Returns modified instances."
  (let ((unique-fields (unique-string-fields entity-name)))
    (when unique-fields
      (dolist (inst instances)
        (dolist (kw unique-fields)
          (setf (getf inst kw) (generate-seed-id entity-name)))))
    instances))

(defun list-to-json (lst)
  "Convert a Lisp list to a JSON array string."
  (format nil "[~{~A~^, ~}]"
          (mapcar (lambda (v)
                    (cond ((stringp v) (format nil "~S" v))
                          ((numberp v) (format nil "~A" v))
                          ((keywordp v) (format nil "~S" (lisp-to-sql (symbol-name v))))
                          ((consp v) (list-to-json v))
                          ((null v) "null")
                          ((eq v t) "true")
                          (t (format nil "~S" (princ-to-string v)))))
                  lst)))

(defun sql-literal (value type-spec)
  "Format VALUE as a SQL literal appropriate for TYPE-SPEC."
  (cond
    ((and (eq type-spec 'list) (null value)) "'[]'")
    ((and (eq type-spec 'list) (consp value))
     (format nil "'~A'" (list-to-json value)))
    ((consp value)
     (format nil "'~A'" (list-to-json value)))
    ((null value) "NULL")
    ((eq value t) "TRUE")
    ((eq value nil) "FALSE")
    ((member-type-p type-spec)
     (format nil "'~A'" (lisp-to-sql (princ-to-string value))))
    ((keywordp value)
     (format nil "'~A'" (lisp-to-sql (symbol-name value))))
    ((stringp value)
     (format nil "'~A'" (substitute #\' #\' value)))  ; basic escaping
    ((numberp value) (format nil "~A" value))
    (t (format nil "'~A'" value))))

(defun entity-belongs-to-targets (entity-name)
  "Return alist of (fk-keyword . target-entity-name) for :belongs-to relations."
  (let ((result nil))
    (dolist (rel (entity-relations entity-name))
      (when (eq (first rel) :belongs-to)
        (let* ((target (belongs-to-target rel))
               (fk-kw (intern (format nil "~A-ID" (string-upcase target)) :keyword)))
          (push (cons fk-kw target) result))))
    (nreverse result)))

(defun entity-col-spec (entity-name)
  "Return (col-names col-field-specs) for ENTITY-NAME including variant and FK columns.
col-field-specs is a list of (keyword type-spec) pairs matching col-names order."
  (let ((col-names nil)
        (col-specs nil))
    (dolist (f (entity-fields entity-name))
      (push (lisp-to-sql (string (first f))) col-names)
      (push (list (intern (string (first f)) :keyword) (second f)) col-specs))
    (dolist (vname (entity-variants entity-name))
      (let ((variant (describe-variant vname)))
        (dolist (f (getf variant :fields))
          (push (lisp-to-sql (string (first f))) col-names)
          (push (list (intern (string (first f)) :keyword) (second f)) col-specs))))
    (dolist (fk (entity-belongs-to-targets entity-name))
      (push (format nil "~A_id" (lisp-to-sql (cdr fk))) col-names)
      (push (list (car fk) 'string) col-specs))
    (values (nreverse col-names) (nreverse col-specs))))

(defun instance-to-row (instance col-specs)
  "Convert an entity instance plist to a list of SQL literal strings."
  (mapcar (lambda (spec)
            (let ((val (getf instance (first spec))))
              (sql-literal val (second spec))))
          col-specs))

(defun emit-inserts (entity-name instances out)
  "Emit INSERT INTO statements for a list of INSTANCES of ENTITY-NAME."
  (when instances
    (multiple-value-bind (col-names col-specs) (entity-col-spec entity-name)
      (let ((rows (mapcar (lambda (inst) (instance-to-row inst col-specs)) instances)))
        (format out "INSERT INTO ~A (~{~A~^, ~}) VALUES~%"
                (lisp-to-sql entity-name) col-names)
        (loop for row in rows
              for i from 0
              do (format out "    (~{~A~^, ~})~A~%"
                         row
                         (if (= i (1- (length rows))) ";" ",")))
        (format out "~%")))))

(defun scenario-entity-map ()
  "Return hash: entity-name → list of scenario names that include it."
  (let ((result (make-hash-table :test #'equal)))
    (dolist (sname (list-scenarios))
      (let ((scenario (describe-scenario sname)))
        (dolist (espec (getf scenario :entities))
          (pushnew sname (gethash (getf espec :entity) result)
                   :test #'string=))))
    result))

(defun specs-to-sql-seed (&key (rows-per-entity 10) (scenario-trials 3))
  "Generate SQL INSERT statements with random, invariant-consistent seed data.
Returns a string. Entities covered by scenarios use generate-scenario for
correlated data (SCENARIO-TRIALS batches). Remaining entities get
ROWS-PER-ENTITY independent rows. Tables are emitted in dependency order.
Unique/ID string fields are stamped with collision-free identifiers."
  (dolist (name (list-entities))
    (ensure-entity-accessors name))
  (dolist (name (list-variants))
    (ensure-variant-accessors name))
  (setf *seed-id-counter* 0)
  (let ((out (make-string-output-stream))
        (entities (toposort-entities))
        (entity-instances (make-hash-table :test #'equal))
        (covered (scenario-entity-map)))
    ;; Phase 1: generate scenario instances for covered entities
    (let ((done-scenarios (make-hash-table :test #'equal)))
      (dolist (ename entities)
        (let ((scenarios (gethash ename covered)))
          (dolist (sname scenarios)
            (unless (gethash sname done-scenarios)
              (setf (gethash sname done-scenarios) t)
              (let ((scenario (describe-scenario sname)))
                (dotimes (_i scenario-trials)
                  (let ((si (generate-scenario sname)))
                    ;; Extract instances per entity from scenario
                    (dolist (espec (getf scenario :entities))
                      (let* ((binding (getf espec :binding))
                             (target-entity (getf espec :entity))
                             (val (getf si binding))
                             (insts (cond
                                      ((null val) nil)
                                      ((and (listp val) (keywordp (car val)))
                                       (list val))
                                      ((listp val) val)
                                      (t (list val)))))
                        (setf (gethash target-entity entity-instances)
                              (append (gethash target-entity entity-instances)
                                      insts))))))))))))
    ;; Phase 2: generate independent instances for uncovered entities
    (dolist (ename entities)
      (unless (gethash ename covered)
        (let ((id-pool (make-hash-table :test #'equal))
              (instances nil))
          ;; Collect parent IDs from already-generated instances
          (maphash (lambda (k v)
                     (dolist (inst v)
                       (let ((id (getf inst :id)))
                         (when id
                           (pushnew id (gethash k id-pool) :test #'equal)))))
                   entity-instances)
          (let ((fk-targets (entity-belongs-to-targets ename)))
            (dotimes (_i rows-per-entity)
              (let ((overrides
                      (loop for (fk-kw . target) in fk-targets
                            for parent-ids = (or (gethash target id-pool)
                                                 (let ((existing (gethash target entity-instances)))
                                                   (when existing
                                                     (mapcar (lambda (i) (getf i :id))
                                                             existing))))
                            when parent-ids
                              nconc (list fk-kw
                                         (nth (random (length parent-ids))
                                              parent-ids)))))
                (push (generate-instance ename overrides) instances))))
          (setf (gethash ename entity-instances) (nreverse instances)))))
    ;; Phase 3: stamp unique IDs on independently generated entities only.
    ;; Scenario-generated data has coherent cross-references by construction.
    (let ((id-map (make-hash-table :test #'equal)))
      (dolist (ename entities)
        (unless (gethash ename covered)
          (let ((instances (gethash ename entity-instances))
                (ufields (unique-string-fields ename)))
            (dolist (inst instances)
              (dolist (kw ufields)
                (let* ((old-val (getf inst kw))
                       (new-val (generate-seed-id ename)))
                  (when old-val
                    (setf (gethash old-val id-map) new-val))
                  (setf (getf inst kw) new-val))))
            (let ((fk-targets (entity-belongs-to-targets ename)))
              (dolist (inst instances)
                (dolist (fk fk-targets)
                  (let* ((kw (car fk))
                         (old-ref (getf inst kw))
                         (new-ref (when old-ref (gethash old-ref id-map))))
                    (when new-ref
                      (setf (getf inst kw) new-ref))))))))))
    ;; Phase 4: deduplicate by unique string fields (multiple scenario trials
    ;; can produce identical IDs from deterministic generators)
    (dolist (ename entities)
      (let* ((instances (gethash ename entity-instances))
             (ufields (unique-string-fields ename)))
        (when (and instances ufields)
          (let ((seen (make-hash-table :test #'equal))
                (unique nil))
            (dolist (inst instances)
              (let* ((key (format nil "~{~A~^|~}"
                                  (mapcar (lambda (kw) (or (getf inst kw) "")) ufields)))
                     (dup (gethash key seen)))
                (unless dup
                  (setf (gethash key seen) t)
                  (push inst unique))))
            (setf (gethash ename entity-instances) (nreverse unique))))))
    ;; Phase 5: emit INSERTs in dependency order
    (dolist (ename entities)
      (let ((instances (gethash ename entity-instances)))
        (emit-inserts ename instances out)))
    (get-output-stream-string out)))
