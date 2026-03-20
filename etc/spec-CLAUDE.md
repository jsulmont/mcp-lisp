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
```

### Querying specs

- `(list-entities)`, `(describe-entity name)`, `(entity-fields name)`, `(entity-relations name)`
- `(list-rules)`, `(describe-rule name)`
- `(list-invariants)`, `(describe-invariant name)`
- `(validate-specs)` — catches dangling entity references in rules, invariants, and relations
- `(clear-specs)` — reset all registries

### Property-based testing

Generate random entity instances and check invariants automatically:

```lisp
(run-pbt :trials 200)
```

This will generate random instances for every entity that has invariants, check all applicable invariants, and report counterexamples on failure. Use `(check-invariants "entity-name" instance)` for targeted checking and `(generate-instance "entity-name")` to produce test data.

#### Custom generators

The default generator picks each field independently, which can't satisfy cross-field invariants (e.g. "suspended implies margin < 0.5"). Use `defgenerator` to register a custom generator that enforces these dependencies:

```lisp
(defgenerator trader (overrides)
  (let ((inst (default-generate-instance "trader" overrides)))
    (when (getf inst :suspended)
      (setf (getf inst :margin-ratio)
            (generate-value 'number :min 0.0 :max 0.5)))
    inst))
```

- `defgenerator` registers a generator function for an entity. It receives `overrides` (an alist of `(keyword . value)` or NIL) and must return a plist.
- `default-generate-instance` is the original field-by-field generator — use it as a base, then fix up cross-field dependencies.
- `generate-value` is available for generating individual typed values (e.g. `(generate-value 'number :min 0.0 :max 10.0)`).
- `clear-specs` also clears registered generators.

### JSON persistence

- `(specs-to-json)` — export all specs as a JSON string (conforms to JSON Schema 2020-12)
- `(json-to-specs json-string)` — import specs from JSON (merges; call `clear-specs` first for clean import)
- `(spec-json-schema)` — returns the JSON Schema

Save specs to a file for persistence across sessions. Load them at the start of a new session.

### Workflow

1. User describes domain in natural language
2. Define entities, rules, invariants via `eval_lisp`
3. Run `(validate-specs)` to catch dangling references
4. Run `(run-pbt)` to test invariants against random data
5. Generate code artifacts (SQL, API routes, types, validation) from the spec
6. Export with `(specs-to-json)` and save to a file

Always spec first, code second.
