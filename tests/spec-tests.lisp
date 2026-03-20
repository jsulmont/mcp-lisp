;;;; tests/spec-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite spec-tests
  :description "Tests for the behavioral spec DSL"
  :in mcp-lisp-tests)

(in-suite spec-tests)

;;; Helpers — each test gets a clean registry

(defmacro with-fresh-specs (&body body)
  `(let ((mcp-lisp/src/spec/spec::*entities* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*rules* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*invariants* (make-hash-table :test #'equal)))
     ,@body))

;;; ---------------------------------------------------------------------------
;;; defentity
;;; ---------------------------------------------------------------------------

(test defentity-basic-fields
  "defentity stores field metadata correctly"
  (with-fresh-specs
    (mcp-lisp:defentity user ()
      (id string :required t)
      (email string :required t)
      (role (member :admin :member :guest) :default :member))
    (let ((desc (mcp-lisp:describe-entity "user")))
      (is (not (null desc)))
      (is (eq 'user (getf desc :name)))
      (let ((fields (getf desc :fields)))
        (is (= 3 (length fields)))
        (is (equal '(id string :required t) (first fields)))
        (is (equal '(email string :required t) (second fields)))
        (is (equal '(role (member :admin :member :guest) :default :member) (third fields)))))))

(test defentity-relations
  "defentity stores relationship metadata"
  (with-fresh-specs
    (mcp-lisp:defentity user ()
      (id string :required t)
      (:has-many orders :of order)
      (:has-one profile :of user-profile)
      (:belongs-to organization :of org))
    (let ((rels (mcp-lisp:entity-relations "user")))
      (is (= 3 (length rels)))
      (is (equal '(:has-many orders :of order) (first rels)))
      (is (equal '(:has-one profile :of user-profile) (second rels)))
      (is (equal '(:belongs-to organization :of org) (third rels))))))

(test defentity-derived
  "defentity stores derived value specs"
  (with-fresh-specs
    (mcp-lisp:defentity user ()
      (name string)
      (email string :required t)
      (:derived display-name (lambda (u) (or (name u) (email u)))))
    (let ((derived (getf (mcp-lisp:describe-entity "user") :derived)))
      (is (= 1 (length derived)))
      (is (eq :derived (caar derived)))
      (is (eq 'display-name (cadar derived))))))

(test defentity-supers
  "defentity records supertype list"
  (with-fresh-specs
    (mcp-lisp:defentity admin-user (user)
      (permissions list :required t))
    (let ((desc (mcp-lisp:describe-entity "admin-user")))
      (is (equal '(user) (getf desc :supers))))))

(test defentity-return-value
  "defentity returns the entity name symbol"
  (with-fresh-specs
    (is (eq 'account (mcp-lisp:defentity account ()
                       (id string))))))

;;; ---------------------------------------------------------------------------
;;; defrule
;;; ---------------------------------------------------------------------------

(test defrule-stores-metadata
  "defrule stores when/let/requires/ensures"
  (with-fresh-specs
    (mcp-lisp:defrule place-order
      :when (order :state :draft)
      :let ((customer (order-customer order)))
      :requires ((active-account-p customer)
                 (pos (account-balance customer)))
      :ensures ((eq (order-state order) :placed)
                (order-placed-at order)))
    (let ((rule (mcp-lisp:describe-rule "place-order")))
      (is (not (null rule)))
      (is (eq 'place-order (getf rule :name)))
      (is (equal '(order :state :draft) (getf rule :when)))
      (is (equal '((customer (order-customer order))) (getf rule :let)))
      (is (equal '((active-account-p customer)
                   (pos (account-balance customer)))
                 (getf rule :requires)))
      (is (equal '((eq (order-state order) :placed)
                   (order-placed-at order))
                 (getf rule :ensures))))))

(test defrule-return-value
  "defrule returns the rule name symbol"
  (with-fresh-specs
    (is (eq 'cancel-order
            (mcp-lisp:defrule cancel-order
              :when (order :state :placed)
              :ensures ((eq (order-state order) :cancelled)))))))

;;; ---------------------------------------------------------------------------
;;; definvariant
;;; ---------------------------------------------------------------------------

(test definvariant-stores-metadata
  "definvariant stores on/check"
  (with-fresh-specs
    (mcp-lisp:definvariant positive-balance
      :on account
      :check (>= (account-balance account) 0))
    (let ((inv (mcp-lisp:describe-invariant "positive-balance")))
      (is (not (null inv)))
      (is (eq 'positive-balance (getf inv :name)))
      (is (eq 'account (getf inv :on)))
      (is (equal '(>= (account-balance account) 0) (getf inv :check))))))

(test definvariant-return-value
  "definvariant returns the invariant name symbol"
  (with-fresh-specs
    (is (eq 'non-negative
            (mcp-lisp:definvariant non-negative
              :on account
              :check (>= (balance account) 0))))))

;;; ---------------------------------------------------------------------------
;;; Introspection
;;; ---------------------------------------------------------------------------

(test list-entities-empty
  "list-entities returns empty list with no entities"
  (with-fresh-specs
    (is (null (mcp-lisp:list-entities)))))

(test list-entities-populated
  "list-entities returns names of all registered entities"
  (with-fresh-specs
    (mcp-lisp:defentity user () (id string))
    (mcp-lisp:defentity order () (id string))
    (let ((entities (mcp-lisp:list-entities)))
      (is (= 2 (length entities)))
      (is (member "user" entities :test #'string=))
      (is (member "order" entities :test #'string=)))))

(test entity-fields-accessor
  "entity-fields returns only field specs"
  (with-fresh-specs
    (mcp-lisp:defentity user ()
      (id string :required t)
      (:has-many orders :of order)
      (:derived display-name (lambda (u) (name u))))
    (let ((fields (mcp-lisp:entity-fields "user")))
      (is (= 1 (length fields)))
      (is (equal '(id string :required t) (first fields))))))

(test entity-relations-accessor
  "entity-relations returns only relation specs"
  (with-fresh-specs
    (mcp-lisp:defentity user ()
      (id string :required t)
      (:has-many orders :of order)
      (:has-one profile :of user-profile))
    (let ((rels (mcp-lisp:entity-relations "user")))
      (is (= 2 (length rels)))
      (is (eq :has-many (caar rels))))))

(test describe-entity-unknown
  "describe-entity returns NIL for unknown entity"
  (with-fresh-specs
    (is (null (mcp-lisp:describe-entity "nonexistent")))))

(test list-rules-populated
  "list-rules returns names of all registered rules"
  (with-fresh-specs
    (mcp-lisp:defrule r1 :when (order :state :draft))
    (mcp-lisp:defrule r2 :when (order :state :placed))
    (let ((rules (mcp-lisp:list-rules)))
      (is (= 2 (length rules)))
      (is (member "r1" rules :test #'string=))
      (is (member "r2" rules :test #'string=)))))

(test list-invariants-populated
  "list-invariants returns names of all registered invariants"
  (with-fresh-specs
    (mcp-lisp:definvariant i1 :on account :check (> (balance account) 0))
    (let ((invs (mcp-lisp:list-invariants)))
      (is (= 1 (length invs)))
      (is (member "i1" invs :test #'string=)))))

;;; ---------------------------------------------------------------------------
;;; clear-specs
;;; ---------------------------------------------------------------------------

(test clear-specs-resets-all
  "clear-specs empties all registries"
  (with-fresh-specs
    (mcp-lisp:defentity user () (id string))
    (mcp-lisp:defrule r1 :when (user :state :active))
    (mcp-lisp:definvariant i1 :on user :check t)
    (is (= 1 (length (mcp-lisp:list-entities))))
    (is (= 1 (length (mcp-lisp:list-rules))))
    (is (= 1 (length (mcp-lisp:list-invariants))))
    (mcp-lisp:clear-specs)
    (is (null (mcp-lisp:list-entities)))
    (is (null (mcp-lisp:list-rules)))
    (is (null (mcp-lisp:list-invariants)))))

;;; ---------------------------------------------------------------------------
;;; validate-specs
;;; ---------------------------------------------------------------------------

(test validate-specs-clean
  "validate-specs returns no warnings when all refs are valid"
  (with-fresh-specs
    (mcp-lisp:defentity order () (id string))
    (mcp-lisp:defentity account () (balance number))
    (mcp-lisp:defrule place-order :when (order :state :draft))
    (mcp-lisp:definvariant positive-balance :on account :check (> (account-balance account) 0))
    (is (null (mcp-lisp:validate-specs)))))

(test validate-specs-dangling-rule
  "validate-specs catches rules referencing unknown entities"
  (with-fresh-specs
    (mcp-lisp:defrule place-order :when (order :state :draft))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (= 1 (length warnings)))
      (is (search "unknown entity" (first warnings))))))

(test validate-specs-dangling-invariant
  "validate-specs catches invariants referencing unknown entities"
  (with-fresh-specs
    (mcp-lisp:definvariant positive-balance :on account :check (> (account-balance account) 0))
    (let ((warnings (mcp-lisp:validate-specs)))
      ;; Dangling entity + unresolvable accessor (entity doesn't exist)
      (is (>= (length warnings) 1))
      (is (some (lambda (w) (search "unknown entity" w)) warnings)))))

(test validate-specs-dangling-relation
  "validate-specs catches relations referencing unknown entities"
  (with-fresh-specs
    (mcp-lisp:defentity user ()
      (id string)
      (:has-many orders :of order))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (= 1 (length warnings)))
      (is (search "unknown entity" (first warnings))))))

(test validate-specs-multiple-warnings
  "validate-specs accumulates multiple warnings"
  (with-fresh-specs
    (mcp-lisp:defrule r1 :when (foo :state :x))
    (mcp-lisp:defrule r2 :when (bar :state :y))
    (mcp-lisp:definvariant i1 :on baz :check t)
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (= 3 (length warnings))))))

(test validate-specs-free-variable-in-invariant
  "validate-specs catches invariant :check using wrong entity variable"
  (with-fresh-specs
    (mcp-lisp:defentity position ()
      (notional number :required t)
      (quantity number :required t)
      (entry-price number :required t))
    ;; Bug: uses 'order' instead of 'position' as the variable
    (mcp-lisp:definvariant notional-correct
      :on position
      :check (= (position-notional order) (* (position-quantity order) (position-entry-price order))))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (plusp (length warnings)))
      (is (some (lambda (w) (search "free variable" w)) warnings))
      (is (some (lambda (w) (search "ORDER" w)) warnings)))))

(test validate-specs-undefined-function-in-invariant
  "validate-specs catches undefined functions in invariant :check"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant positive-balance
      :on account
      :check (pos (account-balance account)))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (= 1 (length warnings)))
      (is (search "undefined function" (first warnings)))
      (is (search "POS" (first warnings))))))

(test validate-specs-undefined-function-in-rule
  "validate-specs catches undefined functions in rule :requires"
  (with-fresh-specs
    (mcp-lisp:defentity order ()
      (quantity number :required t))
    (mcp-lisp:defrule validate-order
      :when (order :state :pending)
      :requires ((pos (order-quantity order))))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (= 1 (length warnings)))
      (is (search "undefined function" (first warnings))))))

(test validate-specs-entity-accessors-ok
  "validate-specs does not warn about entity accessor patterns"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t)
      (name string))
    (mcp-lisp:definvariant positive-balance
      :on account
      :check (>= (account-balance account) 0))
    (is (null (mcp-lisp:validate-specs)))))

(test validate-specs-cl-builtins-ok
  "validate-specs does not warn about CL builtins and special operators"
  (with-fresh-specs
    (mcp-lisp:defentity trader ()
      (margin-ratio number :default 1.0)
      (suspended boolean :default nil))
    (mcp-lisp:definvariant check-margin
      :on trader
      :check (if (trader-suspended trader)
                 (< (trader-margin-ratio trader) 0.5)
                 t))
    (is (null (mcp-lisp:validate-specs)))))

;;; ---------------------------------------------------------------------------
;;; JSON export
;;; ---------------------------------------------------------------------------

(test specs-to-json-entities
  "specs-to-json serializes entities with fields, relations, derived"
  (with-fresh-specs
    (mcp-lisp:defentity user ()
      (id string :required t)
      (role (member :admin :guest) :default :guest)
      (:has-many orders :of order)
      (:derived display-name (lambda (u) (name u))))
    (let* ((json (mcp-lisp:specs-to-json))
           (data (mcp-lisp:decode-json json))
           (entities (gethash "entities" data))
           (user (gethash "user" entities)))
      (is (string= "user" (gethash "name" user)))
      ;; Fields
      (let* ((fields (gethash "fields" user))
             (id-field (aref fields 0))
             (role-field (aref fields 1)))
        (is (= 2 (length fields)))
        (is (string= "id" (gethash "name" id-field)))
        (is (string= "string" (gethash "type" id-field)))
        (is (eq t (gethash "required" id-field)))
        (is (string= "role" (gethash "name" role-field)))
        (is (string= "(member :admin :guest)" (gethash "type" role-field)))
        (is (string= ":guest" (gethash "default" role-field))))
      ;; Relations
      (let ((rel (aref (gethash "relations" user) 0)))
        (is (string= "has-many" (gethash "kind" rel)))
        (is (string= "orders" (gethash "name" rel)))
        (is (string= "order" (gethash "of" rel))))
      ;; Derived
      (let ((der (aref (gethash "derived" user) 0)))
        (is (string= "display-name" (gethash "name" der)))
        (is (string= "(lambda (u) (name u))" (gethash "expression" der)))))))

(test specs-to-json-rules
  "specs-to-json serializes rules"
  (with-fresh-specs
    (mcp-lisp:defrule place-order
      :when (order :state :draft)
      :let ((customer (order-customer order)))
      :requires ((active-account-p customer))
      :ensures ((eq (order-state order) :placed)))
    (let* ((json (mcp-lisp:specs-to-json))
           (data (mcp-lisp:decode-json json))
           (rule (gethash "place-order" (gethash "rules" data))))
      (is (string= "place-order" (gethash "name" rule)))
      (is (string= "(order :state :draft)" (gethash "when" rule)))
      (is (string= "(customer (order-customer order))" (aref (gethash "let" rule) 0)))
      (is (string= "(active-account-p customer)" (aref (gethash "requires" rule) 0)))
      (is (string= "(eq (order-state order) :placed)" (aref (gethash "ensures" rule) 0))))))

(test specs-to-json-invariants
  "specs-to-json serializes invariants"
  (with-fresh-specs
    (mcp-lisp:definvariant positive-balance
      :on account
      :check (>= (balance account) 0))
    (let* ((json (mcp-lisp:specs-to-json))
           (data (mcp-lisp:decode-json json))
           (inv (gethash "positive-balance" (gethash "invariants" data))))
      (is (string= "positive-balance" (gethash "name" inv)))
      (is (string= "account" (gethash "on" inv)))
      (is (string= "(>= (balance account) 0)" (gethash "check" inv))))))

;;; ---------------------------------------------------------------------------
;;; JSON round-trip
;;; ---------------------------------------------------------------------------

(test json-round-trip-entities
  "json-to-specs restores entities from exported JSON"
  (with-fresh-specs
    (mcp-lisp:defentity user ()
      (id string :required t)
      (email string)
      (:has-many orders :of order)
      (:derived display-name (lambda (u) (name u))))
    (mcp-lisp:defentity order ()
      (total number :required t))
    (let ((json (mcp-lisp:specs-to-json)))
      (mcp-lisp:clear-specs)
      (is (null (mcp-lisp:list-entities)))
      (mcp-lisp:json-to-specs json)
      ;; Entities restored
      (is (= 2 (length (mcp-lisp:list-entities))))
      (let ((user (mcp-lisp:describe-entity "user")))
        (is (not (null user)))
        ;; Fields
        (let ((fields (getf user :fields)))
          (is (= 2 (length fields)))
          (is (eq 'id (caar fields)))
          (is (eq 'string (cadar fields))))
        ;; Relations
        (let ((rels (getf user :relations)))
          (is (= 1 (length rels)))
          (is (eq :has-many (caar rels))))
        ;; Derived
        (is (= 1 (length (getf user :derived))))))))

(test json-round-trip-rules
  "json-to-specs restores rules from exported JSON"
  (with-fresh-specs
    (mcp-lisp:defrule place-order
      :when (order :state :draft)
      :requires ((active-p customer))
      :ensures ((eq (state order) :placed)))
    (let ((json (mcp-lisp:specs-to-json)))
      (mcp-lisp:clear-specs)
      (mcp-lisp:json-to-specs json)
      (let ((rule (mcp-lisp:describe-rule "place-order")))
        (is (not (null rule)))
        (is (equal '(order :state :draft) (getf rule :when)))
        (is (equal '((active-p customer)) (getf rule :requires)))
        (is (equal '((eq (state order) :placed)) (getf rule :ensures)))))))

(test json-round-trip-invariants
  "json-to-specs restores invariants from exported JSON"
  (with-fresh-specs
    (mcp-lisp:definvariant positive-balance
      :on account
      :check (>= (balance account) 0))
    (let ((json (mcp-lisp:specs-to-json)))
      (mcp-lisp:clear-specs)
      (mcp-lisp:json-to-specs json)
      (let ((inv (mcp-lisp:describe-invariant "positive-balance")))
        (is (not (null inv)))
        (is (eq 'account (getf inv :on)))
        (is (equal '(>= (balance account) 0) (getf inv :check)))))))

(test json-round-trip-supers
  "json-to-specs preserves entity supertypes"
  (with-fresh-specs
    (mcp-lisp:defentity admin (user)
      (permissions list :required t))
    (let ((json (mcp-lisp:specs-to-json)))
      (mcp-lisp:clear-specs)
      (mcp-lisp:json-to-specs json)
      (is (equal '(user) (getf (mcp-lisp:describe-entity "admin") :supers))))))

;;; ---------------------------------------------------------------------------
;;; JSON Schema
;;; ---------------------------------------------------------------------------

(test spec-json-schema-structure
  "spec-json-schema returns a well-formed schema"
  (let ((schema (mcp-lisp:spec-json-schema)))
    (is (hash-table-p schema))
    (is (string= "https://json-schema.org/draft/2020-12/schema"
                  (gethash "$schema" schema)))
    (is (string= "object" (gethash "type" schema)))
    (let ((props (gethash "properties" schema)))
      (is (hash-table-p (gethash "entities" props)))
      (is (hash-table-p (gethash "rules" props)))
      (is (hash-table-p (gethash "invariants" props))))))
