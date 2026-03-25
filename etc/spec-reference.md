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

;; Field modifiers: :required, :unique, :default, :min, :max, :derived-from, :immutable
;; :immutable t — field cannot be changed after initial set (apply-rule rejects,
;; validate-specs warns, specs-to-sql emits trigger)
;;
;; Field types: string, number, integer, boolean, (member :a :b ...), (list-of type)
;; (list-of number) — ordered list of typed values; generates as Lisp list, maps to JSONB in SQL
(defentity event ()
  (id string :required t)
  (creation-time number :required t :immutable t)
  (start-time number :required t :immutable t))

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

;; :when accepts a single keyword or (member ...) for multiple source states
(defrule timeout
  :when (server :state (member :follower :candidate))
  :sets ((server-current-term server) (+ (server-current-term server) 1))
  :ensures ((eq (server-state server) :candidate)))

;; Relations support :cardinality on has-many for bounded counts
;; specs-to-sql emits a trigger enforcing the max on the child table
(defentity device ()
  (id string :required t)
  (:has-many group-assignments :of assignment :cardinality (1 15)))

;; Invariants — properties that must always hold
(definvariant non-negative-balance
  :on account
  :check (>= (account-balance account) 0))

;; :reqs maps invariants to requirement IDs for compliance traceability
(definvariant non-negative-balance-req
  :on account
  :reqs ("REQ-ACCT-001")
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

;; :refs on bindings auto-wires FK fields from referenced bindings,
;; eliminating the need for a custom generator in join-table scenarios
(defscenario group-membership
  :entities ((devices     (1 5) end-device)
             (groups      (1 3) dpd-group)
             (assignments (1 15) device-group-assignment
               :refs ((device-id :from devices :field id)
                      (group-id  :from groups  :field id)))))

;; Scenario invariants — binding names become variables in the check form
(definvariant total-items-match
  :on order-fulfillment
  :check (= (reduce #'+ orders :key #'order-item-count)
             (length items)))
```

#### Value sets

Named enumerations for use in invariant checks:

```lisp
;; Define a named value set
(defvalueset valid-response-codes (1 2 3 4 5 6 7 8 9 10 11 13 14 252 253 254))

;; Use in-set in invariant checks
(definvariant valid-response-status
  :on response
  :check (in-set 'valid-response-codes (response-status response)))
```

`in-set` translates to SQL `IN (...)` in `specs-to-sql`.

#### Non-invariant requirements

For requirements that cannot be expressed as `definvariant` (API behavior, authorization, performance, operational procedures):

```lisp
(defreq "REQ-API-001" "Return 404 for unauthorized access"
  :category :api            ;; :api, :authorization, :operational, :performance, or custom
  :status :not-expressible  ;; :not-expressible, :partial
  :notes "HTTP-level behavior, not a data property")
```

These appear in `(compliance-matrix)` alongside invariant-backed requirements, giving a complete view of requirement coverage.

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
- `(list-valuesets)` — named value sets from `defvalueset`
- `(list-requirements)` — non-invariant requirements from `defreq`
- `(list-scenarios)`, `(describe-scenario name)`
- `(describe-config)`, `(config-fields)`
- `(validate-specs)` — catches dangling entity references, undefined functions, free variables, non-exhaustive variant handling, invalid scenario bindings, entities with zero invariant coverage, uncovered FK-like fields/belongs-to relations, config keys referenced by scenario invariants but missing from their generators, rules whose `:sets` touch `:immutable` fields, and entity-level invariants that reference has-many relation accessors (only testable via scenario when no `:cardinality` is set)
- `(suggest-invariants)` — proposes `defscenario` + `definvariant` skeletons for relations and config fields
- `(compliance-matrix)` — returns requirement-to-invariant mapping from `:reqs` metadata; groups by requirement ID, collects untagged invariants under `:uncategorized`
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
- **Requires scenario-level testing** — invariant uses a has-many relation accessor that `generate-raw-instance` does not populate
- **Structurally untestable** — uniqueness checks over high-entropy fields (collision probability ~0); safe to ignore
- **Weak bounds** — comparison operators referencing `(config :key)` where the generation range is too narrow to violate; test with extreme config values
- **Enforced by schema** — null/presence checks on fields that are all `:required` or typed; random generation always satisfies them
- **Enforced by field bounds** — numeric comparisons where `:min`/`:max` field constraints prevent violation
- **Conditional** — `if`/`when`/`cond` with `eq`/`member` tests; needs a `defscenario-negative-generator` to produce targeted violations

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

Member/enum and boolean fields are generated first, then numeric fields in topologically sorted dependency order (expression deps and conditional deps are both tracked). **State fields** (member fields used in `:when`/`:ensures` of rules) use their `:default` value instead of random selection — this prevents scenario generators from producing instances in terminal states. Non-state member fields are still random. A retry loop (10 attempts) catches constraints too complex for static extraction.

After fields are generated, **FK fields from `:belongs-to` relations are automatically populated**: for each `(:belongs-to parent :of parent-entity)`, a `:parent-id` field is generated with a random string value. Overrides are respected. This means custom `defscenario-generator` functions can wire FK fields via `generate-instance` overrides without manual `setf`.

**Has-many relations with `:cardinality (min max)` are automatically populated**: the generator creates N child instances (N random in [min, max]), wires FK fields back to the parent via `:belongs-to` relations, and stores them under the relation keyword. This means entity-level invariants like `(>= (length (parent-children parent)) 2)` work without a custom generator. Population is depth-limited (default 3) to handle cyclic relations. Has-many relations without `:cardinality` are not populated.

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

- `defgenerator` registers a generator function for an entity. It receives `overrides` (a plist of `:keyword value ...` or NIL) and must return a plist. Use `override-val` / `override-present-p` to read values from it.
- `default-generate-instance` is the constraint-aware generator — use it as a base, then fix up remaining dependencies.
- `generate-value` is available for generating individual typed values (e.g. `(generate-value 'number :min 0.0 :max 10.0)`).
- `clear-specs` also clears registered generators.
- **Overrides vs inst**: To conditionally override a field, check `overrides` not `inst` — `default-generate-instance` always populates every field, so `(or (getf inst :field) (my-value))` never fires. Use: `(or (override-val overrides :field) (my-value))`.

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

#### Negative scenario generators

When a scenario invariant is structurally hard to violate via random generation (e.g. two servers must share the same random integer term), the negative pass classifies it as "structurally untestable". Use `defscenario-negative-generator` to produce targeted bad data that *should* violate at least one scenario invariant:

```lisp
(defscenario-negative-generator raft-cluster (overrides)
  (declare (ignore overrides))
  ;; Two leaders at same term — violates election-safety
  (let ((term (+ 1 (random 10))))
    (list :servers
          (list (generate-instance "server" (list :state :leader :current-term term ...))
                (generate-instance "server" (list :state :leader :current-term term ...))
                (generate-instance "server" (list :state :follower :current-term term ...)))
          :entries nil)))
```

- Same plist return format as `defscenario-generator`.
- During negative PBT, every generated instance is checked — if it passes all invariants (i.e. the negative generator produced valid data), a warning is emitted.
- `scenario-feasibility` reports `:has-negative-generator` when one is registered.
- Targeted negative trials are added alongside random negative trials; per-invariant rejection stats combine both sources.

### Temporal interval helpers

Pre-loaded functions for interval reasoning in `:check` forms. `specs-to-sql` translates them to PostgreSQL arithmetic.

```lisp
;; Do two intervals [s1, s1+d1) and [s2, s2+d2) overlap?
(intervals-overlap-p start1 dur1 start2 dur2)

;; Is [inner-start, inner-start+inner-dur) entirely within [outer-start, outer-start+outer-dur)?
(interval-contains-p outer-start outer-dur inner-start inner-dur)

;; Does [start1, start1+dur1) end at or before start2?
(interval-before-p start1 dur1 start2)
```

Usage in invariants:
```lisp
(definvariant task-finishes-before-deadline
  :on task
  :check (interval-before-p (task-start task) (task-duration task) (task-deadline task)))
```

### Temporal duration helpers

For retention policies, inactivity thresholds, and timeout requirements:

```lisp
;; Time elapsed between timestamp and now
(elapsed-since timestamp now)  ; → (- now timestamp)

;; Has at least min-duration elapsed?
(duration-at-least-p timestamp now min-duration)  ; → (>= (- now timestamp) min-duration)

;; Is now still within retention-duration of event-time?
(within-retention-period-p event-time retention-duration now)  ; → (< (- now event-time) retention-duration)
```

Usage in invariants:
```lisp
(definvariant event-retained
  :on event
  :check (within-retention-period-p
           (event-created-at event)
           (event-retention-hours event)
           (event-checked-at event)))
```

All three translate to PostgreSQL arithmetic in `specs-to-sql`.

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
;; → (values instance nil (:immutable-violation :field)) ; :sets touches immutable field
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
