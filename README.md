# mcp-lisp

Common Lisp SDK for [Model Context Protocol](https://modelcontextprotocol.io) (MCP 2025-11-25) and [Agent-to-Agent Protocol](https://github.com/google/A2A) (A2A).

**44/44 conformance checks passing** (32 scenarios) against [`@modelcontextprotocol/conformance`](https://github.com/modelcontextprotocol/conformance).

## Requirements

- [SBCL](http://www.sbcl.org/)
- [Quicklisp](https://www.quicklisp.org/)

## Installation

```bash
ln -s /path/to/mcp-lisp ~/quicklisp/local-projects/mcp-lisp
```

```lisp
(ql:quickload :mcp-lisp)
```

## MCP Server

```lisp
(use-package :mcp-lisp)

;; Tool with annotations and enum support
(define-tool lookup-order
    ((order-id string "Order ID" :required t)
     (status string "Filter by status" :enum ("pending" "shipped" "delivered")))
  "Look up an order by ID."
  (:annotations :read-only t)
  (fetch-order order-id status))

;; Resource
(define-resource "config://settings"
    (:name "Settings" :mime-type "application/json")
  "Application settings."
  (encode-json *settings*))

;; Prompt
(define-prompt summarize ((text string "Text to summarize" :required t))
  "Generate a summarization prompt."
  (list (make-ht "role" "user"
                 "content" (make-ht "type" "text"
                                    "text" (format nil "Summarize: ~a" text)))))

;; Start (stdio for Claude Code, blocking)
(run-server :name "my-server" :version "1.0.0")
```

### Transports

- `:stdio` (default) -- newline-delimited JSON over stdio, for Claude Code
- `:sse` -- Streamable HTTP via [Woo](https://github.com/fukamachi/woo) (libev), for persistent servers and HTTP clients

```lisp
;; Non-blocking HTTP server for REPL development
(defvar *server* (make-server :name "my-server" :version "1.0.0"))
(server-start *server* :transport :sse :port 8080)
;; server running on http://localhost:8080/mcp
(server-stop *server*)
```

#### SSE Server Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `:port` | 8080 | Listen port |
| `:event-loops` | CPU cores | Woo event loop threads. Handle all requests except `tools/call`. |
| `:tool-workers` | = event-loops | Worker pool threads for `tools/call`. Runs off the event loop so tool handlers can block (e.g. sampling, elicitation) without deadlocking. |

```lisp
(server-start *server* :transport :sse :port 9090
              :event-loops 4 :tool-workers 8)
```

### Structured Tool Errors

Tools can signal categorized errors for agent recovery decisions:

```lisp
(error 'tool-error
       :message "Refund exceeds $500 policy limit"
       :category :business
       :retryable nil)
```

Categories: `:transient`, `:validation`, `:permission`, `:business`.

### Structured Access Log

Set `*access-log-stream*` for JSON-lines operational logging:

```lisp
(setf mcp-lisp/src/transport/mcp-woo:*access-log-stream* *standard-output*)
```

```json
{"ts":"2026-03-15T08:44:00Z","session":"3982553040-11","method":"tools/call","id":2,"duration_us":165,"status":"ok","target":"test_tool_with_logging"}
```

## MCP Client

Supports both stdio (subprocess) and Streamable HTTP transports:

```lisp
;; HTTP client
(with-client (c "http://localhost:8080/mcp")
  (dolist (tool (list-tools c))
    (format t "~a~%" (gethash "name" tool)))
  (call-tool c "echo" :message "hello"))

;; Stdio client (spawns subprocess)
(with-client (c "sbcl" "--script" "server.lisp")
  (list-tools c))
```

## REPL Agent

Run Claude (or Groq, OpenAI) with tools in your Lisp environment:

```lisp
(use-package :mcp-lisp)

(setf *provider* :anthropic)  ; or :groq, :openai

(run-agent "Write a function that computes fibonacci numbers and test it"
           :system "You are a Lisp coding assistant."
           :max-iterations 10
           :thinking-budget 10000)    ; Anthropic extended thinking (optional)
```

### Built-in Tools

| Tool | Description |
|------|-------------|
| `eval_lisp` | Evaluate Lisp in a sandboxed package. Per-session isolation. |
| `clear_repl` | Reset the sandbox. |
| `shell` | Execute shell commands. |
| `read_file` | Read file contents. |
| `web_search` | Search via Tavily. |
| `grep_files` | Search file contents (uses rg or grep). |
| `find_files` | Find files by name (uses fd or find). |
| `list_tools` | List all registered tools. |

### Multi-Provider Support

```lisp
(setf *provider* :anthropic)  ; Claude (default: claude-sonnet-4-20250514)
(setf *provider* :groq)       ; Llama (default: llama-4-maverick-17b-128e-instruct)
(setf *provider* :openai)     ; GPT (default: gpt-4o)
(setf *model* "claude-opus-4-20250514")  ; override default
```

### Prompt Caching

Anthropic prompt caching is enabled automatically. The system prompt and tool definitions are marked with `cache_control`, so iterations 2+ of the agent loop pay ~0.1x for the cached prefix. The verbose output shows cache status:

```
[Tokens: 459 in, 276 out (cache hit: 1,141) | Session: 1,843 in, 610 out]
```

### Extended Thinking

Enable Anthropic's extended thinking for complex reasoning tasks:

```lisp
(run-agent "Design a data structure for..."
           :thinking-budget 10000)  ; tokens allocated for reasoning
```

The agent shows `[Thinking: N chars]` in verbose output. Thinking is incompatible with `tool_choice`, so the model chooses tools freely when thinking is enabled.

## Agent Swarm

`agent-swarm.lisp` is a multi-agent coordinator that decomposes tasks across specialists:

```
Coordinator (delegation + test_tool)
  ├─ ask_researcher  →  Researcher (web_search, read_file)
  ├─ ask_coder       →  Coder (eval_lisp, clear_repl, test_tool)
  ├─ ask_analyst     →  Analyst (shell, read_file)
  └─ test_tool       →  Test agent (any registered tool)
```

```bash
sbcl --load agent-swarm.lisp
```

### Self-Extending: Runtime Tool Creation

The swarm can create and register new MCP tools at runtime, then test them via a sub-agent that discovers the tool from its schema alone. Tools created during a session persist in the registry and are available to subsequent tasks.

Example session ([full trace](swarm-create-and-register-a-new-mcp-tool-call.log)):

```
swarm> create and register a new MCP tool called add-n -- that should take
       at least 1 integer and add them all. once done, call this new tool
       a few times, with different values

>> CODER: defines add-n via eval_lisp, tests with pp, runs test_tool
   [Thinking: 1989 chars]
   [cache hit: 1,160]
   Test 1 - Sum of [1, 2, 3, 4, 5]:  → 15
   Test 2 - Single integer [42]:      → 42
   Test 3 - Mix [-5, 10, -3, 8]:      → 10
   test_tool smoke test: 10+25+7+13   → 55

>> TEST-AGENT: coordinator calls add_n via test_tool
   7 + 8 + 9     → 24
   100+200+300+50 → 650
   -5+10-15+25    → 15
   42             → 42
```

The coder defines the tool, unit-tests it with `pp`, then `test_tool` spawns a fresh agent that only sees `add_n` in its tool list — verifying the schema and description work end-to-end.

## Behavioral Specs

A specification DSL for capturing domain models as structured metadata — entities, rules, and invariants — queryable and testable at the REPL or via MCP tools. Inspired by [JUXT Allium](https://github.com/juxt/allium) but executable from day one.

```lisp
(defentity account ()
  (id string :required t :unique t)
  (balance number :required t :default 0)
  (:belongs-to owner :of user))

(defrule withdraw
  :when (account :state :active)
  :requires ((>= (account-balance account) amount))
  :ensures ((= (account-balance account) (- old-balance amount))))

(definvariant non-negative-balance
  :on account
  :check (>= (account-balance account) 0))
```

### Property-Based Testing

Generate random entity instances and check invariants — with counterexamples on failure:

```lisp
(run-pbt :trials 200)

;; === PBT Results ===
;;
;; account (1 invariants)
;;   104/200 passed, 96 FAILED
;;   counterexample: (:BALANCE -876.8)
;;     violated: non-negative-balance
```

### JSON Persistence

Export specs as JSON (conforming to JSON Schema 2020-12) for version control and cross-session persistence:

```lisp
(specs-to-json)    ;; => JSON string
(json-to-specs s)  ;; import from JSON
```

### Claude Code Integration

Copy [`etc/spec-CLAUDE.md`](etc/spec-CLAUDE.md) into your project's `CLAUDE.md` to teach Claude Code the spec-first workflow. Claude will then define specs via `eval_lisp` before generating code.

## A2A (Agent-to-Agent Protocol)

Partial implementation of [A2A 1.0](https://a2a-protocol.org/latest/specification/). Covers agent card discovery, messaging, skills, and task lifecycle. Does not implement streaming, push notifications, or security schemes. No conformance suite exists for A2A.

## Conformance Testing

Run the MCP conformance suite against this SDK:

```bash
# Start the conformance server
sbcl --load conformance-server.lisp

# In another terminal
npx @modelcontextprotocol/conformance server --url http://localhost:8080/mcp

# Client conformance
npx @modelcontextprotocol/conformance client \
  --command "sbcl --non-interactive --load conformance-client.lisp"
```

## Stress Testing

Two test scripts, both targeting the conformance server:

```bash
sbcl --load conformance-server.lisp   # terminal 1
```

**soak-test.py** -- uniform load, single scenario, simple stats:
```bash
uv run soak-test.py --concurrency 50
```

**stress-test.py** -- multi-scenario with per-scenario stats and result verification:
```bash
uv run stress-test.py --concurrency 20
```

Runs three scenario types concurrently:
- **simple** -- conformance tools, resources, prompts (content assertions)
- **eval** -- multi-step `eval_lisp` sessions: define functions, call with random inputs, verify computed results, clear sandbox, verify isolation
- **errors** -- bad tool names, missing params, syntax errors, nonexistent resources

Reports per-scenario req/s, latency percentiles, assertion failures, heap usage, and leak detection. Ctrl-C to stop.

## Self-Hosting Tricks

The Streamable HTTP server can serve as its own MCP client, enabling some entertaining self-referential tests.

### Eval Quine

A `format`-based quine — code that evaluates to its own source:

```lisp
(let ((s "(let ((s ~s)) (format nil s s))"))
  (format nil s s))
;; => "(let ((s \"(let ((s ~s)) (format nil s s))\")) (format nil s s))"
```

### MCP Inception

The server connects to itself as a client, and through that connection evals code that connects *again*, recursively:

```
Claude → eval_lisp → HTTP client → server → eval_lisp → HTTP client → server → ...
```

Each layer adds another level of JSON string escaping. At depth 4 you get 15 layers of backslashes, but the server handles it without deadlocking.

### Concurrent Self-Connection Stress Test

From inside the running server, spawn threads that each run full MCP session lifecycles back against the same server:

```lisp
;; 100 concurrent workers × 100 iterations = 10,000 sessions, 90,000 requests
;; Results on Apple M4 Pro:
;;   10 workers:  15,223 req/s, 0 errors
;;   50 workers:  17,238 req/s, 0 errors
;;  100 workers:  12,717 req/s, 0 errors
```

## Testing

```bash
make test    # 438 unit tests
make clean   # remove .fasl files
```

## License

Dual-licensed under MIT OR Apache-2.0.
