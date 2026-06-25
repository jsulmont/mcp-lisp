# Sampling / Logging / Progress demo

A client + server demonstrating three MCP server→client features in one tool
call. It calls two external services — the Tavily Search API and the Anthropic
API — so it needs network access and the two keys below (it's not self-contained
or free to run).

| Feature      | API used                | What you see                                  |
|--------------|-------------------------|-----------------------------------------------|
| **logging**  | `tool-log`              | `notifications/message` printed live          |
| **progress** | `tool-report-progress`  | `notifications/progress` (0/4 → 4/4) live     |
| **sampling** | `tool-sample`           | the server borrows the *client's* LLM         |

The server's `research` tool searches the web with **Tavily** (server-side), then
asks the **calling client's** model to synthesize a cited answer via MCP sampling.
The synthesis model is owned by the host, not the server — that is the point of
sampling: the server has no LLM key of its own for that step.

```
client (host)                         server (research tool)
  │  tools/call research ───────────────▶ tool-log "info"           ──▶ notifications/message
  │                                        tool-report-progress 0/4  ──▶ notifications/progress
  │                                        Tavily web search (TAVILY_API_KEY)
  │  ◀── sampling/createMessage ────────── tool-sample(...)          (server asks the host's LLM)
  │  → Anthropic /v1/messages (ANTHROPIC_API_KEY)
  │  ── result (assistant text) ─────────▶ tool-report-progress 4/4
  │  ◀── tools/call result ─────────────── synthesized answer + sources
```

## Requirements

A `.env` file in the **project root** (`../../.env` from here) with:

```
ANTHROPIC_API_KEY=sk-ant-...     # used by the CLIENT to answer sampling
TAVILY_API_KEY=tvly-...          # used by the SERVER for web search
```

Keys are read at runtime; they are never written into the code.

**The demo only runs when the keys are present.** If a key is missing (not
exported and not in `.env`), each piece exits cleanly with a message instead of
failing mid-run: the server won't start without `TAVILY_API_KEY`, the client
skips without `ANTHROPIC_API_KEY`, and `run.sh` checks both up front.

## Run

One command (starts the server, runs the client, tears the server down):

```sh
examples/sampling-demo/run.sh "What is the Model Context Protocol?"
```

Or as two processes, for real client/server separation over Streamable HTTP:

```sh
# terminal 1 — start the server (listens on http://localhost:8080/mcp)
sbcl --load examples/sampling-demo/server.lisp

# terminal 2 — run the client with a question
sbcl --script examples/sampling-demo/client.lisp "What is the Model Context Protocol?"
```

Example output (notifications arrive live, interleaved with the tool running):

```
  log [info] Researching: What is the Model Context Protocol?
  progress 0/4  Searching the web
  progress 1/4  Found 5 result(s)
  progress 2/4  Asking your model to synthesize (sampling)
  log [debug] Issuing sampling/createMessage to the client
  progress 4/4  Done
## Model Context Protocol (MCP)
... cited answer ...
--- Sources ---
[1] ...
```

## How it works

**Transport.** Sampling and progress require a transport that can carry
server→client messages, so the server runs on Streamable HTTP (Woo) and the
client uses `make-http-client`. The HTTP client reads the SSE response stream
incrementally, so it can answer the server's mid-stream `sampling/createMessage`
request before the tool's response arrives. (The stdio transport supports the
same round-trip and would work too.)

**Progress needs a token.** `tool-report-progress` is a no-op unless the client
includes a `progressToken` in the request's `_meta`. The client therefore calls
`tools/call` with `_meta: {progressToken: ...}` rather than the plain
`call-tool` helper — see `client.lisp`.

**Logging level.** The client sends `logging/setLevel "debug"` so the server's
`debug`-level log is delivered; without it the session default (`info`) would
filter it out.

**The sampling handler.** `client.lisp` registers a `client-request-handler`
that maps `sampling/createMessage` params onto the Anthropic Messages API and
returns the result in MCP shape (`{role, content:{type,text}, model, stopReason}`).

## Notes

- Default sampling model is `claude-sonnet-4-6` (`client.lisp`, `*model*`). It
  accepts the `temperature` the handler forwards; swap to `claude-haiku-4-5` for
  a cheaper run. Opus 4.8 rejects `temperature`, so drop that field if you use it.
- The server's `stream-call` waits up to 30s for the sampling reply; a slow
  Anthropic call with large `max_tokens` could exceed that.
