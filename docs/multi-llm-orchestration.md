# Multi-LLM Orchestration via MCP Chaining

## Overview

A pattern where MCP clients and servers are chained to create hierarchical agent systems. Each layer can have its own LLM with different specializations.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ User                                                            │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│ Client A  (Coordinator)                                         │
│ ┌─────────┐                                                     │
│ │ LLM A   │  Generalist - understands user intent,              │
│ │(Claude) │  delegates to specialists                           │
│ └─────────┘                                                     │
│     Tools: [ask-code-expert, ask-data-expert, ...]              │
└─────────────────────┬───────────────────────────────────────────┘
                      │ MCP (tool call)
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│ Server B / Client B  (Specialist: Code Expert)                  │
│ ┌─────────┐                                                     │
│ │ LLM B   │  Specialist - deep knowledge of code,               │
│ │(Claude) │  knows how to use low-level tools                   │
│ └─────────┘                                                     │
│     Tools from C: [read-file, grep, ast-parse, run-tests, ...]  │
└─────────────────────┬───────────────────────────────────────────┘
                      │ MCP (tool calls)
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│ Server C  (Raw Capabilities)                                    │
│                                                                 │
│ Just tools, no LLM. File ops, git, compiler, etc.               │
└─────────────────────────────────────────────────────────────────┘
```

## Roles

| Component | Role | Has LLM? | MCP Role |
|-----------|------|----------|----------|
| Client A | Coordinator | Yes (generalist) | Client only |
| B | Specialist | Yes (domain expert) | Server to A, Client to C |
| Server C | Capability provider | No | Server only |

## Flow Example

```
User: "Is there a memory leak in my app?"

Client A (LLM A):
  "This needs code analysis. I'll delegate to the code expert."
  → calls tool: ask-code-expert("investigate memory leak")

Server B receives request, LLM B reasons:
  "Memory leak investigation. I should:
   1. Find allocation patterns
   2. Check for missing cleanup
   3. Look at long-lived objects"
  → calls: grep(pattern="malloc|alloc|new")
  → calls: ast-parse(file="main.c")
  → calls: grep(pattern="free|delete|close")
  → thinks: "Found 12 allocs, only 9 frees..."
  → returns: "Leak in foo.c:142 - socket opened but never closed"

Client A (LLM A):
  "Expert found the issue."
  → User: "There's a memory leak in foo.c line 142 -
           a socket is opened but never closed."
```

## Benefits

| Benefit | Explanation |
|---------|-------------|
| **Separation of concerns** | Coordinator doesn't need to know low-level tools |
| **Specialist prompting** | Each LLM has focused system prompt & context |
| **Cost control** | Use expensive model for coordination, cheaper for grunt work |
| **Different models** | Coordinator: Claude. Specialist: fine-tuned code model |
| **Parallel specialists** | A can call multiple specialists concurrently |
| **Encapsulation** | Swap out B's implementation without A knowing |

## Implementation Sketch (mcp-lisp)

### Server B: Exposes specialist tool to A

```lisp
(define-tool ask-code-expert
    ((question string "What to investigate" :required t))
  "Delegates to code analysis specialist."
  ;; B has its own LLM + client connection to C
  (let ((answer (run-specialist-llm question *tools-from-c*)))
    answer))
```

### B as both Server and Client

```lisp
;; B starts as server (for A to connect)
(defvar *specialist-server*
  (run-server :name "code-expert" :version "1.0.0" :transport :sse :port 8081))

;; B also connects as client to C
(defvar *tools-server*
  (make-client "sbcl" "--script" "raw-tools-server.lisp"))
(client-initialize *tools-server*)

;; B's specialist LLM loop (pseudocode)
(defun run-specialist-llm (question tools-client)
  (let ((tools (list-tools tools-client)))
    (loop
      ;; Call Claude API with specialist system prompt
      ;; Execute any tool calls via tools-client
      ;; Return final answer
      )))
```

## MCP Primitives Recap

| Primitive | Direction | Who defines | Who uses |
|-----------|-----------|-------------|----------|
| **Tools** | Server → Client | Server | LLM (via client) |
| **Resources** | Server → Client | Server | LLM (via client) |
| **Prompts** | Server → Client | Server | User (via client UI) |
| **Sampling** | Client → Server | Client provides | Server requests |

In chaining, the middle layer (B) participates in both directions.

## Next Steps

- [ ] Implement Claude API wrapper for Lisp
- [ ] Build a simple specialist (code-expert)
- [ ] Build a coordinator that delegates
- [ ] Test the full chain
