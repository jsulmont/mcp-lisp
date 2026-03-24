# Behavioral Spec Engine

A specification DSL embedded in Common Lisp for capturing domain models as structured, testable metadata. Define entities, rules, and invariants — then generate test data, run property-based testing, analyze state machines, and emit PostgreSQL DDL with enforced constraints. Everything runs at the REPL or via MCP tools (`eval_lisp`).

Inspired by [JUXT Allium](https://github.com/juxt/allium) but executable from day one. See [mcp-lisp vs allium v3](../mcp-lisp-vs-allium-v3.md) for a detailed comparison.

For API reference (every function and macro), see [spec-reference.md](spec-reference.md).

## Why

Requirements documents describe what a system should do. Code implements it. Between those two things, there's a gap where constraints get lost — field bounds go unchecked, state transitions miss edges, cross-entity invariants never get tested, and the database schema drifts from the domain model.

The spec engine sits in that gap. You define the domain model once, and it:

- **Validates completeness** — finds fields with no invariant coverage, relations with no cross-entity scenario, state machines with dead-end or unreachable states
- **Tests correctness** — generates random data constrained by your invariants, verifies invariants hold under random state transitions, checks that invariants actually reject invalid data (negative testing)
- **Generates artifacts** — PostgreSQL DDL with CHECK constraints derived from invariants, enum types from member fields, state machine transition triggers from rules, foreign keys from relations, and seed data that satisfies all constraints

## Workflow

The workflow prescribed in [`examples/CLAUDE.md`](../examples/CLAUDE.md) follows a define → verify → generate cycle:

1. Define entities, config, rules, invariants, scenarios
2. Verify completeness: `validate-specs`, `invariant-coverage`, `analyze-state-machine`
3. Check generation feasibility; write custom generators where needed
4. Run PBT (positive + negative) and random walks
5. Generate SQL and seed data; save the spec as `.lisp`

Each step catches a different class of problem. The order matters — `validate-specs` catches structural issues before PBT wastes time on broken generators, and `analyze-state-machine` catches missing transitions before `random-walk` hits dead ends.

## What it Catches

### Structural gaps (validate-specs)

- Entities with zero invariant coverage
- `belongs-to` relations with no cross-entity scenario
- FK-like fields with no scenario testing the relationship
- Scenarios using aggregates but missing a `defscenario-generator`
- Config keys referenced in scenario invariants but not in their generators
- Conditional invariants on entities without a `defgenerator`

### State machine defects (analyze-state-machine)

- Dead-end states: non-terminal states with no outbound transition
- Unreachable states: states with no inbound edge (except the initial state)
- Missing terminal states: entities that can never reach a final state

### Invariant violations (run-pbt, random-walk)

- Positive testing: does the generator produce data that satisfies all invariants?
- Negative testing: do invariants actually reject random (unconstrained) data? Invariants that pass 100% of random data are classified as structurally untestable (high-entropy uniqueness) or weak bounds (config-dependent)
- Random walk testing: do invariants hold after arbitrary sequences of state transitions? This catches correlated-field bugs that static generation misses — e.g. a rule that sets `lifecycle = :soft-deleted` without clearing `enabled`

## Defining Specs

### Entities

Typed fields with constraints, relations, and derived values:

```lisp
(defentity end-device ()
  (id string :required t :unique t)
  (lfdi string :required t :unique t)
  (sfdi string :required t)
  (device-type (member :der :aggregator) :required t)
  (enabled boolean :default t)
  (lifecycle (member :active :soft-deleted :hard-deleted) :default :active)
  (changed-time number :required t)
  (last-interaction-time number :required t)
  (soft-deletion-time number :default 0)
  (:has-many subscriptions :of subscription)
  (:belongs-to aggregator :of end-device :optional t))
```

Field types: `string`, `number`, `boolean`, `list`, `(member :a :b :c)`. Relations: `:has-many`, `:belongs-to`. Fields can be `:required`, `:unique`, have `:default` values. Member fields become PostgreSQL enums in codegen.

### Config

Typed configuration parameters with bounds. PBT generates random configs within declared ranges:

```lisp
(defconfig
  (max-groups-per-device number :default 15 :min 1 :max 15)
  (subscription-max-per-client number :default 10 :min 1 :max 100)
  (subscription-expiry-hours number :default 36 :min 1 :max 168))
```

Invariants can reference config with `(config :key)`. During PBT, `:config-trials` (default 5) generates random configs, so invariants are tested across the configuration space.

### Rules

State transitions with guards and side effects:

```lisp
(defrule soft-delete-device
  :when (end-device :lifecycle :active)
  :requires ((> (end-device-last-interaction-time end-device) 0))
  :sets ((end-device-enabled end-device) nil
         (end-device-soft-deletion-time end-device) (end-device-changed-time end-device))
  :ensures ((eq (end-device-lifecycle end-device) :soft-deleted)))

(defrule reactivate-device
  :when (end-device :lifecycle :soft-deleted)
  :sets ((end-device-enabled end-device) t
         (end-device-soft-deletion-time end-device) 0)
  :ensures ((eq (end-device-lifecycle end-device) :active)))
```

- `:when` — required source state
- `:requires` — guard predicates (must all be true)
- `:sets` — field updates applied with the transition
- `:ensures` — target state after the transition

Rules implicitly define state machines. The engine extracts them and checks for structural defects:

```lisp
(analyze-state-machine "end-device")
;; → (:FIELD :LIFECYCLE
;;    :STATES (:ACTIVE :SOFT-DELETED :HARD-DELETED)
;;    :INITIAL :ACTIVE
;;    :TERMINAL (:HARD-DELETED)
;;    :UNREACHABLE NIL
;;    :DEAD-ENDS NIL
;;    :TRANSITIONS ((:FROM :ACTIVE :TO :SOFT-DELETED :VIA SOFT-DELETE-DEVICE ...) ...))
```

### Invariants

Properties that must always hold on a single entity:

```lisp
(definvariant active-means-enabled
  :on end-device
  :check (if (eq (end-device-lifecycle end-device) :active)
             (end-device-enabled end-device)
             t))

(definvariant primacy-range
  :on der-program
  :check (and (>= (der-program-primacy der-program) 0)
              (<= (der-program-primacy der-program) 255)))
```

The generator automatically extracts constraints from `:check` forms to produce valid instances — constant bounds, field ordering, arithmetic expressions, conditional constraints, config references.

### Scenarios and Cross-Entity Invariants

When invariants span multiple entity types, define a scenario:

```lisp
(defscenario control-supersession
  :entities ((program 1 der-program)
             (older-control 1 der-control)
             (newer-control 1 der-control)))

(definvariant newer-has-later-creation
  :on control-supersession
  :check (> (getf newer-control :creation-time)
             (getf older-control :creation-time)))

(definvariant overlapping-intervals
  :on control-supersession
  :check (and (< (getf older-control :interval-start)
                  (+ (getf newer-control :interval-start)
                     (getf newer-control :interval-duration)))
              (< (getf newer-control :interval-start)
                  (+ (getf older-control :interval-start)
                     (getf older-control :interval-duration)))))

(definvariant older-is-superseded
  :on control-supersession
  :check (eq (getf older-control :event-status) :superseded))
```

Scenarios that compute aggregates or cross-references need a custom generator — default random generation won't satisfy them:

```lisp
(defscenario-generator control-supersession (overrides)
  (declare (ignore overrides))
  (let* ((program (generate-instance "der-program"))
         (base-time (+ 1000000 (random 500000)))
         (duration (+ 3600 (random 82800)))
         (older (generate-instance "der-control"
                  (list :creation-time base-time
                        :interval-start (+ base-time (random 10000))
                        :interval-duration duration
                        :event-status :superseded)))
         (newer (generate-instance "der-control"
                  (list :creation-time (+ base-time 1 (random 10000))
                        :interval-start (+ base-time (random (floor duration 2)))
                        :interval-duration (+ 1800 (random 82800))
                        :event-status :active))))
    (list :program program :older-control older :newer-control newer)))
```

## Testing

### Property-based testing

```lisp
(run-pbt :trials 500 :negative-trials 200)
```

Output from a 13-entity utility server spec:

```
=== PBT Results ===
(5 config x 500 trials)
  scenario:control-response-tracking: 2500/2500 passed (3 invariants)
  scenario:device-subscriptions: 2500/2500 passed (2 invariants)
  scenario:aggregator-device-visibility: 2500/2500 passed (4 invariants)
  scenario:control-supersession: 2500/2500 passed (4 invariants)
  scenario:device-group-assignment: 2500/2500 passed (5 invariants)
  end-device: 2500/2500 passed (7 invariants)
  der-control: 2500/2500 passed (5 invariants)
  ...
Total: 40000 passed, 0 failed

=== Negative Testing ===
  lfdi-length: 100% (200/200 rejected)
  superseded-time-consistency: 82% (163/200 rejected)
  overlapping-intervals: 85% (170/200 rejected)
  fsa-count-matches-refs: 100% (200/200 rejected)
  ...

WARNING: never rejected:
  all-lfdi-unique (structurally untestable — uniqueness over high-entropy field)
  device-group-count-max (weak bounds — test with extreme config values)
```

### Random walks

Test invariants across rule sequences, not just freshly generated instances:

```lisp
(random-walk "end-device" :steps 20 :trials 50)
(random-walk "der-control" :steps 20 :trials 50)
```

```
=== Random Walk Results ===
  end-device (7 invariants, 20 steps/trial)
    50/50 passed
  der-control (5 invariants, 20 steps/trial)
    50/50 passed
```

## Code Generation

### PostgreSQL DDL

`(specs-to-sql)` generates a complete schema:

- **Enum types** from `(member ...)` fields
- **Tables** with columns, NOT NULL, DEFAULT, UNIQUE
- **CHECK constraints** from every invariant — conditional logic maps to `CASE WHEN` expressions
- **Foreign keys** from `:belongs-to` relations
- **Indexes** on FK columns and state fields
- **State machine triggers** — `BEFORE UPDATE` triggers that enforce valid transitions derived from rules

Example output (abbreviated):

```sql
CREATE TYPE end_device_lifecycle AS ENUM ('active', 'soft_deleted', 'hard_deleted');

CREATE TABLE end_device (
    id TEXT PRIMARY KEY,
    lfdi TEXT NOT NULL UNIQUE,
    lifecycle end_device_lifecycle DEFAULT 'active',
    enabled BOOLEAN DEFAULT TRUE,
    ...
    CONSTRAINT lfdi_length CHECK (length(lfdi) = 40),
    CONSTRAINT active_means_enabled CHECK ((NOT (lifecycle = 'active') OR (enabled))),
    CONSTRAINT soft_deleted_means_disabled CHECK ((NOT (lifecycle = 'soft_deleted') OR (NOT (enabled))))
);

CREATE OR REPLACE FUNCTION check_end_device_lifecycle_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT (
        (OLD.lifecycle = 'active' AND NEW.lifecycle = 'soft_deleted') OR
        (OLD.lifecycle = 'soft_deleted' AND NEW.lifecycle = 'hard_deleted') OR
        (OLD.lifecycle = 'soft_deleted' AND NEW.lifecycle = 'active')
    ) THEN
        RAISE EXCEPTION 'invalid end_device transition: % → %', OLD.lifecycle, NEW.lifecycle;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

The constraints are enforced at the database level — invalid data is rejected by PostgreSQL regardless of application bugs:

```
ERROR:  invalid end_device transition: active → hard_deleted
ERROR:  new row violates check constraint "active_means_enabled"
ERROR:  new row violates check constraint "primacy_range"
```

### Seed data

`(specs-to-sql-seed :rows-per-entity 20)` generates INSERT statements with invariant-consistent random data. Entities with custom generators use them; the default generator uses constraint-aware generation.

### Lisp persistence

`(specs-to-lisp)` emits a loadable `.lisp` file containing all entities, config, rules, invariants, scenarios, and generators. This is the canonical format — load it to restore the full spec state.

## Examples

The [`examples/`](../examples/) directory contains specs across different domains:

| Example | Entities | Domain |
|---------|----------|--------|
| `utility_server/` | 13 | IEEE 2030.5 / CSIP-AUS utility server — DER device management, control events, subscriptions |
| `energy-grid/` | — | Power grid dispatch — generators, transmission, market clearing |
| `trading-ledger/` | — | Financial trading — positions, risk limits, margin |
| `flight-dispatch/` | — | Airline operations — flights, crew, gates |
| `k8s/` | — | Kubernetes — pods, nodes, deployments, scheduling |
| `raft/` | — | Raft consensus protocol — nodes, terms, log replication |
| `interlocking/` | — | Railway signaling — routes, points, signals |

## Claude Code Integration

Copy [`etc/spec-CLAUDE.md`](spec-CLAUDE.md) into your project's `CLAUDE.md`. Claude Code will then use `eval_lisp` to define specs before writing code — the spec-first workflow described above.
