#!/usr/bin/env bash
# Run the escalation-agent demo (Claude Architect Exercise 1) end-to-end:
# starts the MCP server, then runs the client (which drives Claude and prints
# the server's logging/progress notifications live).
#
# Key-gated: only runs when ANTHROPIC_API_KEY is available (env or project .env).
#
# Usage: examples/escalation-agent/run.sh ["your message to the support agent"]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
env_file="$root/.env"

have_key() {
  local name="$1"
  [[ -n "${!name:-}" ]] && return 0
  [[ -f "$env_file" ]] && grep -qE "^[[:space:]]*${name}[[:space:]]*=[[:space:]]*[^[:space:]#]" "$env_file"
}

if ! have_key ANTHROPIC_API_KEY; then
  echo "[escalation-agent] Skipping — ANTHROPIC_API_KEY not set."
  echo "Add it to $env_file (or export it), then re-run."
  exit 0
fi

log="$(mktemp -t escalation-agent-server.XXXXXX)"
echo "[escalation-agent] starting MCP server (log: $log)"
sbcl --load "$here/server.lisp" >"$log" 2>&1 &
server_pid=$!
cleanup() { kill "$server_pid" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for the server to listen (up to ~60s).
for _ in $(seq 1 60); do
  if curl -sf -o /dev/null -m 2 http://localhost:8765/health; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "[escalation-agent] server exited early:"; cat "$log"; exit 1
  fi
  sleep 1
done

echo "[escalation-agent] running client"
sbcl --script "$here/client.lisp" "$@"
