# mcp-lisp — Project Guide

Common Lisp implementation of the Model Context Protocol (MCP), plus a
behavioral-specification DSL, a property-based-testing (PBT) engine, an agent
loop, and Agent-to-Agent (A2A) support.

## Build & test

- `make test` runs the suite — `(mcp-lisp/tests:run-tests)`, fiveam. Prefer it
  over ad-hoc loading after a change.
- `make load` for an interactive image; `make clean` to clear fasls.
- ASDF is **package-inferred** (`mcp-lisp.asd`): every file has its own
  `defpackage`; `main.lisp` re-exports the public API. Add new public symbols to
  the relevant facade/re-export, not by making callers depend on sub-packages.

## Lisp conventions

- Reason about code as a tree of s-expressions, not text with parentheses.
  Build forms inside-out; emit each opening/closing paren as a unit.
- **Verify paren balance after editing** with a `read`-loop check, never by
  hand-counting.
- **No comments in generated or example Lisp** — just the forms.
- Match the surrounding file's idiom, naming, and comment density. Comments only
  where the logic isn't self-evident.
- Prefer small, complete forms over large monolithic blocks.

## Testing conventions

- Tests live in `tests/`, one file per area named `<area>-tests.lisp`, using
  fiveam. New behavior needs assertions in the matching `*-tests.lisp`.
- Run `make test` and report **real** results — never claim green without
  running.

## Spec-first workflow

- This project models domains with a behavioral-spec DSL **before** writing code.
  When a task describes entities, rules, or invariants, define specs first.
- Full workflow: `examples/CLAUDE.md`. DSL syntax: call `(spec-reference)` via
  the `eval_lisp` MCP tool (the project-scoped `lisp-tools` server).

## Layout

- `src/spec/` — spec DSL + PBT engine (module order matters; see
  `.claude/rules/spec-dsl.md`)
- `src/server/`, `src/client/`, `src/transport/` — MCP protocol + transports
- `src/primitives/` — tools/prompts/resources (`define-*` macros + registries)
- `src/agent/`, `src/a2a/` — agent loop + agent-to-agent protocol
- `examples/` — runnable example servers/clients

Area-specific conventions live in `.claude/rules/` and load automatically when
you touch the matching files.
