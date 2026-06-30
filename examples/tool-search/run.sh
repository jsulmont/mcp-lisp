#!/usr/bin/env bash
# Run the tool-search agent client against the cloud-ops MCP server.
#
# Start the server first, in its own terminal, so you can watch the live tool
# trace it prints:
#     sbcl --load examples/tool-search/server.lisp
#
# Then run this client (optionally with a prompt):
#     ./run.sh
#     ./run.sh "List my buckets and report the size of backups-prod"
#
# Requires an Anthropic key in $ANTHROPIC_API_KEY or ~/.anthropic-key.
set -euo pipefail
cd "$(dirname "$0")"
PORT=8930

if ! curl -sf -o /dev/null -m 2 "http://localhost:$PORT/health"; then
  echo "cloud-ops server is not reachable on http://localhost:$PORT"
  echo "Start it first in another terminal, then re-run:"
  echo "  sbcl --load $(pwd)/server.lisp"
  exit 1
fi

exec sbcl --script client.lisp "$@"
