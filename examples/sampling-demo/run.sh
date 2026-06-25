#!/usr/bin/env bash
# Run the sampling/logging/progress demo end-to-end.
# Only runs when the required keys are available (env or project-root .env):
#   ANTHROPIC_API_KEY  — the client answers sampling/createMessage via Claude
#   TAVILY_API_KEY     — the server's research tool searches the web
#
# Usage: examples/sampling-demo/run.sh ["your question"]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
env_file="$root/.env"
question="${1:-What is the Model Context Protocol and who created it?}"

# A key is available if exported, or present and non-empty in .env.
have_key() {
  local name="$1"
  [[ -n "${!name:-}" ]] && return 0
  [[ -f "$env_file" ]] && grep -qE "^[[:space:]]*${name}[[:space:]]*=[[:space:]]*[^[:space:]#]" "$env_file"
}

missing=()
have_key ANTHROPIC_API_KEY || missing+=("ANTHROPIC_API_KEY")
have_key TAVILY_API_KEY     || missing+=("TAVILY_API_KEY")
if (( ${#missing[@]} )); then
  echo "[sampling-demo] Skipping — missing key(s): ${missing[*]}"
  echo "Add them to $env_file (or export them), then re-run."
  exit 0
fi

log="$(mktemp -t sampling-demo-server.XXXXXX)"
echo "[sampling-demo] starting server (log: $log)"
sbcl --load "$here/server.lisp" >"$log" 2>&1 &
server_pid=$!
cleanup() { kill "$server_pid" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for the server to listen (up to ~60s).
for _ in $(seq 1 60); do
  if curl -sf -o /dev/null -m 2 http://localhost:8080/health; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "[sampling-demo] server exited early:"; cat "$log"; exit 1
  fi
  sleep 1
done

echo "[sampling-demo] running client"
sbcl --script "$here/client.lisp" "$question"
