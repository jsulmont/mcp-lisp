---
paths:
  - "src/spec/**"
---

# Spec engine conventions (`src/spec/`)

Respect the module dependency DAG — adding a dependency that violates it will
break load order:

```
registry → dsl → introspection → validation
                              → serialization
               → pbt-util → checking → constraints → generation → rules → pbt
               → transitions
               → analysis (reads checking, constraints, generation, transitions)
               → codegen  (reads checking, generation, transitions)
helpers (standalone — no spec deps)
spec.lisp = thin facade re-exporting all sub-modules
```

- New `def*` macros go in `dsl.lisp`; `list-*` / `describe-*` introspection in
  `introspection.lisp`; JSON/sexp/Lisp serde in `serialization.lisp`.
- Keep `helpers.lisp` standalone (haversine, intervals, durations — no spec deps).
- Expose new public symbols through `spec.lisp`; don't make callers depend on a
  sub-module package directly.
- After changing the engine, run `make test` (spec suites include
  `dsl-features-tests`, `analysis-tests`, `codegen-tests`, …) and verify with the
  read-only introspection (`(validate-specs)`, `(run-pbt)`) via `eval_lisp`.
