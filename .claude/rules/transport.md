---
paths:
  - "src/transport/**"
---

# Transport conventions (`src/transport/`)

- Two transports: **stdio** and **Streamable HTTP** (Woo / SSE).
- Server→client features — sampling, progress, logging, elicitation — only flow
  over a transport that can carry server→client messages (HTTP/SSE), **not** plain
  stdio. Guard such code with `tool-streaming-available-p` and degrade gracefully.
- `mcp-woo.lisp` is the largest and most delicate file (SSE server + worker pool +
  evloop bridges). Preserve the worker-pool/bridge structure; don't inline blocking
  work into the event loop.
