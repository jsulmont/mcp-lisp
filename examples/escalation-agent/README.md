# Escalation Agent — Claude Architect Exercise 1

A customer-support **refund agent** demonstrating an agentic loop with multi-tool
integration, structured error handling, and a business-rule escalation hook —
built as a real **MCP server + client** so the server actually **logs and reports
progress** as it works.

Two halves, like the `sampling-demo`:

- **`server.lisp`** — an mcp-lisp MCP server (Streamable HTTP) that defines the
  four refund tools with `define-tool`, returns the structured-error envelopes,
  and emits `tool-log` (→ `notifications/message`) and `tool-report-progress`
  (→ `notifications/progress`) as each tool runs.
- **`client.lisp`** — the host. It discovers the tools via `tools/list`, runs the
  agentic `stop_reason` loop against Claude (`claude-opus-4-8`), applies the
  **client-side pre-tool hook**, calls the MCP tools, and prints the server's
  logging/progress notifications **live**.

The escalation rule lives in the **client** (a model-independent interceptor), so
the server tools are plain capabilities — a $980 card refund would go through on
the server; the client is what stops it.

## Run

```sh
examples/escalation-agent/run.sh                 # built-in multi-concern prompt
examples/escalation-agent/run.sh "your message"  # custom message
```

The runner starts the server, waits for `/health`, then runs the client. It is
**key-gated**: it no-ops unless `ANTHROPIC_API_KEY` is set in the environment or
the project-root `.env`. (The server itself needs no keys.)

To run the halves by hand:

```sh
sbcl --load   examples/escalation-agent/server.lisp     # terminal 1
sbcl --script examples/escalation-agent/client.lisp "…" # terminal 2
```

## How it maps to the five exercise steps

| Step | Requirement | Where |
|------|-------------|-------|
| 1 | 3–4 MCP tools, incl. two confusable ones | `server.lisp` `define-tool`s — `lookup_order`, `check_refund_eligibility`, and the deliberately similar **`issue_card_refund`** (money back to the card) vs **`apply_account_credit`** (store credit). Their docstrings carefully draw the boundary so the model picks correctly. |
| 2 | Agentic loop on `stop_reason` (`tool_use` / `end_turn`) | `client.lisp` `run-loop` — `tool_use` runs tools and continues, `end_turn` returns the final text (`max_tokens` / `refusal` handled too). |
| 3 | Structured tool errors (`errorCategory` / `isRetryable` / message) | `server.lisp` `err-result` → `{ok:false, errorCategory, isRetryable, message}`. The first `lookup_order` fails **transiently** (`isRetryable: true`) so the model retries; unknown orders are `validation` errors (`isRetryable: false`) the model must explain instead of retrying. |
| 4 | Programmatic hook enforcing a business rule → escalation | `client.lisp` `escalation-hook` (a pre-tool interceptor) blocks `issue_card_refund` over `*refund-limit*` ($500) **before** the MCP call, returning a `permission` error with an escalation ticket. |
| 5 | Multi-concern message → decompose → handle each → synthesize | `*default-prompt*` raises two issues; the agent decomposes them, handles each, and synthesizes one summary. |

## What you should see

The transcript interleaves the agent's turns with the **server's live
notifications** (`· log […]` and `· progress n/total …`). With the default prompt:

1. **Transient retry** — the first `lookup_order` logs a gateway timeout and
   returns a retryable error; the model retries and succeeds.
2. **Tool disambiguation** — the customer says "back to my card", so the model
   chooses `issue_card_refund`, not `apply_account_credit`.
3. **A100 ($240)** refunds to the card normally (watch the progress steps).
4. **B200 ($980)** is intercepted by the client hook (`· [hook] blocked … —
   escalating`), returned as an escalation, and the model tells the customer it's
   under review (ticket `ESC-7782`) instead of retrying.
5. **Synthesis** — a final message covering both issues and their outcomes.

Because it is a live model, exact wording and tool ordering vary between runs.

## Tweaks to try

- Lower `*refund-limit*` (client) to `200` → A100 escalates too.
- Change the prompt to "I'll take store credit" → the model should switch to
  `apply_account_credit` (tests the confusable-tool boundary).
- Comment out the `escalation-hook` call in `execute-tools` → the $980 refund
  goes through on the server, showing the hook is what enforces the rule.
- Raise/lower `logging/setLevel` in the client to see more/fewer server logs.
