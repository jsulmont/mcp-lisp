# MCP-LISP

Common Lisp SDK for Model Context Protocol

Server, client, agent, behavioral spec engine.

---

## Why MCP-LISP?

LLMs speak tool calls. MCP standardizes the wire format.

But the tool behind the tool matters.

**eval_lisp** is the most powerful single tool you can give an LLM.

One tool, unbounded capability. The model writes code, evaluates it,
sees the result, iterates. No schema explosion. No 47 narrow tools
with brittle parameter lists.

---

## Why MCP-LISP? (cont.)

**Lisp is the natural language of structure.**
S-expressions are the easiest for an LLM to generate correctly —
no bracket-matching ambiguity, no comma-trailing bugs, no escaping hell.

**Runtime extensibility is the default.**
The model can `define-tool` a new MCP tool at runtime, then test it,
then hand it to another agent. No redeploy. No restart. No YAML.

**Everything runs in one image.**
Spec engine, PBT, SQL codegen, and MCP server share a single SBCL
process — compiled to native code, no subprocess tax, no cold starts.

---

## What's in the box

**MCP Server + Client** — 44/44 conformance checks

**Agent Loop** — Anthropic, Groq, OpenAI — caching, extended thinking

**Agent Swarm** — Coordinator + specialists + runtime tool creation

**Behavioral Spec DSL** — defentity, defrule, definvariant, defscenario

**Property-Based Testing** — generate, check, random-walk, negative trials

**State Machine Analysis** — dead-end / unreachable / missing-terminal

**SQL Codegen** — DDL, CHECK constraints, state transition triggers

**Spec Import/Export** — save as Lisp (canonical) or JSON, reload later

**Compliance Matrix** — REQ traceability from requirements to invariants

---

## MCP Server

```lisp
(define-tool lookup-order
    ((order-id string "Order ID" :required t)
     (status string "Status"
             :enum ("pending" "shipped" "delivered")))
  "Look up an order by ID."
  (:annotations :read-only t)
  (fetch-order order-id status))

(run-server :name "my-server" :version "1.0.0")
```

stdio for Claude Code. Streamable HTTP via Woo for everything else.

---

## Transports

**stdio** — Claude Code, subprocess, single session

**Streamable HTTP (Woo/libev)** — persistent servers, multi-session

```lisp
(server-start *server* :transport :sse :port 8080
              :event-loops 4 :max-tool-calls 8)
```

Tool handlers run off the event loop —
they can block (sampling, elicitation) without deadlocking.

17,238 req/s peak (100 concurrent workers, self-connect, M4 Pro)

---

## eval_lisp — The One Tool

The model writes Lisp. SBCL compiles and runs it. Result comes back.

```lisp
(defun fib (n)
  (if (<= n 1) n
      (+ (fib (- n 1)) (fib (- n 2)))))
(fib 50)
```

Sandboxed per session. Full SBCL. Compiles to native code.

No tool schema needed — the model decides what to compute.

---

## Agent Loop

```lisp
(run-agent "Analyze the sales data and build a dashboard"
           :system "You are a Lisp coding assistant."
           :thinking-budget 10000)
```

Multi-provider: Anthropic, Groq, OpenAI

Prompt caching: iterations 2+ pay ~0.1x for cached prefix

Extended thinking for complex reasoning

Built-in tools: eval_lisp, shell, read_file, web_search, grep, find

---

## Agent Swarm — Self-Extending

```
Coordinator
  ├─ ask_researcher  → web_search, read_file
  ├─ ask_coder       → eval_lisp, test_tool
  └─ ask_analyst     → shell, read_file
```

The swarm can create new MCP tools at runtime, then test them
via a sub-agent that discovers the tool from its schema alone.

```
swarm> create and register a new MCP tool called add-n

>> CODER:      defines add-n, tests it       → 15, 42, 10
>> TEST-AGENT: discovers add-n, calls it      → 24, 650, 15, 42
```

---

## Behavioral Spec Engine

A DSL for capturing domain models — entities, rules, invariants —
with property-based testing and codegen.

**Spec first, code second.**

```
Natural language prompt
    ↓  Claude + eval_lisp
Lisp spec (defentity, defrule, definvariant, defscenario)
    ↓  validate-specs, run-pbt, random-walk
Verified model
    ↓  specs-to-sql
PostgreSQL DDL + seed data
```

---

## defentity

```lisp
(defentity server ()
  (id string :required t :unique t)
  (current-term integer :required t)
  (state (member :follower :candidate :leader)
         :default :follower)
  (voted-for string)
  (commit-index integer :default 0)
  (:has-many log-entries :of log-entry))
```

Types: string, number, integer, boolean, (member ...), (list-of type)

Modifiers: :required, :unique, :default, :immutable, :nullable

Relations: :has-many, :belongs-to, :cardinality, :unique-together

Sum types: defvariant for discriminated unions

---

## defrule — State Transitions

```lisp
(defrule request-vote
  :when (server :state :candidate)
  :requires ((> (server-current-term server) 0))
  :sets ((server-votes-responded-count server)
         (+ (server-votes-responded-count server) 1))
  :ensures ((eq (server-state server) :candidate)))
```

`:when` — source state guard

`:requires` — preconditions

`:sets` — field mutations

`:ensures` — postconditions

`:reqs` — traceability to requirement IDs

---

## definvariant

```lisp
(definvariant active-means-enabled
  :on end-device
  :check (if (eq (end-device-lifecycle end-device) :active)
             (end-device-enabled end-device)
             t))
```

Per-entity invariant. Must hold for every instance, always.

---

## defscenario — Cross-Entity Invariants

```lisp
(defscenario grid-dispatch
  :entities ((grid   1      grid)
             (plants (1 20) power-plant :per grid)))

(definvariant grid-power-balance
  :on grid-dispatch
  :check (<= (reduce #'+ (mapcar #'power-plant-output plants))
             (grid-max-capacity grid)))
```

Bind multiple entities with cardinalities; attach the cross-entity
property as an invariant `:on` the scenario.

---

## Verification Pipeline

```lisp
;; Static checks
(validate-specs)

;; State machine analysis
(analyze-state-machine "server")

;; Property-based testing
(run-pbt :trials 500 :negative-trials 200)

;; Random walks — invariants across rule sequences
(random-walk "server" :steps 20 :trials 50)

;; Coverage audit
(invariant-coverage "server")
(generation-feasibility "server")
```

---

## SQL Codegen

```lisp
(specs-to-sql)                            ;; DDL
(specs-to-sql-seed :rows-per-entity 20)   ;; seed data
```

Generates:

- Tables with typed columns, NOT NULL, UNIQUE
- CHECK constraints derived from invariants
- State transition triggers from defrule
- Cardinality enforcement triggers
- Composite UNIQUE from :unique-together
- Immutability triggers from :immutable

---

## Compliance Matrix

```lisp
(defreq "REQ-ACCT-001"
  "Accounts must maintain non-negative balance"
  :category :data :status :covered)

(definvariant non-negative-balance
  :on account
  :reqs ("REQ-ACCT-001")
  :check (>= (account-balance account) 0))

(compliance-matrix)
```

Maps REQ-IDs to invariants, rules, coverage status.

Non-expressible requirements (API behavior, ACLs) tracked via defreq.

---

## Example Specs

Raft consensus — from TLA+ — server, log-entry, 10 rules, 15+ invariants

Railway interlocking — safety spec — route, signal, point, 20+ invariants

Energy grid — grid, plant, substation, meter, 12+ invariants

DHCP (RFC 2131) — server, lease, pool, 10+ invariants

ACME (RFC 8555) — account, order, authorization, 14+ invariants

Trading ledger — account, position, trade, risk-limit

Blood bank — donor, unit, test-result, component, regulatory

K8s pod scheduling — node, pod, deployment, scheduler

---

## The Loop

```
           ┌───────────────────┐
           │  Natural Language  │
           └────────┬──────────┘
                    ▼
           ┌───────────────────┐
  ┌───────▶│ Claude + eval_lisp│◀──────┐
  │        └────────┬──────────┘       │
  │                 ▼                  │
  │        ┌───────────────────┐       │
  │        │  validate-specs   │       │
  │        │  run-pbt          │       │
  │  fix   │  random-walk      │  fix  │
  │  gaps  └────────┬──────────┘ fails │
  │           pass? │ fail?            │
  │          ┌──────┴─────┐            │
  │          ▼            └────────────┘
  │  ┌──────────────┐
  └──│ analyze-sm   │
     │ inv-coverage │
     └──────┬───────┘
            ▼ complete
     ┌──────────────┐
     │ specs-to-sql │
     │ specs-to-lisp│
     └──────────────┘
```

---

## Numbers

MCP conformance:    44/44 checks (32 scenarios)

Unit tests:         457 tests (2,943 checks)

Spec engine:        ~8,400 lines across src/spec/

SSE transport:      17,238 req/s peak (self-connect, M4 Pro)

Example specs:      20+ domains

---

## Getting Started

```bash
# SBCL + Quicklisp
ln -s /path/to/mcp-lisp ~/quicklisp/local-projects/mcp-lisp
```

```lisp
(ql:quickload :mcp-lisp)
```

Add to Claude Code MCP config — get eval_lisp as a tool.

Copy `etc/spec-CLAUDE.md` into your project's CLAUDE.md for spec-first workflow.

MIT OR Apache-2.0
