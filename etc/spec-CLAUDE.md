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

### Spec analysis

Tools for inspecting coverage, feasibility, and dependencies:

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
;; → (:VERDICT :NEEDS-CUSTOM-GENERATOR  ;; conditional constraints on :state
;;    :CONDITIONAL-CONSTRAINTS (:OUTPUT-MW :EMISSIONS-RATE ...)
;;    :UNCONSTRAINED-FIELDS (:ID :NAME :START-COST ...))

;; Does a scenario need a custom generator?
(scenario-feasibility "full-dispatch")
;; → (:NEEDS-CUSTOM-GENERATOR T  ;; aggregate invariants detected
;;    :HAS-CUSTOM-GENERATOR T    ;; and one exists
;;    :VERDICT :OK)

;; Step through rules on a concrete instance
(simulate-trace "generator" instance '("start-generator" "sync-generator"))
;; → per-step: rule, from/to state, each guard pass/fail, instance-after
```

### Property-based testing

Generate random entity instances and check invariants automatically:

```lisp
(run-pbt :trials 200)

;; With config: test across random configuration space
(run-pbt :trials 100 :config-trials 5)

;; Test a specific scenario (cross-entity invariants)
(run-pbt :scenario "order-fulfillment" :trials 50)
```

Add `:negative-trials` to also verify invariants aren't trivially true:

```lisp
;; Positive: smart generation should pass. Negative: random generation should fail.
(run-pbt :trials 200 :negative-trials 100)
```

The negative pass generates unconstrained random instances (no constraint extraction, no retry) and checks that each invariant correctly rejects them. Invariants that pass 100% of random data are flagged as suspicious — they may be trivially true or too weak. Always run negative trials alongside positive trials to validate both directions.

This generates random instances for every entity that has invariants, checks all applicable invariants (including variant-specific ones), and reports counterexamples on failure. When `defconfig` is defined, `:config-trials` (default 5) generates random configs within declared bounds — catching specs that only hold for the default config.

For entities with variants, `generate-instance` picks a random variant, sets the discriminator, and generates variant-specific fields. Invariants on the base entity apply to all variants; invariants on a variant name apply only when the discriminator matches.

Use `(check-invariants "entity-name" instance)` for targeted checking and `(generate-instance "entity-name")` to produce test data.

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

For constraints the extractor can't handle (e.g. neither side is a single field, iterative computations), use `defgenerator` as an escape hatch:

```lisp
(defgenerator triple (overrides)
  (let* ((inst (default-generate-instance "triple" overrides))
         (a (getf inst :a))
         (b (getf inst :b)))
    ;; Satisfy: (= (+ result a) (* b b))
    (setf (getf inst :result) (- (* b b) a))
    inst))
```

- `defgenerator` registers a generator function for an entity. It receives `overrides` (an alist of `(keyword . value)` or NIL) and must return a plist.
- `default-generate-instance` is the constraint-aware generator — use it as a base, then fix up remaining dependencies.
- `generate-value` is available for generating individual typed values (e.g. `(generate-value 'number :min 0.0 :max 10.0)`).
- `clear-specs` also clears registered generators.

#### Custom scenario generators

**You MUST write a `defscenario-generator` whenever a scenario has invariants that compute aggregates, sums, or cross-references across entity bindings** (e.g. "total equals sum of parts", "transfers net to zero", "priority ordering across contracts"). Default random generation will never satisfy these — instances must be constructed top-down with correlated values.

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

### Rule execution

Apply rules as state transitions and test invariants across rule sequences:

```lisp
;; Apply a single rule — returns (values new-instance applied-p reason)
(apply-rule "order" instance "fill-order")
;; → (values new-instance t nil)               ; applied: state changed
;; → (values instance nil :when-mismatch)       ; wrong state
;; → (values instance nil (:guard-failed form)) ; :requires failed
;; → (values instance nil :unknown-rule)        ; rule doesn't exist

;; Which rules can fire on this instance?
(applicable-rules "order" instance)
;; → ("validate-order" "reject-order" "cancel-pending")

;; Random walk PBT: generate instances, apply random rules, check invariants
(random-walk "order" :steps 20 :trials 50)
```

`apply-rule` performs state transitions only — non-state fields are unchanged. This is deliberate: state-dependent invariants (e.g. "fill-price must be positive when state is :filled") will fire when a rule changes state without the corresponding field update. These violations expose incomplete rules — the spec declares a state transition but doesn't account for fields that must change with it.

`random-walk` generates instances in the initial state, then repeatedly picks a random applicable rule, applies it, and checks all invariants. It reports the first violation with the rule trace that caused it. Use this to find invariant violations that only surface through specific rule sequences.

### JSON persistence

- `(specs-to-json)` — export all specs as a JSON string (conforms to JSON Schema 2020-12)
- `(json-to-specs json-string)` — import specs from JSON (merges; call `clear-specs` first for clean import)
- `(spec-json-schema)` — returns the JSON Schema

Save specs to a file for persistence across sessions. Load them at the start of a new session.

### Scenario binding semantics

- Cardinality `(min max)` (e.g. `(1 3)`) always produces a **list** of instances, even when the random count is 1. Use `every`, `reduce`, `mapcar` to iterate.
- Cardinality `1` (bare number) produces a **single plist** (not a list). Access fields directly with `getf`.

Example: `(interval 1 dispatch-interval)` → `interval` is a plist; use `(getf interval :total-generation-mw)`.
Example: `(zones (1 3) grid-zone)` → `zones` is always a list; use `(every (lambda (z) ...) zones)`.

### Workflow

1. User describes domain in natural language
2. Define entities, variants, config, rules, invariants via `eval_lisp`
3. **Verify completeness against the prompt.** If the prompt names specific invariants, rules, entities, or scenarios, verify every one was implemented. Run `(list-entities)`, `(list-rules)`, `(list-invariants)`, `(list-scenarios)` and diff against the prompt's named items. List any that appear in the prompt but are missing from the spec. **Implement all missing items before proceeding.** This catches the most common generation failure: silently dropping items from long lists, especially complex invariants in the middle-to-end of the prompt.
4. **Inspect state machines.** For any entity with `(member ...)` state fields and rules, run `(analyze-state-machine "entity")`. Check for:
   - **Dead-end states**: non-terminal states with no outgoing transitions — usually a missing rule.
   - **Unreachable states**: states no transition leads to — either the state is unused or an inbound rule is missing.
   - **Missing terminal states**: if every real-world process has an end state, the machine should have at least one terminal state.
   - Use `(simulate-trace "entity" instance '("rule1" "rule2"))` to verify a concrete instance can walk through the full lifecycle. Each step shows which guards pass/fail and the resulting state.
   - Fix gaps in rules/states before proceeding — the state graph shapes what invariants and scenarios are needed.
5. **Check invariant coverage.** Run `(invariant-coverage "entity")` for each entity. Fields with NIL have no invariant checking them. Decide whether each unconstrained field needs an invariant or is intentionally uncovered (e.g. `:id`, `:name`). Use `(field-index "entity" :field)` to see the full picture of what touches a specific field.
6. **Audit for missing cross-entity invariants.** After per-entity invariants are defined, check for gaps:
   - **Bounding fields**: Any field whose purpose is to constrain another entity (e.g. `max-notional` on a risk-limit that should bound a trader's positions, `capacity` on a warehouse that should bound stored items) MUST have a cross-entity scenario testing that relationship. A per-entity invariant on such a field (e.g. "max-notional > 0") is necessary but not sufficient — the aggregate constraint is the one that matters.
   - **Relations as signals**: For every `has-many` relation, ask: does the parent entity have fields that should bound aggregate properties of the children (count, sum, max)? If yes, that's a scenario.
   - **Rules that reach across entities**: If a rule's `:requires` or `:let` accesses fields from related entities, the constraint it checks likely has a corresponding aggregate invariant that should hold at rest, not just at transition time.
   - If this audit finds gaps, define the scenarios before proceeding.
7. Define scenarios with `defscenario` for cross-entity invariants
8. **Check generation feasibility.** Run `(generation-feasibility "entity")` for each entity with invariants. If the verdict is `:needs-custom-generator` (conditional constraints that require correlated field values), write a `defgenerator` **before** running PBT — otherwise you'll waste trials on guaranteed failures.
9. **Check scenario feasibility.** Run `(scenario-feasibility "scenario")` for each scenario. If `:needs-custom-generator` is T and `:has-custom-generator` is NIL, write a `defscenario-generator` before running PBT. See [Custom scenario generators](#custom-scenario-generators).
10. Run `(validate-specs)` to catch dangling references, non-exhaustive variant handling, and invalid scenario bindings
11. Run `(run-pbt :trials 500 :negative-trials 200)` to test per-entity invariants against random data (and random configs). The negative pass verifies invariants aren't trivially true.
12. Run `(run-pbt :scenario "name" :trials 50)` to test cross-entity invariants
13. Run `(random-walk "entity" :steps 20 :trials 50)` for entities with rules — tests that invariants hold across all reachable rule sequences, not just on freshly generated instances
14. Generate SQL DDL: `(specs-to-sql)` produces PostgreSQL DDL (enums, tables, CHECK constraints, foreign keys, indexes, state machine triggers). Invariants that can't be translated to SQL are emitted as comments.
15. Generate seed data: `(specs-to-sql-seed :rows-per-entity 20)` produces INSERT statements with invariant-consistent random data. Foreign keys reference previously generated parent rows. Every row passes the spec's invariants.
16. Save the spec as a loadable `.lisp` file (all `defentity`, `defrule`, `definvariant`, `defscenario`, `defgenerator`, and helper forms). This is the canonical format — load with `(load "spec.lisp")` in future sessions.

Always spec first, code second.
