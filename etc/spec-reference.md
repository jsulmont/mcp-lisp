## Spec DSL Reference

All macros and functions are available in the `eval_lisp` sandbox with no imports.

### Defining specs

```lisp
;; Entities — typed fields, relations, derived values
(defentity user ()
  (id string :required t :unique t)
  (name string)
  (email string :required t)
  (role (member :admin :member :guest) :default :member)
  (:has-many orders :of order)
  (:derived display-name (lambda (u) (or (name u) (email u)))))

;; Variants — discriminated unions (sum types)
(defentity node ()
  (id string :required t)
  (kind (member :branch :leaf)))

(defvariant branch (node :kind :branch)
  (children list :required t))

(defvariant leaf (node :kind :leaf)
  (data list :required t))

;; Config — typed configuration with defaults and ranges
(defconfig
  (max-leverage number :default 10.0 :min 1.0 :max 100.0)
  (margin-call-threshold number :default 0.5 :min 0.0 :max 1.0)
  (allow-short-selling boolean :default t))

;; Rules — state transition metadata (when/requires/sets/ensures)
(defrule place-order
  :when (order :state :draft)
  :let ((customer (order-customer order)))
  :requires ((active-account-p customer)
             (pos (account-balance customer)))
  :sets ((order-placed-at order) (get-universal-time))
  :ensures ((eq (order-state order) :placed)))

;; Invariants — properties that must always hold
(definvariant non-negative-balance
  :on account
  :check (>= (account-balance account) 0))

;; Invariants can reference config via (config :key)
(definvariant leverage-limit
  :on position
  :check (<= (position-leverage position) (config :max-leverage)))

;; Invariants can target a specific variant
(definvariant branch-has-children
  :on branch
  :check (> (length (branch-children branch)) 0))

;; Scenarios — use when invariants span multiple entity types or when
;; valid instances require correlated generation across entities
(defscenario order-fulfillment
  :entities ((warehouses (1 3) warehouse)
             (orders     (5 20) order)
             (items      (1 5) line-item :per orders)))

;; Scenario invariants — binding names become variables in the check form
(definvariant total-items-match
  :on order-fulfillment
  :check (= (reduce #'+ orders :key #'order-item-count)
             (length items)))
```

#### `:sets` clause

The `:sets` clause takes alternating `(accessor-form value-form)` pairs. Each accessor identifies the field to set; the value-form is evaluated with the entity instance and `:let` bindings in scope. Use `:sets` when a state transition must update non-state fields (e.g. setting `enabled=nil` on soft-delete, or recording a timestamp). Without `:sets`, `random-walk` will trigger invariant violations for any rule that changes state without updating correlated fields.

#### Scenario binding semantics

- Cardinality `(min max)` (e.g. `(1 3)`) always produces a **list**, even when the random count is 1. Use `every`, `reduce`, `mapcar` to iterate.
- Cardinality `1` (bare number) produces a **single plist**. Access fields directly with `getf`.

### Querying specs

- `(list-entities)`, `(describe-entity name)`, `(entity-fields name)`, `(entity-relations name)`
- `(list-rules)`, `(describe-rule name)`
- `(list-invariants)`, `(describe-invariant name)`
- `(list-variants)`, `(describe-variant name)`, `(entity-variants entity-name)`
- `(list-scenarios)`, `(describe-scenario name)`
- `(describe-config)`, `(config-fields)`
- `(validate-specs)` — catches dangling entity references, undefined functions, free variables, non-exhaustive variant handling, invalid scenario bindings, entities with zero invariant coverage, uncovered FK-like fields/belongs-to relations, and config keys referenced by scenario invariants but missing from their generators
- `(suggest-invariants)` — proposes `defscenario` + `definvariant` skeletons for relations and config fields
- `(clear-specs)` — reset all registries

### Spec analysis

```lisp
;; Which fields are covered by invariants? NIL = unconstrained.
(invariant-coverage "generator")
;; → ((:STATE "output-matches-state" "output-within-bounds")
;;    (:START-COST)       ;; ← no coverage
;;    (:MARGINAL-COST))   ;; ← no coverage

;; Reverse lookup: what invariants and rules touch a field?
(field-index "generator" :output-mw)
;; → (:INVARIANTS ("output-matches-state" "output-within-bounds")
;;    :RULES (("ramp-generator" . :REQUIRES) ("ramp-generator" . :ENSURES)))

;; Can the default generator produce valid instances?
(generation-feasibility "generator")
;; → (:VERDICT :NEEDS-CUSTOM-GENERATOR
;;    :CONDITIONAL-CONSTRAINTS (:OUTPUT-MW :EMISSIONS-RATE ...)
;;    :UNCONSTRAINED-FIELDS (:ID :NAME :START-COST ...))

;; Does a scenario need a custom generator?
(scenario-feasibility "full-dispatch")
;; → (:NEEDS-CUSTOM-GENERATOR T
;;    :HAS-CUSTOM-GENERATOR T
;;    :VERDICT :OK)

;; Step through rules on a concrete instance
(simulate-trace "generator" instance '("start-generator" "sync-generator"))
;; → per-step: rule, from/to state, each guard pass/fail, instance-after
```

### Property-based testing

```lisp
(run-pbt :trials 200)

;; With config: test across random configuration space
(run-pbt :trials 100 :config-trials 5)

;; Test a specific scenario (cross-entity invariants)
(run-pbt :scenario "order-fulfillment" :trials 50)

;; Positive + negative: verify invariants pass on smart data, reject random data
(run-pbt :trials 200 :negative-trials 100)
```

`run-pbt` generates random instances for every entity that has invariants, checks all applicable invariants (including variant-specific ones), and reports counterexamples on failure. When `defconfig` is defined, `:config-trials` (default 5) generates random configs within declared bounds.

For entities with variants, `generate-instance` picks a random variant, sets the discriminator, and generates variant-specific fields. Invariants on the base entity apply to all variants; invariants on a variant name apply only when the discriminator matches.

Use `(check-invariants "entity-name" instance)` for targeted checking and `(generate-instance "entity-name")` to produce test data.

#### Negative trials

The negative pass generates unconstrained random instances (no constraint extraction, no retry) and checks that each invariant correctly rejects them. Invariants that pass 100% of random data are classified:
- **Structurally untestable** — uniqueness checks over high-entropy fields (collision probability ~0); safe to ignore
- **Weak bounds** — comparison operators referencing `(config :key)` where the generation range is too narrow to violate; test with extreme config values

#### Invariant-aware generation

The default generator automatically extracts constraints from invariant `:check` forms to produce valid instances. It handles:

- **Constant bounds**: `(>= field 0)`, `(< field 100)` → narrows numeric range
- **Field ordering**: `(< min-output max-output)` → generates in dependency order
- **Arithmetic expressions**: `(= notional (* quantity price))`, `(= total (+ base tax))` → computes derived field from any pure arithmetic expression (`+`, `-`, `*`, `/`, `abs`, `mod`, `expt`, `min`, `max`) over other fields and constants. Also works for inequalities: `(<= field (- max-val offset))` → upper bound computed from expression
- **Boolean conditionals**: `(if (trader-suspended trader) (< margin-ratio 0.5) t)` → applies bounds when boolean field is true
- **Conditional constraints**: `(if (eq state :online) (>= output min-output) t)` → applies bounds only when condition holds
- **Member conditions**: `(if (member fuel '(:hydro :wind :solar)) (= emissions 0) (> emissions 0))`
- **Disjunctive state patterns**: `(or (and (eq state :idle) (= rate 0)) (and (eq state :charging) (< rate 0)))` → per-state constraints
- **Config references**: `(<= (position-leverage position) (config :max-leverage))` → resolves bound from current config at generation time

Member/enum and boolean fields are generated first, then numeric fields in topologically sorted dependency order (expression deps and conditional deps are both tracked). A retry loop (10 attempts) catches constraints too complex for static extraction.

The extractor cannot solve constraints where neither side of a comparison is a single field access (e.g. `(= (+ a b) (* c c))`). Use `defgenerator` for those cases.

Use `(extract-generation-constraints "entity-name")` to inspect what the extractor found.

#### Custom generators

For constraints the extractor can't handle, use `defgenerator`:

```lisp
(defgenerator triple (overrides)
  (let* ((inst (default-generate-instance "triple" overrides))
         (a (getf inst :a))
         (b (getf inst :b)))
    (setf (getf inst :result) (- (* b b) a))
    inst))
```

- `defgenerator` registers a generator function for an entity. It receives `overrides` (an alist of `(keyword . value)` or NIL) and must return a plist.
- `default-generate-instance` is the constraint-aware generator — use it as a base, then fix up remaining dependencies.
- `generate-value` is available for generating individual typed values (e.g. `(generate-value 'number :min 0.0 :max 10.0)`).
- `clear-specs` also clears registered generators.

#### Custom scenario generators

**You MUST write a `defscenario-generator` whenever a scenario has invariants that compute aggregates, sums, or cross-references across entity bindings** (e.g. "total equals sum of parts", "transfers net to zero", "priority ordering across contracts"). Default random generation will never satisfy these.

```lisp
(defscenario-generator order-fulfillment (overrides)
  (declare (ignore overrides))
  (let* ((warehouses (list (generate-instance "warehouse")))
         (orders (loop repeat 5 collect (generate-instance "order")))
         (items (loop for o in orders
                      append (loop repeat (getf o :item-count)
                                   collect (generate-instance "line-item")))))
    (list :warehouses warehouses :orders orders :items items)))
```

- Returns a plist mapping binding keywords to instances (lists for plural bindings, single plist for cardinality=1).
- `generate-scenario` dispatches to custom generator if registered, otherwise uses `default-generate-scenario`.
- In `defscenario-generator`, use `(or (config :key) default)` since config values are only populated during PBT runs. Outside PBT, `(config :key)` returns the field's `:default` from `defconfig`, but if no default was declared it returns NIL.

### State machine analysis

Rules with `:when`/`:ensures` patterns implicitly define state machines:

```lisp
(detect-state-fields "order")        ; → (:STATE)
(extract-transitions "order")        ; → ((:from :draft :to :placed :via PLACE-ORDER :guards (...)) ...)

(analyze-state-machine "order")      ; → full analysis: states, initial, terminal, unreachable, dead-ends
(terminal-states "order")            ; → (:filled :cancelled)
(unreachable-states "order")         ; → states with no incoming edge (minus initial)
(dead-end-states "order")            ; → non-terminal states stuck in a cycle

(validate-transitions)               ; → warns about unreachable states and dead ends
```

A state field is a `(member ...)` field that appears as a source in at least one rule's `:when` AND as a target in at least one rule's `:ensures`.

### Rule execution

```lisp
;; Apply a single rule — returns (values new-instance applied-p reason)
(apply-rule "order" instance "fill-order")
;; → (values new-instance t nil)               ; applied
;; → (values instance nil :when-mismatch)       ; wrong state
;; → (values instance nil (:guard-failed form)) ; :requires failed
;; → (values instance nil :unknown-rule)        ; rule doesn't exist

;; Which rules can fire on this instance?
(applicable-rules "order" instance)

;; Random walk PBT: generate instances, apply random rules, check invariants
(random-walk "order" :steps 20 :trials 50)
```

`random-walk` generates instances in the initial state, then repeatedly picks a random applicable rule, applies it, and checks all invariants. It reports the first violation with the rule trace that caused it.

### Code generation

```lisp
(specs-to-sql)                          ; → PostgreSQL DDL (enums, tables, CHECK, FK, indexes, triggers)
(specs-to-sql-seed :rows-per-entity 20) ; → INSERT statements with invariant-consistent random data
(specs-to-lisp)                         ; → loadable .lisp file with all spec forms
```

### JSON persistence

- `(specs-to-json)` — export all specs as JSON (conforms to JSON Schema 2020-12)
- `(json-to-specs json-string)` — import specs from JSON (merges; call `clear-specs` first for clean import)
- `(spec-json-schema)` — returns the JSON Schema
