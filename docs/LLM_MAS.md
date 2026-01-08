# LLM-Based Multi-Agent Systems

Research notes on building **hierarchical, tool-using LLM agent systems** with clear separation between:

- **Intra-agent capability access** (MCP)
- **Inter-agent collaboration** (A2A)

The default architecture is **strictly hierarchical**, with no shared mutable global state.

> **Design principles:**  
> - Think locally, act globally.  
> - Each agent owns its task and its subtree.  
> - If you need shared global state, your coordinator is too weak.

---

## Context

Goal: Build a demo with MCP client + servers, potentially extending to full multi-agent orchestration using the A2A protocol.

Non-goals:

- Fully decentralized swarms
- Peer-to-peer emergent behavior
- Agent “societies”
- Distributed consensus for its own sake

The system is designed as a **supervision tree of autonomous nodes**.

---

## Protocols Overview

### MCP (Model Context Protocol)

Anthropic's protocol for connecting LLMs to tools and data.

| Aspect | Description |
|--------|-------------|
| **Relationship** | Client (has LLM) → Server (has tools) |
| **Transport** | JSON-RPC 2.0 over stdio or HTTP/SSE |
| **Primitives** | Tools, Resources, Prompts, Sampling |
| **Direction** | Hierarchical - client controls, server exposes |

```
Client (LLM) ←→ Server (tools/data)
```

**MCP answers:**  
> “How does an LLM access tools and external capabilities safely and uniformly?”

It does **not** deal with agents, workflows, or delegation.

---

### A2A (Agent-to-Agent Protocol)

Google's protocol for agent-to-agent communication.

| Aspect | Description |
|--------|-------------|
| **Relationship** | Peer ↔ Peer |
| **Transport** | JSON-RPC 2.0 over HTTP(S), SSE, webhooks |
| **Primitives** | Agent Cards, Skills, Tasks, Messages |
| **Direction** | Peer-to-peer - agents collaborate as equals |

```
Agent A ←→ Agent B ←→ Agent C
```

**A2A answers:**  
> “How do autonomous agents delegate work to each other and track long-running tasks?”

It does **not** care how an agent uses tools internally.

---

### MCP vs A2A

| Aspect | MCP | A2A |
|--------|-----|-----|
| **Relationship** | Hierarchical (client → server) | Peer-to-peer |
| **Exposure** | Tools, resources, prompts | Skills, tasks |
| **Opacity** | Server internals visible via schemas | Agents are black boxes |
| **Focus** | Connect LLM to capabilities | Connect agent to agent |

> **They are complementary, not competing.**

An A2A agent may internally use MCP to access tools, but presents itself as an **opaque peer** to other agents.

### The Full Picture: A Single Agent Node

```
┌─────────────────────────────────────────────┐
│              Agent Node                     │
│  ┌───────────────────────────────────────┐  │
│  │          LLM (reasoning)              │  │
│  └───────────────────────────────────────┘  │
│              │                 │            │
│         A2A (up/down)     MCP (tools)       │
│              │                 │            │
└──────────────┼─────────────────┼────────────┘
               │                 │
        Parent / Children    Tool Servers
```

- **A2A** faces outward: receives tasks from parent, delegates to children
- **MCP** faces inward: accesses tools, resources, data sources
- **LLM** decides what to do, when to delegate, which tools to call

---

## A2A Core Concepts

### Agent Cards

JSON metadata documents for discovery:

- Identity and provider info
- Capabilities declaration
- Skills inventory
- Authentication requirements
- Endpoint URLs

### Tasks

Unit of work with lifecycle:

- **States**: Active → Completed / Failed / Canceled
- **Contains**: ID, status, artifacts, message history, metadata
- **Supports**: Async operations, human-in-the-loop

### Messages

Communication turns:

- **Role**: "user" or "agent"
- **Parts**: TextPart, FilePart, DataPart
- **Multi-turn**: Sequential exchanges within task context

### Interaction Patterns

1. **Synchronous**: Direct request/response  
2. **Streaming**: Server-Sent Events for real-time  
3. **Asynchronous**: Push notifications (webhooks)

---

## Multi-Agent Architectures

### Network (not the default)

Any agent can call any other agent.  
Use only when no stable hierarchy exists.

```
Agent A ←→ Agent B
   ↕         ↕
Agent C ←→ Agent D
```

---

### Supervisor (default)

A central coordinator delegates to specialists.

```
      Supervisor
       /   |   \
      ↓    ↓    ↓
   Agent Agent Agent
     A     B     C
```

---

### Hierarchical

Supervisor of supervisors.

```
         Top Supervisor
            /      \
     Team Lead    Team Lead
      /    \        /    \
   Agent  Agent  Agent  Agent
```

This is the **primary target architecture**.

---

### Recursive Structure

The architecture is **fractal** — every node has the same shape:

```
┌─────────────────────────────────────────────┐
│              Agent Node                     │
│  ┌───────────────────────────────────────┐  │
│  │          LLM (reasoning)              │  │
│  └───────────────────────────────────────┘  │
│              │                 │            │
│         A2A (↑↓)          MCP (→)          │
│              │                 │            │
└──────────────┼─────────────────┼────────────┘
               │                 │
        Parent/Children     Tool Servers
```

Whether Top Supervisor, Team Lead, or Leaf Agent — same structure:

- Receives tasks from parent (A2A up)
- Delegates to children (A2A down)
- Calls tools (MCP)
- Reasons about what to do (LLM)

Like Erlang/OTP supervision trees: the pattern repeats at every level.

---

### Tool-Calling Supervisor

Specialists are exposed as tools to a single LLM.

```
Supervisor (tool-calling LLM)
    │
    ├── tool: agent_a(query)
    ├── tool: agent_b(query)
    └── tool: agent_c(query)
```

This is an **implementation technique**, not a conceptual model.

---

## Knowledge and State

### The Reality

Each LLM agent has:

- Its own context window
- Its own working memory
- No shared state by default

There is **no natural global memory** in LLM systems.

---

### Default Rule

> **No shared mutable state between agents.**

Instead:

- The **coordinator holds context**
- Agents are **stateless workers**
- Results flow **upward**

---

### When Shared State Might Appear

Only if:

- There is no stable coordinator
- Tasks are long-running across agent lifetimes
- Agents must work while disconnected
- Or the system is intentionally decentralized

In those cases, shared storage is an **infrastructure component**, not an agent feature.

---

### Alternatives to Shared State

| Problem | Solution |
|--------|----------|
| Avoid duplicate work | Coordinator tracks assignments |
| Build on results | Pass outputs through coordinator |
| Ensure consistency | Coordinator is source of truth |
| Long-running context | Coordinator persists state |

---

### Key Insight

> **Global knowledge = weak coordinator**

---

## Consensus (Mostly Not Needed)

Classical consensus (Raft/Paxos) assumes:

- Deterministic state machines
- Log replication
- Byte-identical agreement

LLM systems are:

- Non-deterministic
- Semantic, not byte-exact
- Coordinator-driven

### What Might Need Agreement?

| Category | Example | How to handle |
|----------|---------|---------------|
| Facts | "Deadline is Jan 15" | Coordinator owns truth |
| Decisions | "Use approach X" | Judge agent or scoring |
| Tasks | "Agent A handles this" | Coordinator assigns |
| Opinions | "This code is bad" | No agreement needed |

> Consensus lives **inside the coordinator**, not between agents.

---

## Implementation: a2a-lisp

Built on top of mcp-lisp, which already provides:

- JSON-RPC 2.0 handling
- HTTP server (Hunchentoot)
- SSE streaming
- Tool definitions and dispatch

### Additional Components

| mcp-lisp | a2a-lisp |
|---------|----------|
| tools/list, tools/call | Agent Card, Skills |
| resources, prompts | Tasks (lifecycle) |
| stdio, SSE transport | message/send, message/stream |
| | Webhooks / callbacks |

---

### Core A2A Primitives

```lisp
;; Agent Card
(define-agent-card
  :name "my-agent"
  :description "Does X, Y, Z"
  :skills (list skill-a skill-b)
  :endpoint "http://localhost:8080")

;; Skills
(define-skill analyze-code
    ((code string "Code to analyze" :required t))
  "Analyzes code for issues."
  ...)

;; Tasks
(create-task agent message)
(get-task task-id)
(cancel-task task-id)
(subscribe-task task-id callback)

;; Messages
(send-message agent-url message)
(stream-message agent-url message callback)
```

---

## Open Engineering Questions

These are _plumbing_, not architectural drivers:

1. Discovery: static config vs registry
2. Security: mTLS, tokens, or similar
3. Failure: retry, fail task, or escalate to supervisor

---

## References

- MCP Specification: https://modelcontextprotocol.io
- A2A Protocol: https://github.com/google/A2A
- LangGraph Concepts: https://github.com/langchain-ai/langgraph
