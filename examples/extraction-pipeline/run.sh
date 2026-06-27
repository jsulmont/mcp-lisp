#!/usr/bin/env bash
# Run the structured-extraction pipeline demo (Claude Architect Exercise 3, steps 1-3).
# Key-gated: only runs when ANTHROPIC_API_KEY is available (env or project .env).
#
# Usage: examples/extraction-pipeline/run.sh [extract|batch|review|all]   (default: extract)
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
  echo "[extraction-pipeline] Skipping — ANTHROPIC_API_KEY not set."
  echo "Add it to $env_file (or export it), then re-run."
  exit 0
fi

sbcl --script "$here/pipeline.lisp" "$@"
