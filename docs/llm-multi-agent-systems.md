# LLM-Based Multi-Agent Systems

Research notes on building distributed LLM-based Multi-Agent Systems (MAS).

## Context

Goal: Build a demo with MCP client + servers, potentially extending to full multi-agent orchestration using the A2A protocol.

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

### MCP vs A2A

| Aspect | MCP | A2A |
|--------|-----|-----|
| **Relationship** | Hierarchical (client → server) | Peer-to-peer |
| **Exposure** | Tools, resources, prompts | Skills, tasks |
| **Opacity** | Server internals visible via schemas | Agents are black boxes |
| **Focus** | Connect LLM to capabilities | Connect agent to agent |

**They're complementary**: An A2A agent might internally use MCP to access tools, but presents itself as an opaque peer to other agents.

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

## Multi-Agent Architectures

From LangGraph's taxonomy:

### Network
Any agent can call any other agent (many-to-many).

```
Agent A ←→ Agent B
   ↕         ↕
Agent C ←→ Agent D
```

### Supervisor
Central LLM decides which specialist to call.

```
      Supervisor
       /   |   \
      ↓    ↓    ↓
   Agent Agent Agent
     A     B     C
```

### Hierarchical
Supervisor of supervisors (teams).

```
         Top Supervisor
            /      \
     Team Lead    Team Lead
      /    \        /    \
   Agent  Agent  Agent  Agent
```

### Tool-Calling Supervisor
Agents exposed as tools to supervisor LLM.

```
Supervisor (tool-calling LLM)
    │
    ├── tool: agent_a(query)
    ├── tool: agent_b(query)
    └── tool: agent_c(query)
```

## Knowledge Sharing

### The Problem

Each LLM agent has:

- Its own context window (limited)
- Its own conversation history
- No persistent memory by default

"Global knowledge" doesn't exist naturally - it must be architected.

### Approaches

| Pattern | How it works | Trade-offs |
|---------|--------------|------------|
| **Message passing** | Include knowledge in each message | Bloats context, redundant |
| **Shared blackboard** | Central store all agents read/write | Consistency issues, bottleneck |
| **Knowledge graph** | Structured facts agents query | Needs ontology, rigid |
| **Vector store (RAG)** | Embed & retrieve from shared corpus | Lossy, retrieval quality varies |
| **Coordinator agent** | One agent manages distribution | Single point of failure |

### A2A's Stance

A2A is deliberately **opaque** - agents don't share internal state. Knowledge flows via:

- Message content (explicit)
- Task artifacts (outputs)
- External resources (outside A2A scope)

## Do We Need Global Knowledge?

### When You Don't Need It

Hierarchical delegation model:

```
         User
           │
           ▼
      Coordinator
       /   |   \
      ▼    ▼    ▼
    Agent Agent Agent
      │     │     │
      ▼     ▼     ▼
   result result result
```

Each agent:

- Receives task from coordinator
- Works autonomously
- Returns result
- No peer communication needed

Coordinator aggregates results. No shared state required.

### When You Might Need It

| Scenario | Why shared state? |
|----------|-------------------|
| Avoid duplicate work | "Agent B already checked this file" |
| Build on each other | "Agent A found X, Agent B should use X" |
| Consistency | "We all agree the deadline is Jan 15" |
| Long-running collaboration | Agents come and go, context persists |

### Alternatives to Global State

| Scenario | Alternative |
|----------|-------------|
| Avoid duplicates | Coordinator tracks assignments |
| Build on each other | Pass results via coordinator |
| Consistency | Coordinator is source of truth |
| Long-running | Coordinator maintains context |

### Key Insight

**Global knowledge = weak coordinator**

If the coordinator is smart enough:

- It holds the context
- It routes information between agents
- It resolves conflicts

Global shared state becomes necessary when:

- No central coordinator (true peer-to-peer)
- Coordinator can't handle the complexity
- Agents need to work while disconnected

## Consensus

### Do LLM Agents Need Consensus?

Traditional consensus (Raft, Paxos) assumes:

- Deterministic state machines
- Byte-exact agreement
- Log replication

LLM agents are different:

- Non-deterministic (same prompt → different outputs)
- Semantic agreement (meaning, not bytes)
- Knowledge synchronization, not log replication

### What Might Need Agreement?

| Category | Example | Consensus needed? |
|----------|---------|-------------------|
| **Facts** | "The deadline is Jan 15" | Yes - single truth |
| **Decisions** | "Use approach X" | Maybe - voting/debate |
| **Tasks** | "Agent A handles this" | Yes - avoid duplicates |
| **Beliefs** | "This code looks buggy" | No - can disagree |

### Possible Patterns

1. **Single Source of Truth**: Knowledge store is authoritative, agents propose changes
2. **Voting**: Majority wins
3. **Debate + Judge**: Agents argue, judge agent decides
4. **Two-Phase Commit**: For critical state changes
5. **Leader Election**: One agent owns a knowledge domain

### For Hierarchical Autonomy

If each node is autonomous with its own coordinator:

```
Agent A (autonomous)
   │
   ├── sub-agent A1
   ├── sub-agent A2
   └── (A coordinates internally)
```

Then A2A is just about **delegation and results** - not shared knowledge. Consensus may not be needed.

## Implementation: a2a-lisp

Building on mcp-lisp, which already provides:

- JSON-RPC 2.0 handling
- HTTP server (Hunchentoot)
- SSE streaming
- Tool definitions and dispatch

### Additional Components Needed

| mcp-lisp (existing) | a2a-lisp (new) |
|---------------------|----------------|
| tools/list, tools/call | Agent Card, Skills |
| resources, prompts | Tasks (lifecycle) |
| stdio, SSE transport | message/send, message/stream |
| | Push notifications (webhooks) |

### Core A2A Primitives to Implement

```lisp
;; Agent Card
(define-agent-card
  :name "my-agent"
  :description "Does X, Y, Z"
  :skills (list skill-a skill-b)
  :endpoint "http://localhost:8080")

;; Skills (similar to tools)
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

## Open Questions

1. **Knowledge sharing**: Build into protocol or keep external?
2. **Consensus**: Needed for the target use cases?
3. **Discovery**: How do agents find each other? Registry? Broadcast?
4. **Security**: Authentication between agents?
5. **Failure handling**: What happens when an agent goes down mid-task?

## References

- [MCP Specification](https://modelcontextprotocol.io/specification/2025-11-25)
- [A2A Protocol (Google)](https://github.com/google/A2A)
- [LangGraph Multi-Agent Concepts](https://github.com/langchain-ai/langgraph)
