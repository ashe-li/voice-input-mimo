#!/usr/bin/env bash
# Start the ASR engine on port 8766 (default) using the existing
# voice-input-mimo server venv (which has mimo_mlx + opencc + fastapi
# + uvicorn + psutil).
#
# Override port with PORT env var:
#   PORT=8888 ./scripts/run-engine.sh
#
# Override server venv path with SERVER_VENV env var.
set -euo pipefail

SERVER_VENV="${SERVER_VENV:-/Users/shiun/Documents/voice-input-mimo/server/.venv}"
PORT="${PORT:-8766}"
HOST="${HOST:-127.0.0.1}"

if [[ ! -x "$SERVER_VENV/bin/python" ]]; then
  echo "Server venv not found at: $SERVER_VENV" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

PYTHONPATH=. exec "$SERVER_VENV/bin/python" -m uvicorn engine.server:app \
  --host "$HOST" --port "$PORT" --log-level info
