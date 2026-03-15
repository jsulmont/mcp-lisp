# mcp-lisp

Common Lisp SDK for [Model Context Protocol](https://modelcontextprotocol.io) (MCP 2025-11-25) and [Agent-to-Agent Protocol](https://github.com/google/A2A) (A2A).

**40/40 conformance checks passing** against [`@modelcontextprotocol/conformance`](https://github.com/modelcontextprotocol/conformance).

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
- `:sse` -- Streamable HTTP on a configurable port, for interactive development and HTTP clients

```lisp
;; Non-blocking HTTP server for REPL development
(defvar *server* (make-server :name "my-server" :version "1.0.0"))
(server-start *server* :transport :sse :port 8080)
;; server running on http://localhost:8080/mcp
(server-stop *server*)
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
(setf mcp-lisp/src/transport/mcp-sse:*access-log-stream* *standard-output*)
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

Peer-to-peer agent communication with agent cards, skills, and tasks:

```lisp
(define-agent-card
  :name "my-agent"
  :description "An example agent"
  :url "http://localhost:8080"
  :version "1.0.0")

(define-skill analyze
    ((code string "Code to analyze" :required t))
  "Analyzes code for issues."
  (analyze-code code))

(start-a2a-server :port 8080)
```

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

## Testing

```bash
make test    # 182 unit tests
make clean   # remove .fasl files
```

## License

Dual-licensed under MIT OR Apache-2.0.
