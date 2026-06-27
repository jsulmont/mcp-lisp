---
paths:
  - "tests/**"
  - "**/*-tests.lisp"
---

# Test conventions (`tests/`)

- fiveam. One file per area, named `<area>-tests.lisp`, mirroring the `src/` area
  it covers (e.g. `dispatcher-tests.lisp` ↔ `src/server/dispatcher.lisp`).
- Register suites so `(mcp-lisp/tests:run-tests)` discovers them; run via
  `make test`.
- A change under `src/<area>` should land with assertions in the matching
  `<area>-tests.lisp`.
- Never assert "tests pass" without running `make test` — paste the real output.
