# tool-search example

Demonstrates the Anthropic **tool search tool** + **`defer_loading`** support in
the agent loop (`*tool-search*` in `src/agent/agent.lisp`), driven against a real
MCP server over **HTTP (Streamable HTTP / SSE)** and the real Anthropic API.

## What it does

- `server.lisp` is a mock **cloud-ops MCP server** exposing **12 tools** over
  HTTP on `http://localhost:8930/mcp` (`instance_*`, `bucket_*`, `log_query`,
  `alert_*`, `billing_summary`, `service_*`). The bodies return canned data, and
  each call is printed to the server's own console via `slog`.
- `client.lisp` connects over HTTP, lists the server's tools, and **bridges**
  each one into an agent registry — the handler proxies `tools/call` back to the
  server.
- It then sets `*provider* :anthropic`, `*tool-search* :regex`, and runs the
  agent. With tool search on and `*tool-search-keep-loaded*` empty, **all 12
  tools are deferred**: the model starts with only the tool search tool in
  context and must search the catalog (`service`, `billing`, …) to discover the
  tools it needs before calling them.

This exercises `defer_loading: true` on every tool plus the server-side
`tool_search_tool_regex` round-trip end to end.

## Run (two terminals)

Needs an Anthropic key in `$ANTHROPIC_API_KEY` or `~/.anthropic-key`, and a
tool-search-capable model (default `claude-sonnet-4-6`; the agent's own default
`claude-sonnet-4-20250514` is too old).

**Terminal 1 — start the server and watch it:**

```sh
sbcl --load examples/tool-search/server.lisp
```

It prints a banner, listens on `http://localhost:8930/mcp`, and then logs every
tool call as the agent makes it:

```
06:58:43  [cloud-ops] MCP server on http://localhost:8930/mcp — 12 tools, waiting for a client
06:58:51  [cloud-ops] service_health(service=web)
             => web: DEGRADED, 2/3 instances healthy, p99 latency 1200ms, error rate 4.1%
06:58:51  [cloud-ops] billing_summary()
             => MTD $4,213; projected $6,840. Top: compute $3,100, storage $640, egress $410
```

Leave it running. Stop it with Ctrl-C.

**Terminal 2 — run the agent client:**

```sh
examples/tool-search/run.sh
examples/tool-search/run.sh "List my buckets and report the size of backups-prod"
```

`run.sh` checks the server is up (`/health`) and then runs the client.

**From a REPL (Sly/SLIME):** `(load ".../client.lisp")` just defines things when
slynk is present — it won't auto-run or exit. Call `(tool-search-client::main)`
or `(tool-search-client::main "your prompt")` by hand; it returns `T`/`NIL` and
never kills the image. (The server must already be running.)

`*verbose*` is on, so the client prints `[Tool search: ...]` and `[Tool: ...]`
lines as the model searches and calls tools, then a final answer and token-usage
summary. Watch both terminals: the client shows the agent's view, the server
shows what it actually received.

## Notes

- Transport is Streamable HTTP; the MCP endpoint is `/mcp`, readiness is
  `/health`. (`/sse` is the legacy endpoint for `claude mcp add --transport sse`.)
- **Conversation transcript:** the client binds the agent's `*transcript*` to
  `/tmp/tool-search-agent.log`, a structured log of the whole exchange — the
  system and user prompts, each assistant turn with its `stop_reason`
  (`tool_use` / `end_turn`), the tool-search queries, and every tool call and
  result. `cat /tmp/tool-search-agent.log` after a run. Set
  `mcp-lisp:*transcript*` to any stream (e.g. `*standard-output*`) to redirect it.
- Server transport logs (woo/log4cl) go to `/tmp/tool-search-server.log` at
  `:info`; raise to `:debug` in `server.lisp` to see every JSON-RPC method.
  Client log4cl output goes to `/tmp/tool-search-client.log`.
- The example bridges remote MCP tools into a registry and passes it to
  `run-agent` via `:registry`; the agent executes discovered tools against that
  registry.
- To see the deferral effect, flip `*tool-search*` to `nil` in `client.lisp`:
  all 12 definitions then load up front with no search step.
