## Behavioral Specs

This project uses a behavioral specification DSL via the `eval_lisp` MCP tool. When the user describes a domain model, entities, rules, or business logic, define specs BEFORE writing code.

### Defining specs

All macros are available in the sandbox with no imports:

```lisp
;; Entities — typed fields, relations, derived values
(defentity user ()
  (id string :required t :unique t)
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

;; Rules — state transition metadata (when/requires/ensures)
(defrule place-order
  :when (order :state :draft)
  :let ((customer (order-customer order)))
  :requires ((active-account-p customer)
             (pos (account-balance customer)))
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

;; Scenarios — use defscenario when an invariant references fields from
;; multiple entity types, or when valid instances require correlated
;; generation across entities (e.g. totals must match sums of parts).
(defscenario order-fulfillment
  :entities ((warehouses (1 3) warehouse)
             (orders     (5 20) order)
             (items      (1 5) line-item :per orders)))

;; Scenario invariants — check properties across entity boundaries
;; Binding names from defscenario become variables in the check form
(definvariant total-items-match
  :on order-fulfillment
  :check (= (reduce #'+ orders :key #'order-item-count)
             (length items)))
```

### Querying specs

- `(list-entities)`, `(describe-entity name)`, `(entity-fields name)`, `(entity-relations name)`
- `(list-rules)`, `(describe-rule name)`
- `(list-invariants)`, `(describe-invariant name)`
- `(list-variants)`, `(describe-variant name)`, `(entity-variants entity-name)`
- `(list-scenarios)`, `(describe-scenario name)`
- `(describe-config)`, `(config-fields)`
- `(validate-specs)` — catches dangling entity references, undefined functions, free variables, non-exhaustive variant handling, and invalid scenario bindings
- `(clear-specs)` — reset all registries

### Property-based testing

Generate random entity instances and check invariants automatically:

```lisp
(run-pbt :trials 200)

;; With config: test across random configuration space
(run-pbt :trials 100 :config-trials 5)

;; Test a specific scenario (cross-entity invariants)
(run-pbt :scenario "order-fulfillment" :trials 50)
```

This generates random instances for every entity that has invariants, checks all applicable invariants (including variant-specific ones), and reports counterexamples on failure. When `defconfig` is defined, `:config-trials` (default 5) generates random configs within declared bounds — catching specs that only hold for the default config.

For entities with variants, `generate-instance` picks a random variant, sets the discriminator, and generates variant-specific fields. Invariants on the base entity apply to all variants; invariants on a variant name apply only when the discriminator matches.

Use `(check-invariants "entity-name" instance)` for targeted checking and `(generate-instance "entity-name")` to produce test data.

#### Invariant-aware generation

The default generator automatically extracts constraints from invariant `:check` forms to produce valid instances. It handles:

- **Constant bounds**: `(>= field 0)`, `(< field 100)` → narrows numeric range
- **Field ordering**: `(< min-output max-output)` → generates in dependency order
- **Scaled references**: `(>= min-output (* 0.5 max-output))` → computes bound from other field
- **Conditional constraints**: `(if (eq state :online) (>= output min-output) t)` → applies bounds only when condition holds
- **Member conditions**: `(if (member fuel '(:hydro :wind :solar)) (= emissions 0) (> emissions 0))`
- **Disjunctive state patterns**: `(or (and (eq state :idle) (= rate 0)) (and (eq state :charging) (< rate 0)))` → per-state constraints
- **Config references**: `(<= (position-leverage position) (config :max-leverage))` → resolves bound from current config at generation time

Member/enum fields are generated first, then numeric fields in topologically sorted dependency order. A retry loop (10 attempts) catches constraints too complex for static extraction.

Use `(extract-generation-constraints "entity-name")` to inspect what the extractor found.

#### Custom generators

For constraints the extractor can't handle (complex arithmetic across multiple fields, iterative computations), use `defgenerator` as an escape hatch:

```lisp
(defgenerator trader (overrides)
  (let ((inst (default-generate-instance "trader" overrides)))
    (when (getf inst :suspended)
      (setf (getf inst :margin-ratio)
            (generate-value 'number :min 0.0 :max 0.5)))
    inst))
```

- `defgenerator` registers a generator function for an entity. It receives `overrides` (an alist of `(keyword . value)` or NIL) and must return a plist.
- `default-generate-instance` is the constraint-aware generator — use it as a base, then fix up remaining dependencies.
- `generate-value` is available for generating individual typed values (e.g. `(generate-value 'number :min 0.0 :max 10.0)`).
- `clear-specs` also clears registered generators.

#### Custom scenario generators

For scenarios where instances must be correlated across entities, use `defscenario-generator`:

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

### State machine analysis

Rules with `:when`/`:ensures` patterns implicitly define state machines. The transitions module extracts and validates them:

```lisp
;; Auto-detect state fields and extract the transition graph
(detect-state-fields "order")        ; → (:STATE)
(extract-transitions "order")        ; → ((:from :draft :to :placed :via PLACE-ORDER :guards (...)) ...)

;; Static analysis
(analyze-state-machine "order")      ; → full analysis: states, initial, terminal, unreachable, dead-ends
(terminal-states "order")            ; → (:filled :cancelled) — no outgoing edges
(unreachable-states "order")         ; → states with no incoming edge (minus initial)
(dead-end-states "order")            ; → non-terminal states stuck in a cycle

;; Validation — warns about unreachable states and dead ends
(validate-transitions)
```

A state field is a `(member ...)` field that appears as a source in at least one rule's `:when` AND as a target in at least one rule's `:ensures`. The analysis checks all entities automatically.

### JSON persistence

- `(specs-to-json)` — export all specs as a JSON string (conforms to JSON Schema 2020-12)
- `(json-to-specs json-string)` — import specs from JSON (merges; call `clear-specs` first for clean import)
- `(spec-json-schema)` — returns the JSON Schema

Save specs to a file for persistence across sessions. Load them at the start of a new session.

### Workflow

1. User describes domain in natural language
2. Define entities, variants, config, rules, invariants via `eval_lisp`
3. Define scenarios with `defscenario` for cross-entity invariants
4. Run `(validate-specs)` to catch dangling references, non-exhaustive variant handling, and invalid scenario bindings
5. Run `(validate-transitions)` to check state machines for unreachable/dead-end states
6. Run `(run-pbt)` to test per-entity invariants against random data (and random configs)
7. Run `(run-pbt :scenario "name")` to test cross-entity invariants
8. Generate code artifacts (SQL, API routes, types, validation) from the spec
9. Export with `(specs-to-json)` and save to a file

Always spec first, code second.
