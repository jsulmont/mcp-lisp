---
name: spec-audit
description: Read-only inventory and sanity audit of the behavioral specs defined in this repo (entities, rules, invariants, scenarios). Runs in an isolated forked context so it doesn't fill the main conversation. Use when asked to review, inventory, or sanity-check the spec definitions.
context: fork
agent: Explore
allowed-tools: Read, Grep, Glob
---

Produce a **read-only** inventory and sanity audit of this project's behavioral
specifications. Do not modify any file.

1. Find spec definitions across `src/spec/`, `micro-specs/`, and `examples/` by
   grepping for the `def*` forms: `(defentity`, `(defconfig`, `(defrule`,
   `(definvariant`, `(defscenario`, `(defvalueset`, `(defgenerator`,
   `(defreq`.
2. Inventory what you find, grouped by file: entities, config, rules,
   invariants, scenarios, value sets.
3. Flag likely gaps (static, best-effort — no execution):
   - rules whose `:sets` / `:ensures` reference a field not present on any entity;
   - entity-level invariants that reference `has-many` accessors (these need
     scenario-level testing);
   - entities with a `(member ...)` state field but no rule that transitions out
     of one of its states (possible dead-end).
4. Return a concise summary: counts per category, the per-file inventory, and a
   short "potential gaps" list. End with one line on what a deeper check would
   add (running `(validate-specs)` / `(run-pbt)` via `eval_lisp`).

Keep the output compact — this is a survey, not a fix.
