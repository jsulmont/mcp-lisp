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
make test    # 317 unit tests
make clean   # remove .fasl files
```

## License

Dual-licensed under MIT OR Apache-2.0.
