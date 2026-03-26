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
         (mcp-lisp/src/spec/spec::*invariants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*variants* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenarios* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*scenario-generators* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*compiled-fn-cache* (make-hash-table :test #'equal))
         (mcp-lisp/src/spec/spec::*config* nil)
         (mcp-lisp/src/spec/spec::*current-config* nil))
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
      ;; 2 dangling rule entities + 1 dangling invariant entity + 1 trivially-true
      (is (= 4 (length warnings))))))

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
    (mcp-lisp:definvariant order-quantity-positive
      :on order
      :check (>= (order-quantity order) 0))
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
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (null (remove-if (lambda (w) (search "defgenerator" w)) warnings))))))

(test validate-specs-loop-hash-iteration-ok
  "validate-specs does not warn about loop hash iteration keywords"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant all-positive
      :on account
      :check (loop for k being the hash-keys of (account-balance account)
                   always (> k 0)))
    (is (null (mcp-lisp:validate-specs)))))

(test validate-specs-loop-binds-vars
  "validate-specs recognises loop for-var as bound"
  (with-fresh-specs
    (mcp-lisp:defentity portfolio ()
      (items list :required t))
    (mcp-lisp:definvariant items-positive
      :on portfolio
      :check (loop for item in (portfolio-items portfolio)
                   always (> item 0)))
    (is (null (mcp-lisp:validate-specs)))))

(test validate-specs-loop-destructuring-on
  "validate-specs recognises loop for (a b) on ... destructuring"
  (with-fresh-specs
    (mcp-lisp:defentity item ()
      (id string :required t)
      (val integer :required t :min 0 :max 100))
    (mcp-lisp:defscenario item-scenario
      :entities ((items (3 5) item)))
    (mcp-lisp:definvariant pairwise-ascending
      :on item-scenario
      :check (let ((sorted (sort (copy-list items) #'< :key (lambda (x) (getf x :val)))))
               (loop for (a b) on sorted while b
                     always (<= (getf a :val) (getf b :val)))))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (notany (lambda (w) (search "free variable A" w)) warnings))
      (is (notany (lambda (w) (search "free variable B" w)) warnings))
      (is (notany (lambda (w) (search "undefined function A" w)) warnings)))))

(test validate-specs-loop-destructuring-dotted
  "validate-specs recognises loop for (a . rest) on ... destructuring"
  (with-fresh-specs
    (mcp-lisp:defentity record ()
      (id string :required t)
      (vals list :required t))
    (mcp-lisp:definvariant first-positive
      :on record
      :check (loop for (head . tail) on (record-vals record)
                   always (or (null head) (> head 0))))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (notany (lambda (w) (search "free variable HEAD" w)) warnings))
      (is (notany (lambda (w) (search "free variable TAIL" w)) warnings))
      (is (notany (lambda (w) (search "undefined function HEAD" w)) warnings)))))

(test validate-specs-loop-destructuring-nested
  "validate-specs handles nested loop destructuring"
  (with-fresh-specs
    (mcp-lisp:defentity matrix ()
      (id string :required t)
      (rows list :required t))
    (mcp-lisp:definvariant rows-ok
      :on matrix
      :check (loop for ((x y) . rest) on (matrix-rows matrix)
                   always (or (null x) (numberp x))))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (notany (lambda (w) (search "free variable X" w)) warnings))
      (is (notany (lambda (w) (search "free variable Y" w)) warnings))
      (is (notany (lambda (w) (search "undefined function X" w)) warnings)))))

(test validate-specs-return-from-ok
  "validate-specs does not flag return-from block name as free variable"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant balance-check
      :on account
      :check (block check
               (return-from check (> (account-balance account) 0))))
    (is (null (mcp-lisp:validate-specs)))))

(test validate-specs-declare-in-lambda-ok
  "validate-specs does not flag declare forms inside lambdas"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant balance-check
      :on account
      :check (funcall (lambda (x) (declare (ignore x)) t) (account-balance account)))
    (is (null (mcp-lisp:validate-specs)))))

;;; ---------------------------------------------------------------------------
;;; defvariant
;;; ---------------------------------------------------------------------------

(test defvariant-stores-metadata
  "defvariant stores parent, discriminator, value, and fields"
  (with-fresh-specs
    (mcp-lisp:defentity node ()
      (id string :required t)
      (kind (member :branch :leaf)))
    (mcp-lisp:defvariant branch (node :kind :branch)
      (children list :required t))
    (let ((v (mcp-lisp:describe-variant "branch")))
      (is (not (null v)))
      (is (eq 'branch (getf v :name)))
      (is (string= "node" (getf v :parent)))
      (is (eq :kind (getf v :discriminator)))
      (is (eq :branch (getf v :value)))
      (is (= 1 (length (getf v :fields))))
      (is (equal '(children list :required t) (first (getf v :fields)))))))

(test defvariant-return-value
  "defvariant returns the variant name symbol"
  (with-fresh-specs
    (is (eq 'leaf (mcp-lisp:defvariant leaf (node :kind :leaf)
                    (data list :required t))))))

(test list-variants-populated
  "list-variants returns names of all registered variants"
  (with-fresh-specs
    (mcp-lisp:defvariant branch (node :kind :branch)
      (children list))
    (mcp-lisp:defvariant leaf (node :kind :leaf)
      (data list))
    (let ((vs (mcp-lisp:list-variants)))
      (is (= 2 (length vs)))
      (is (member "branch" vs :test #'string=))
      (is (member "leaf" vs :test #'string=)))))

(test entity-variants-returns-children
  "entity-variants returns variant keys for a given entity"
  (with-fresh-specs
    (mcp-lisp:defentity node ()
      (id string)
      (kind (member :branch :leaf)))
    (mcp-lisp:defvariant branch (node :kind :branch)
      (children list))
    (mcp-lisp:defvariant leaf (node :kind :leaf)
      (data list))
    (let ((vs (mcp-lisp:entity-variants "node")))
      (is (= 2 (length vs)))
      (is (member "branch" vs :test #'string=))
      (is (member "leaf" vs :test #'string=)))))

(test entity-variants-empty-for-non-variant-entity
  "entity-variants returns nil for entity without variants"
  (with-fresh-specs
    (mcp-lisp:defentity user () (id string))
    (is (null (mcp-lisp:entity-variants "user")))))

(test clear-specs-clears-variants
  "clear-specs removes variants"
  (with-fresh-specs
    (mcp-lisp:defvariant branch (node :kind :branch)
      (children list))
    (is (= 1 (length (mcp-lisp:list-variants))))
    (mcp-lisp:clear-specs)
    (is (null (mcp-lisp:list-variants)))))

(test validate-specs-variant-invariant-ok
  "validate-specs accepts invariants whose :on is a variant name"
  (with-fresh-specs
    (mcp-lisp:defentity node ()
      (id string)
      (kind (member :branch :leaf)))
    (mcp-lisp:defvariant branch (node :kind :branch)
      (children list :required t))
    (mcp-lisp:definvariant node-has-kind
      :on node
      :check (node-kind node))
    (mcp-lisp:definvariant branch-has-children
      :on branch
      :check (> (length (branch-children branch)) 0))
    (is (null (mcp-lisp:validate-specs)))))

(test validate-specs-exhaustiveness-warning
  "validate-specs warns when rules handle some but not all variants"
  (with-fresh-specs
    (mcp-lisp:defentity node ()
      (id string)
      (kind (member :branch :leaf)))
    (mcp-lisp:defvariant branch (node :kind :branch)
      (children list))
    (mcp-lisp:defvariant leaf (node :kind :leaf)
      (data list))
    (mcp-lisp:definvariant node-has-kind
      :on node
      :check (node-kind node))
    ;; Rule handles :branch but not :leaf
    (mcp-lisp:defrule process-branch
      :when (node :kind :branch)
      :ensures ((not (null (node-id node)))))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (= 1 (length warnings)))
      (is (search "LEAF" (first warnings))))))

(test validate-specs-exhaustiveness-no-warning-when-all-handled
  "validate-specs does not warn when all variants are handled"
  (with-fresh-specs
    (mcp-lisp:defentity node ()
      (id string)
      (kind (member :branch :leaf)))
    (mcp-lisp:defvariant branch (node :kind :branch)
      (children list))
    (mcp-lisp:defvariant leaf (node :kind :leaf)
      (data list))
    (mcp-lisp:definvariant node-has-kind
      :on node
      :check (node-kind node))
    (mcp-lisp:defrule process-branch
      :when (node :kind :branch)
      :ensures ((not (null (node-id node)))))
    (mcp-lisp:defrule process-leaf
      :when (node :kind :leaf)
      :ensures ((not (null (node-id node)))))
    (is (null (mcp-lisp:validate-specs)))))

;;; ---------------------------------------------------------------------------
;;; defconfig
;;; ---------------------------------------------------------------------------

(test defconfig-stores-fields
  "defconfig stores field specs in *config*"
  (with-fresh-specs
    (mcp-lisp:defconfig
      (max-leverage number :default 10.0 :min 1.0 :max 100.0)
      (margin-call-threshold number :default 0.5 :min 0.0 :max 1.0)
      (allow-short-selling boolean :default t))
    (let ((fields (mcp-lisp:config-fields)))
      (is (= 3 (length fields)))
      (is (eq 'max-leverage (first (first fields))))
      (is (eq 'number (second (first fields))))
      (is (= 10.0 (getf (cddr (first fields)) :default))))))

(test describe-config-returns-fields
  "describe-config returns config field specs"
  (with-fresh-specs
    (mcp-lisp:defconfig
      (max-retries integer :default 3 :min 1 :max 10))
    (is (= 1 (length (mcp-lisp:describe-config))))
    (is (eq 'integer (second (first (mcp-lisp:describe-config)))))))

(test defconfig-nil-when-not-defined
  "describe-config returns NIL when no config defined"
  (with-fresh-specs
    (is (null (mcp-lisp:describe-config)))))

(test clear-specs-clears-config
  "clear-specs resets config"
  (with-fresh-specs
    (mcp-lisp:defconfig (x number :default 1.0))
    (is (not (null (mcp-lisp:config-fields))))
    (mcp-lisp:clear-specs)
    (is (null (mcp-lisp:config-fields)))))

(test validate-specs-config-accessor-ok
  "validate-specs does not warn about (config :key) in invariant :check"
  (with-fresh-specs
    (mcp-lisp:defentity position ()
      (leverage number :required t))
    (mcp-lisp:defconfig
      (max-leverage number :default 10.0 :min 1.0 :max 100.0))
    (mcp-lisp:definvariant leverage-limit
      :on position
      :check (<= (position-leverage position) (mcp-lisp:config :max-leverage)))
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
      ;; Derived — expression is now an AST node
      (let ((der (aref (gethash "derived" user) 0)))
        (is (string= "display-name" (gethash "name" der)))
        (let ((expr (gethash "expression" der)))
          (is (string= "lambda" (gethash "node" expr)))
          (is (string= "u" (aref (gethash "params" expr) 0)))
          (let ((body (gethash "body" expr)))
            (is (string= "call" (gethash "node" body)))
            (is (string= "name" (gethash "fn" body)))))))))

(test specs-to-json-rules
  "specs-to-json serializes rules as AST"
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
      ;; when → call node (order :state :draft)
      (let ((when-ast (gethash "when" rule)))
        (is (string= "call" (gethash "node" when-ast)))
        (is (string= "order" (gethash "fn" when-ast))))
      ;; let → structured binding
      (let ((binding (aref (gethash "let" rule) 0)))
        (is (string= "customer" (gethash "name" binding)))
        (let ((val (gethash "value" binding)))
          (is (string= "call" (gethash "node" val)))
          (is (string= "order-customer" (gethash "fn" val)))))
      ;; requires → call node
      (let ((req (aref (gethash "requires" rule) 0)))
        (is (string= "call" (gethash "node" req)))
        (is (string= "active-account-p" (gethash "fn" req))))
      ;; ensures → eq node
      (let ((ens (aref (gethash "ensures" rule) 0)))
        (is (string= "eq" (gethash "node" ens)))))))

(test specs-to-json-invariants
  "specs-to-json serializes invariants as AST"
  (with-fresh-specs
    (mcp-lisp:definvariant positive-balance
      :on account
      :check (>= (balance account) 0))
    (let* ((json (mcp-lisp:specs-to-json))
           (data (mcp-lisp:decode-json json))
           (inv (gethash "positive-balance" (gethash "invariants" data))))
      (is (string= "positive-balance" (gethash "name" inv)))
      (is (string= "account" (gethash "on" inv)))
      ;; check → compare node
      (let ((check (gethash "check" inv)))
        (is (string= "compare" (gethash "node" check)))
        (is (string= ">=" (gethash "op" check)))
        ;; left: (balance account) → call node
        (let ((left (gethash "left" check)))
          (is (string= "call" (gethash "node" left)))
          (is (string= "balance" (gethash "fn" left))))
        ;; right: 0 → literal node
        (let ((right (gethash "right" check)))
          (is (string= "literal" (gethash "node" right)))
          (is (= 0 (gethash "value" right))))))))

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

(test json-round-trip-variants
  "json-to-specs restores variants from exported JSON"
  (with-fresh-specs
    (mcp-lisp:defentity node ()
      (id string :required t)
      (kind (member :branch :leaf)))
    (mcp-lisp:defvariant branch (node :kind :branch)
      (children list :required t))
    (mcp-lisp:defvariant leaf (node :kind :leaf)
      (data list))
    (let ((json (mcp-lisp:specs-to-json)))
      (mcp-lisp:clear-specs)
      (is (null (mcp-lisp:list-variants)))
      (mcp-lisp:json-to-specs json)
      ;; Variants restored
      (is (= 2 (length (mcp-lisp:list-variants))))
      (let ((branch (mcp-lisp:describe-variant "branch")))
        (is (not (null branch)))
        (is (string= "node" (getf branch :parent)))
        (is (eq :kind (getf branch :discriminator)))
        (is (eq :branch (getf branch :value)))
        (is (= 1 (length (getf branch :fields))))
        (is (eq 'children (first (first (getf branch :fields)))))))))

(test specs-to-json-variants
  "specs-to-json serializes variants"
  (with-fresh-specs
    (mcp-lisp:defvariant branch (node :kind :branch)
      (children list :required t))
    (let* ((json (mcp-lisp:specs-to-json))
           (data (mcp-lisp:decode-json json))
           (variants (gethash "variants" data))
           (branch (gethash "branch" variants)))
      (is (string= "branch" (gethash "name" branch)))
      (is (string= "node" (gethash "parent" branch)))
      (is (string= "kind" (gethash "discriminator" branch)))
      (is (string= "branch" (gethash "value" branch)))
      (let ((fields (gethash "fields" branch)))
        (is (= 1 (length fields)))
        (is (string= "children" (gethash "name" (aref fields 0))))))))

(test json-round-trip-config
  "json-to-specs restores config from exported JSON"
  (with-fresh-specs
    (mcp-lisp:defconfig
      (max-leverage number :default 10.0 :min 1.0 :max 100.0)
      (allow-short boolean :default t))
    (let ((json (mcp-lisp:specs-to-json)))
      (mcp-lisp:clear-specs)
      (is (null (mcp-lisp:config-fields)))
      (mcp-lisp:json-to-specs json)
      (is (= 2 (length (mcp-lisp:config-fields))))
      (let ((first-field (first (mcp-lisp:config-fields))))
        (is (eq 'max-leverage (first first-field)))
        (is (eq 'number (second first-field)))
        (is (= 1.0 (getf (cddr first-field) :min)))
        (is (= 100.0 (getf (cddr first-field) :max)))))))

(test specs-to-json-config
  "specs-to-json serializes config fields"
  (with-fresh-specs
    (mcp-lisp:defconfig
      (max-leverage number :default 10.0 :min 1.0 :max 100.0))
    (let* ((json (mcp-lisp:specs-to-json))
           (data (mcp-lisp:decode-json json))
           (config (gethash "config" data))
           (fields (gethash "fields" config)))
      (is (= 1 (length fields)))
      (let ((f (aref fields 0)))
        (is (string= "max-leverage" (gethash "name" f)))
        (is (string= "number" (gethash "type" f)))
        (is (= 1.0 (gethash "min" f)))
        (is (= 100.0 (gethash "max" f)))))))

(test specs-to-json-no-config-key-when-empty
  "specs-to-json omits config key when no config defined"
  (with-fresh-specs
    (mcp-lisp:defentity user () (id string))
    (let* ((json (mcp-lisp:specs-to-json))
           (data (mcp-lisp:decode-json json)))
      (is (null (gethash "config" data))))))

;;; ---------------------------------------------------------------------------
;;; JSON Schema
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; defscenario
;;; ---------------------------------------------------------------------------

(test defscenario-basic
  "defscenario stores entity specs with parsed cardinality"
  (with-fresh-specs
    (mcp-lisp:defentity order ()
      (id string :required t)
      (total number :required t))
    (mcp-lisp:defentity line-item ()
      (id string :required t)
      (qty number :required t)
      (:belongs-to order))
    (mcp-lisp:defscenario order-scenario
      :entities ((orders (1 3) order)
                 (items  (2 5) line-item :per orders)))
    (is (= 1 (length (mcp-lisp:list-scenarios))))
    (let ((s (mcp-lisp:describe-scenario "order-scenario")))
      (is (not (null s)))
      (is (= 2 (length (getf s :entities))))
      ;; First entity spec
      (let ((e1 (first (getf s :entities))))
        (is (eq :orders (getf e1 :binding)))
        (is (string= "order" (getf e1 :entity)))
        (is (= 1 (getf e1 :min)))
        (is (= 3 (getf e1 :max)))
        (is (null (getf e1 :per))))
      ;; Second entity spec with :per
      (let ((e2 (second (getf s :entities))))
        (is (eq :items (getf e2 :binding)))
        (is (string= "line-item" (getf e2 :entity)))
        (is (= 2 (getf e2 :min)))
        (is (= 5 (getf e2 :max)))
        (is (eq :orders (getf e2 :per)))))))

(test defscenario-exact-cardinality
  "defscenario with exact cardinality (number, not list)"
  (with-fresh-specs
    (mcp-lisp:defentity widget ()
      (id string :required t))
    (mcp-lisp:defscenario single-widget
      :entities ((w 1 widget)))
    (let* ((s (mcp-lisp:describe-scenario "single-widget"))
           (e1 (first (getf s :entities))))
      (is (= 1 (getf e1 :min)))
      (is (= 1 (getf e1 :max))))))

(test defscenario-clear-specs
  "clear-specs clears scenarios"
  (with-fresh-specs
    (mcp-lisp:defentity widget ()
      (id string :required t))
    (mcp-lisp:defscenario test-scenario
      :entities ((w (1 2) widget)))
    (is (= 1 (length (mcp-lisp:list-scenarios))))
    (mcp-lisp:clear-specs)
    (is (= 0 (length (mcp-lisp:list-scenarios))))))

(test validate-specs-scenario-entity-ref
  "validate-specs catches unknown entity in scenario"
  (with-fresh-specs
    (mcp-lisp:defscenario bad-scenario
      :entities ((things (1 3) nonexistent-entity)))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (plusp (length warnings)))
      (is (search "not defined" (first warnings))))))

(test validate-specs-scenario-per-ref
  "validate-specs catches :per referencing unknown binding"
  (with-fresh-specs
    (mcp-lisp:defentity widget ()
      (id string :required t))
    (mcp-lisp:defentity part ()
      (id string :required t)
      (:belongs-to widget))
    (mcp-lisp:defscenario bad-per
      :entities ((parts (2 3) part :per missing-parent)))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (plusp (length warnings)))
      (is (search "unknown binding" (first warnings))))))

(test validate-specs-scenario-invariant-on
  "validate-specs accepts scenario name in invariant :on"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:defscenario bank-test
      :entities ((accounts (2 5) account)))
    (mcp-lisp:definvariant total-positive
      :on bank-test
      :check (> (reduce #'+ accounts :key (lambda (a) (getf a :balance))) 0))
    (let ((warnings (mcp-lisp:validate-specs)))
      ;; No warning about unknown entity for :on bank-test
      (is (notany (lambda (w) (search "unknown entity/scenario" w)) warnings)))))

(test defscenario-json-roundtrip
  "scenarios survive JSON serialization and deserialization"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (id string :required t)
      (balance number :required t))
    (mcp-lisp:defentity txn ()
      (id string :required t)
      (amount number :required t)
      (:belongs-to account))
    (mcp-lisp:defscenario ledger
      :entities ((accounts (2 4) account)
                 (txns (1 10) txn :per accounts)))
    (let ((json (mcp-lisp:specs-to-json)))
      (mcp-lisp:clear-specs)
      (is (= 0 (length (mcp-lisp:list-scenarios))))
      (mcp-lisp:json-to-specs json)
      (is (= 1 (length (mcp-lisp:list-scenarios))))
      (let* ((s (mcp-lisp:describe-scenario "ledger"))
             (entities (getf s :entities)))
        (is (= 2 (length entities)))
        (let ((e1 (first entities)))
          (is (eq :accounts (getf e1 :binding)))
          (is (string= "account" (getf e1 :entity)))
          (is (= 2 (getf e1 :min)))
          (is (= 4 (getf e1 :max)))
          (is (null (getf e1 :per))))
        (let ((e2 (second entities)))
          (is (eq :txns (getf e2 :binding)))
          (is (string= "txn" (getf e2 :entity)))
          (is (= 1 (getf e2 :min)))
          (is (= 10 (getf e2 :max)))
          (is (eq :accounts (getf e2 :per))))))))

;;; ---------------------------------------------------------------------------
;;; JSON Schema
;;; ---------------------------------------------------------------------------

(test spec-json-schema-structure
  "spec-json-schema returns a well-formed schema with AST $defs"
  (let ((schema (mcp-lisp:spec-json-schema)))
    (is (hash-table-p schema))
    (is (string= "https://json-schema.org/draft/2020-12/schema"
                  (gethash "$schema" schema)))
    (is (string= "object" (gethash "type" schema)))
    (let ((props (gethash "properties" schema)))
      (is (hash-table-p (gethash "entities" props)))
      (is (hash-table-p (gethash "rules" props)))
      (is (hash-table-p (gethash "invariants" props)))
      (is (hash-table-p (gethash "variants" props)))
      (is (hash-table-p (gethash "config" props))))
    ;; $defs contains expr and binding schemas
    (let ((defs (gethash "$defs" schema)))
      (is (hash-table-p defs))
      (is (hash-table-p (gethash "expr" defs)))
      (is (hash-table-p (gethash "binding" defs)))
      ;; expr uses discriminated union
      (let ((expr (gethash "expr" defs)))
        (is (not (null (gethash "oneOf" expr))))
        (is (hash-table-p (gethash "discriminator" expr)))
        (is (string= "node" (gethash "propertyName"
                                      (gethash "discriminator" expr))))))))

;;; ---------------------------------------------------------------------------
;;; Regression: specs-to-lisp derived round-trip
;;; ---------------------------------------------------------------------------

(test specs-to-lisp-derived-round-trip
  "specs-to-lisp emits (:derived name expr), not (:derived :derived name)"
  (with-fresh-specs
    (mcp-lisp:defentity user ()
      (id string :required t)
      (email string :required t)
      (:derived display-name (lambda (u) (or (user-name u) (user-email u)))))
    (let ((lisp-str (mcp-lisp:specs-to-lisp)))
      (is (search ":derived" lisp-str))
      (is (search "display-name" lisp-str))
      (is (search "lambda" lisp-str))
      ;; Must NOT have (:derived :derived ...)
      (is (null (search ":derived :derived" lisp-str))))))

;;; ---------------------------------------------------------------------------
;;; Regression: JSON round-trip resolves pbt helper symbols
;;; ---------------------------------------------------------------------------

(test json-round-trip-pbt-helper-symbols
  "ast-to-form resolves all-pairs-check to pbt package after JSON round-trip"
  (with-fresh-specs
    (mcp-lisp:defentity segment ()
      (id string :required t)
      (value number :required t))

    (mcp-lisp:defscenario segment-check
      :entities ((segments (2 4) segment)))

    ;; Invariant that calls all-pairs-check — a pbt-package function
    (mcp-lisp:definvariant segments-distinct
      :on segment-check
      :check (all-pairs-check segments
               (lambda (a b)
                 (not (equal (getf a :id) (getf b :id))))))

    (let* ((json (mcp-lisp:specs-to-json))
           (_ (mcp-lisp:clear-specs))
           (__ (mcp-lisp:json-to-specs json)))
      (declare (ignore _ __))
      ;; After round-trip, the call head must resolve to the pbt symbol
      ;; (not a dead symbol in the spec package)
      (let* ((inv (mcp-lisp:describe-invariant "segments-distinct"))
             (head (car (getf inv :check))))
        (is (not (null inv)))
        (is (fboundp head))
        (is (eq (find-symbol "ALL-PAIRS-CHECK" :mcp-lisp/src/spec/pbt)
                head))))))

;;; ---------------------------------------------------------------------------
;;; Bug 7: validate-specs warns on trivially-true invariants
;;; ---------------------------------------------------------------------------

(test validate-specs-trivially-true-invariant
  "validate-specs warns when :check is a constant like T"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant always-true
      :on account
      :check t)
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (plusp (length warnings)))
      (is (some (lambda (w) (search "constant" w)) warnings))
      (is (some (lambda (w) (search "trivially true" w)) warnings)))))

(test validate-specs-trivially-true-number
  "validate-specs warns when :check is a numeric constant"
  (with-fresh-specs
    (mcp-lisp:defentity account ()
      (balance number :required t))
    (mcp-lisp:definvariant always-truthy
      :on account
      :check 42)
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (some (lambda (w) (search "constant" w)) warnings)))))

;;; ---------------------------------------------------------------------------
;;; validate-specs: has-many accessor in entity invariants
;;; ---------------------------------------------------------------------------

(test validate-specs-has-many-accessor-warning
  "validate-specs warns when entity-level invariant uses has-many accessor"
  (with-fresh-specs
    (mcp-lisp:defentity curve ()
      (id string :required t)
      (:has-many data-points :of data-point :cardinality (2 100)))
    (mcp-lisp:defentity data-point ()
      (id string :required t)
      (x-value number :required t))
    (mcp-lisp:definvariant curve-min-two-points
      :on curve
      :check (>= (length (curve-data-points curve)) 2))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (some (lambda (w) (search "has-many accessor" w)) warnings))
      (is (some (lambda (w) (search "only testable via scenario" w)) warnings)))))

(test validate-specs-has-many-accessor-no-false-positive
  "validate-specs does not warn about has-many accessor in scenario invariants"
  (with-fresh-specs
    (mcp-lisp:defentity team ()
      (id string :required t)
      (:has-many members :of player :cardinality (1 5)))
    (mcp-lisp:defentity player ()
      (id string :required t)
      (:belongs-to team))
    (mcp-lisp:defscenario roster
      :entities ((team 1 team)
                 (players (1 5) player)))
    (mcp-lisp:definvariant has-players
      :on roster
      :check (>= (length players) 1))
    (let ((warnings (mcp-lisp:validate-specs)))
      (is (notany (lambda (w) (search "has-many accessor" w)) warnings)))))
