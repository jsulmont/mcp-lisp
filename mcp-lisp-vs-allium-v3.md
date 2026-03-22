# mcp-lisp vs allium v3

Both projects use behavioral specifications to drive code correctness.
They make opposite bets on where verification should happen: a deterministic
runtime, or the LLM itself.

*Updated March 2026. allium-tools now ships a Rust parser and CLI. This
revision corrects the original claim that no tooling exists while being
precise about what that tooling actually does (syntax checking, not semantic
verification). mcp-lisp additions: generic expression constraints, negative
testing.*

## Core Philosophy

**mcp-lisp** is an executable specification runtime. Specs are compiled Common
Lisp. Invariants are checked by a deterministic PBT runner. The LLM authors
specs; the machine verifies them.

**allium** is a specification language designed to be read by LLMs and humans.
allium-tools now provides a Rust parser and LSP, but there is no runtime and
no execution semantics. Invariant verification is performed by an LLM
reasoning about whether code matches the spec.

## What Actually Exists Today

The allium project spans two repos: `allium` (language reference, LLM skills,
proposals — pure documentation) and `allium-tools` (Rust parser, CLI, LSP,
tree-sitter grammar, editor extensions).

| Capability | mcp-lisp | allium v3 |
|---|---|---|
| Spec parser | CL reader + macros (working) | Rust parser, ~6400 LOC (working) |
| Syntax checking | `validate-specs` — structural + semantic (working) | `allium check` — parse + report syntax diagnostics (working) |
| Semantic validation | `validate-specs` — cross-entity refs, free variables, variant exhaustiveness, scenario bindings (working) | Not implemented — no cross-entity ref checking, no type checking, no state reachability |
| LSP | N/A | Working — diagnostics (from parser), hover, completions (VS Code, Neovim, Emacs) |
| PBT runner | `run-pbt` with negative testing (working) | Not implemented |
| Instance generation | Constraint-aware `generate-instance` with expression constraints, variant + config support (working) | Not implemented |
| Cross-entity PBT | `defscenario` with cardinality ranges, `:per` relations, scenario invariants, custom scenario generators (working) | Not implemented |
| Sum types | `defvariant` with variant-aware generation, invariants, exhaustiveness checking (working) | Language supports variants — no tooling beyond syntax check |
| Typed config | `defconfig` with PBT over config space (working) | Language supports config — no tooling beyond syntax check |
| State machine analysis | `extract-transitions` + dead-end/unreachable detection (working) | Language supports `transitions` blocks — no tooling to analyze them |
| JSON export | `specs-to-json` with JSON Schema 2020-12 (working) | Not implemented |
| Drift detection | Not implemented | `weed` agent skill (LLM prompt template) |
| Test generation | Built-in PBT is the test | `propagate` skill (LLM prompt template) |
| MCP server | Working (stdio + SSE) | None |
| Agent loop | Working (Anthropic/Groq/OpenAI) | None (relies on Claude Code as host) |
| CLI installation | N/A (Lisp REPL) | `brew tap juxt/allium && brew install allium` (working) |
| Tree-sitter grammar | N/A (Lisp) | Working (in allium-tools) |

The original comparison said allium had no tooling at all. That was wrong —
allium-tools ships a real Rust parser with a CLI, LSP, tree-sitter grammar,
and Homebrew formula. But it's important to be precise: `allium check` runs
the parser and reports syntax diagnostics (version markers, naming conventions,
unexpected tokens). It does not perform semantic analysis — no cross-entity
reference validation, no type checking, no state reachability analysis. The
allium skills (`distill`, `elicit`, `propagate`, `weed`, `tend`) are LLM
prompt templates, not executable tooling.

## Determinism

This is the decisive axis.

| Operation | mcp-lisp | allium v3 |
|---|---|---|
| Spec parsing | Deterministic (CL compiler) | Deterministic (Rust parser) |
| Syntax checking | Deterministic (`validate-specs`) | Deterministic (`allium check`) |
| Semantic validation | Deterministic (cross-entity refs, variant exhaustiveness, scope analysis) | LLM reads language reference, applies rules |
| Invariant evaluation | Deterministic (compiled predicates) | LLM reasons about whether invariant holds |
| Instance generation | Deterministic (constraint extraction, expression analysis, topological field ordering) | Not available |
| PBT execution | Deterministic (generate N instances, check all invariants, report counterexamples) — per-entity and cross-entity via scenarios | Not available |
| Negative testing | Deterministic (unconstrained generation, per-invariant rejection stats, trivially-true detection) | Not available |
| State machine analysis | Deterministic (graph algorithms) | LLM reads transition blocks |
| Spec export | Deterministic (JSON with schema validation) | Plain text `.allium` files |
| Drift detection | Not available | LLM reads spec + code, emits opinion |
| Test generation | Deterministic (PBT runner is the test) | LLM writes test code |

allium now has a deterministic parser. Everything past syntax checking still
requires the LLM. mcp-lisp has a deterministic pipeline from parse through
semantic validation to invariant verification.

## The Feedback Loop

This is mcp-lisp's strongest property and something allium cannot replicate
today.

The pattern:

1. LLM reads a domain prompt (e.g. "model a trading desk")
2. LLM generates `defentity`, `defvariant`, `defconfig`, `defrule`, `definvariant` forms
3. LLM defines `defscenario` for cross-entity relationships (e.g. portfolios containing positions referencing instruments)
4. `run-pbt` finds a counterexample: `balance = -3.7` violates `non-negative-balance` (under config `max-leverage = 47.3`)
5. `run-pbt :scenario "portfolio-check"` finds a cross-entity counterexample: total position notional exceeds portfolio limit
6. `run-pbt :negative-trials 50` flags an invariant that never rejects random data — the predicate may be trivially true
7. LLM sees the concrete failures and suspicious invariants, fixes the spec
8. Repeat until `run-pbt` passes across all entities, variants, config space, and scenarios

The LLM is fallible at authoring. The PBT runner is not fallible at checking.
The LLM does not need to "understand" whether the invariant holds — it receives
a concrete counterexample with actual values and corrects the spec. This is a
**deterministic oracle inside an LLM loop**.

Negative testing closes the other half: where normal PBT asks "does your
invariant reject bad data?", negative testing asks "does your invariant
actually reject *anything*?" An invariant that passes on 100% of random
unconstrained instances is suspicious — it may be vacuously true or too
weak to catch real violations.

allium has no equivalent. When allium's `weed` agent says "spec and code
diverge," that is an LLM opinion. It cannot produce a counterexample. It
cannot prove the spec is consistent. It can only assert that it looks right.

## Spec Expressiveness

allium's language is significantly richer. This is real, not hand-waving — the
constructs exist in the language reference even if tooling does not verify them.

| Feature | mcp-lisp | allium v3 |
|---|---|---|
| Entities | Yes | Yes |
| Value types (immutable records) | No | Yes |
| Sum types / variants | Yes (`defvariant` — discriminated unions with per-variant fields, invariants, exhaustiveness checking) | Yes |
| Named enumerations | No (inline `(member ...)` only) | Yes |
| Relations | `:has-many`, `:has-one`, `:belongs-to` | Structural with backreference |
| Projections | No | Yes (`slots where status = confirmed`) |
| Derived values | Lambda on entity + expression constraints | Inline expressions, parameterized |
| Transition graphs | Implicit (extracted from rules) | Explicit (declared in entity body) |
| State-dependent fields | No | Yes (`field: T when status = shipped`) |
| Surfaces (boundary contracts) | No | Yes (facing, context, exposes, provides) |
| Actors | No | Yes (identity-scoped) |
| Contracts | No | Yes (reusable obligations with signatures) |
| Config | Yes (`defconfig` — typed fields with defaults/ranges, `(config :key)` in invariants, PBT over config space) | First-class (typed, cross-module, expressions) |
| Module system | No | Yes (immutable coordinates) |
| Trigger types | 1 (state match) | 7 (stimulus, transition, becomes, temporal, derived, creation, chained) |
| `implies` operator | No | Yes |
| Cross-entity invariants | Yes (`defscenario` — cardinality ranges, `:per` parent relations, flat-binding in check forms) | Yes (inline expressions) |
| Universal quantifiers | Via CL (`every`, `reduce`, `loop` in check forms) | Yes (`for x in Collection: expr`) |
| Existence checks | Via CL (`some`, `find`) | Yes |
| Optional types / null safety | Not modeled | `T?`, `??`, `?.` |
| Deferred specs | No | Yes |
| Open questions | No | Yes |
| Seed data / defaults | No | Yes |

mcp-lisp's spec language covers entities, variants, config, rules, and
invariants — each backed by deterministic tooling. allium's language captures
additional real-world complexity (boundaries, actors, temporal triggers,
contracts) that mcp-lisp cannot express.

The question is whether expressiveness without mechanical verification buys you
anything beyond documentation.

## Rules and Triggers

mcp-lisp rules have one trigger type: state match (`:when (entity :state :value)`).
They are metadata — serialized as portable AST nodes in JSON (conforming to
JSON Schema 2020-12), used by `extract-transitions` to build state machine graphs.

allium rules have seven trigger types:

- External stimulus: `when: UserLogsIn(email, password)`
- State transition: `when: order: Order.status transitions_to shipped`
- State becomes: `when: order: Order.status becomes shipped`
- Temporal: `when: inv: Invitation.expires_at <= now`
- Derived condition: `when: interview: Interview.all_feedback_in`
- Entity creation: `when: batch: DigestBatch.created`
- Chained: `when: AllConfirmationsResolved(candidacy)`

This is genuinely more expressive. Whether an LLM can reliably reason about
temporal trigger semantics and chained event cascades without a runtime is a
separate question.

## Invariants

mcp-lisp invariants are compiled CL predicates. `check-invariants` evaluates
them against concrete instances, including variant-specific invariants when the
discriminator matches. `extract-generation-constraints` parses `:check` forms
to derive bounds automatically:

- `(>= balance 0)` → generate with min=0
- `(>= field1 field2)` → generate field2 first, bound field1
- `(= notional (* quantity price))` → compute derived field from expression
- `(<= field (- max-val offset))` → upper bound from arithmetic expression
- `(if (member fuel '(:solar :wind)) (= emissions 0) ...)` → conditional bounds
- `(<= leverage (config :max-leverage))` → resolves bound from current config instance

The constraint extractor handles arbitrary arithmetic expressions over entity
fields (`+`, `-`, `*`, `/`, `abs`, `mod`, `expt`, `min`, `max`), tracks
expression dependencies for topological generation ordering, and supports
boolean conditional patterns.

allium invariants are expression-bearing (`invariant Name { expr }`) or prose
(`@invariant Name` with comment body). The language reference says checkers
"validate that entity-level invariants hold after every state-changing rule,"
but no checker exists. The LLM reads the invariant and reasons about it.
`allium check` can verify that the invariant body parses — it cannot evaluate
it.

allium invariants can express things mcp-lisp cannot: implication, optional
types, and state-dependent field existence. Cross-entity assertions — previously
an allium-only capability — are now covered by `defscenario`: scenario
invariants receive all bound entity collections as variables, enabling checks
like "total generation must equal dispatch-interval total" across arbitrary
entity graphs. Universal quantification over collections works naturally via
CL's `every`, `reduce`, `loop`. But allium's remaining assertions are still
things that nothing mechanically verifies.

## Where Each Wins

**mcp-lisp wins on trust.** When `run-pbt` says your spec is consistent, it is.
When it finds a counterexample, that counterexample is real. When negative
testing flags a suspicious invariant, you know it never rejected random data.
You can hand the JSON export to a CI pipeline, a code generator, or another
tool — no LLM required. The feedback loop (LLM authors, oracle checks, LLM
fixes) converges on correct specs without requiring the LLM to be right on the
first try. `defscenario` extends this to cross-entity properties: the PBT
runner generates correlated multi-entity fixtures and checks invariants across
entity boundaries, producing counterexamples that show the full scenario state
on failure.

**allium wins on coverage.** It can describe boundaries, actors, temporal
behavior, contracts, and cross-module dependencies that mcp-lisp has no syntax
for. For teams that need to capture "who can see what, when, under what
conditions," allium's language is the only option. The parser and LSP provide a
developer experience for authoring specs. The gap has narrowed further — sum
types, config, and cross-entity invariants are no longer allium-only — but
surfaces, actors, temporal triggers, contracts, and modules remain outside
mcp-lisp's scope.

## The Verification Gap

allium's verification story is still LLM-dependent past syntax checking. The
Rust parser confirms your `.allium` file parses. It does not check that entity
references are valid, that state machines are reachable, that types are
consistent, or that invariants hold. The LLM reads the spec, reads the code,
and emits a judgment. This means different models — or the same model on
different runs — can reach different conclusions. There is no counterexample,
only an opinion.

allium's TODO.md acknowledges this gap explicitly: planned work includes a
structural validator (semantic analysis beyond parsing), PBT generation, runtime
trace validation, and a model checking bridge (TLA+/Alloy). None exist today.

## The Fundamental Limitation of mcp-lisp

mcp-lisp can only verify what it can express. Its spec language covers entities,
discriminated unions, typed config, rules with state guards, invariants with
boolean predicates (including arithmetic expressions), and cross-entity
scenarios with PBT. It cannot express:

- Who is allowed to perform an action (no actors/surfaces)
- What happens when a deadline passes (no temporal triggers)
- How modules compose (no module system)
- What integration obligations exist (no contracts)
- Which fields exist in which lifecycle states (no state-dependent types)

Adding these requires extending the deterministic toolchain — which is the
point. Features only land when there is a mechanical check behind them.

The next concrete step is a **rule execution model**: `apply-rule` takes an
entity instance and a rule name, evaluates guards, applies the transition,
and returns the new instance (or rejects). Once rules are executable:

- **Actors** become meaningful — PBT generates (actor, rule, instance) triples
  and verifies permission invariants, rather than just annotating metadata.
- **Multi-step scenarios** become testable — generate random rule sequences,
  check that invariants hold after each step.
- **Temporal triggers** become feasible — a simulated clock advances, rules
  fire, and PBT checks time-dependent invariants.

Without execution, actors and temporal triggers would just be documentation
with cross-reference checking — which is exactly the gap this project exists
to avoid.

## Token Efficiency

An underappreciated axis. mcp-lisp's PBT runner, constraint extractor, state
machine analyzer, and JSON serializer all run inside a ~50 MB SBCL process
exposed as MCP tools. The LLM's job is to author spec forms (a few hundred
tokens) and read back results. A typical `run-pbt` call with 200 trials across
5 config permutations executes 1000 invariant checks — zero LLM tokens.

allium's parser runs locally and is similarly cheap. But everything past syntax
checking — invariant evaluation, drift detection, test generation — requires
the LLM to hold the full spec, the full codebase, and the language reference in
context simultaneously. Every semantic verification step burns context window.
The same task that mcp-lisp handles in a single tool call requires allium's LLM
to do all the work.

The MCP architecture makes this natural: the LLM is the author, the SBCL
process is the oracle. Each stays in its lane.

## Context

mcp-lisp started as a project to learn MCP, then became an experiment in
verifying an intuition: that a small Lisp runtime could provide the
deterministic backbone that LLM-authored specifications need.

allium is a genuinely impressive language design — the breadth of constructs
(surfaces, actors, temporal triggers, contracts, modules) reflects deep
thinking about what real-world specs need to capture. The language reference
is one of the best specification documents I've read. The allium-tools parser
is solid Rust and the LSP provides a real editing experience. The bet that LLMs
need a richer target language than what traditional formal methods offer is
probably right long-term, especially as models get better at structured
reasoning.

The difference is timing and approach: mcp-lisp ships mechanical checks for a
narrow language today; allium designs a broad language and has started building
tooling for it. The verification gap — "does this parse?" vs "is this
consistent?" — remains the fundamental distinction. If allium lands its planned
semantic validator, PBT generation, or model checking bridge, the two
approaches converge — and allium's richer expressiveness wins.

## Summary

|  | mcp-lisp | allium v3 |
|---|---|---|
| **What it is** | Executable spec runtime | Spec language + parser |
| **Parser** | Deterministic (CL compiler) | Deterministic (Rust parser, ~6400 LOC) |
| **Semantic validation** | Deterministic (`validate-specs` — refs, scope, exhaustiveness) | Not implemented (LLM reads language reference) |
| **Verification** | Deterministic (PBT over entity × variant × config × scenario space, constraint extraction, expression analysis, negative testing, state machine analysis) | Non-deterministic (LLM reasoning) |
| **Feedback loop** | Yes — LLM authors, oracle rejects with counterexamples (including cross-entity), flags trivially-true invariants, LLM fixes | No — LLM authors, LLM checks |
| **Expressiveness** | Moderate (entities, variants, config, rules, invariants, state machines, cross-entity scenarios) | Broad (+ surfaces, actors, triggers, contracts, modules) |
| **Developer experience** | REPL + MCP tools | LSP + CLI + tree-sitter + brew install |
| **Portable output** | JSON with schema validation | Plain text `.allium` files |
| **Token cost of verification** | Near zero (SBCL process via MCP tools) | High (LLM does all reasoning past syntax) |
| **Trust model** | Trust the compiler, not the LLM | Trust the parser for syntax, trust the LLM for everything else |

Different bets on different failure modes. mcp-lisp optimizes for "is this
spec internally consistent?" allium optimizes for "does this spec capture
the full problem?" Both questions matter.
