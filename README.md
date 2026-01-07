# mcp-lisp

Common Lisp SDK for [Model Context Protocol](https://modelcontextprotocol.io) (MCP) and [Agent-to-Agent Protocol](https://github.com/google/A2A) (A2A).

## Requirements

- [SBCL](http://www.sbcl.org/) (Steel Bank Common Lisp)
- [Quicklisp](https://www.quicklisp.org/)

## Installation

Clone the repository and add it to your ASDF registry:

```lisp
(pushnew #p"/path/to/mcp-lisp/" asdf:*central-registry*)
(ql:quickload :mcp-lisp)
```

## MCP Server

Create an MCP server with tools, prompts, and resources:

```lisp
(defpackage #:my-server
  (:use #:cl #:mcp-lisp))

(in-package #:my-server)

;; Define a tool
(define-tool echo ((message string "The message to echo" :required t))
  "Echoes the input message back."
  (format nil "Echo: ~a" message))

;; Define a prompt
(define-prompt summarize ((text string "Text to summarize" :required t))
  "Generate a summarization prompt."
  (list (make-ht "role" "user"
                 "content" (make-ht "type" "text"
                                    "text" (format nil "Summarize: ~a" text)))))

;; Define a resource
(define-resource "config://info"
  (:name "Server Info" :mime-type "application/json")
  "Returns server information."
  (encode-json (make-ht "name" "my-server" "version" "1.0.0")))

;; Start server (stdio transport for Claude Code - blocking)
(run-server :name "my-server" :version "1.0.0" :transport :mcp-stdio)
```

Run as an MCP server:

```bash
sbcl --script my-server.lisp
```

### Transports

- `:mcp-stdio` - Newline-delimited JSON over stdio (for Claude Code, blocking)
- `:sse` - Server-Sent Events over HTTP (non-blocking)

### REPL Development

For interactive development, use `:sse` transport which runs in a background thread:

```lisp
;; Start server in background
(defvar *server* (make-server :name "my-server" :version "1.0.0"))
(server-start *server* :transport :sse :port 8080)

;; ... develop, test ...

;; Stop when done
(server-stop *server*)
```

## MCP Client

Connect to an MCP server programmatically:

```lisp
(in-package #:mcp-lisp)

;; Using with-client macro (recommended)
(with-client (c "sbcl" "--script" "echo-server.lisp")
  (format t "Server: ~a~%" (gethash "name" (client-server-info c)))

  ;; List available tools
  (dolist (tool (list-tools c))
    (format t "Tool: ~a~%" (gethash "name" tool)))

  ;; Call a tool
  (let ((result (call-tool c "echo" :message "Hello!")))
    (format t "Result: ~a~%" (gethash "text" (elt result 0)))))

;; Manual lifecycle management
(let ((client (make-client "sbcl" "--script" "server.lisp")))
  (client-connect client)
  (client-initialize client)
  ;; ... use client ...
  (client-shutdown client))
```

## A2A (Agent-to-Agent Protocol)

A2A enables peer-to-peer agent communication with tasks and skills.

### Agent Card

```lisp
(define-agent-card
  :name "my-agent"
  :description "An example agent"
  :url "http://localhost:8080"
  :version "1.0.0")
```

### Skills

```lisp
(define-skill analyze
    ((code string "Code to analyze" :required t))
  "Analyzes code for issues."
  ;; Skill implementation
  (analyze-code code))
```

### Tasks and Messages

```lisp
;; Create a task
(let ((task (create-task)))
  (add-task-message task (make-message "user"
                           (list (make-text-part "Analyze this code"))))
  (update-task-status task "completed"))

;; A2A Client
(let ((client (make-a2a-client "http://agent-url/.well-known/agent.json")))
  (fetch-agent-card client)
  (send-message client task-id message))
```

### A2A Server

```lisp
(start-a2a-server :port 8080)
;; Server exposes /.well-known/agent.json and handles A2A requests
(stop-a2a-server)
```

## Examples

See the `examples/` directory:

- `echo-server.lisp` - MCP server with tools, prompts, resources
- `echo-server-sse.lisp` - SSE transport variant
- `client-example.lisp` - MCP client usage

Run the echo server:

```bash
sbcl --script examples/echo-server.lisp
```

## Testing

```bash
make test
```

Or directly:

```bash
sbcl --non-interactive \
  --eval '(ql:quickload :mcp-lisp/tests :silent t)' \
  --eval '(mcp-lisp/tests:run-tests)'
```

## License

Dual-licensed under MIT OR Apache-2.0.
