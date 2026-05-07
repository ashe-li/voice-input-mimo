#!/usr/bin/env bash
# Start the MiMo-V2.5-ASR FastAPI server.
#
# Env:
#   MIMO_PRECISION    int4 (default) | bf16
#   MIMO_MODEL_ROOT   ~/.cache/mimo-asr (default)
#   MIMO_PRELOAD      1 → load model on startup, 0 → on first request
#   PORT              8765 (default)
set -euo pipefail
cd "$(dirname "$0")"
PORT="${PORT:-8765}"
exec ./.venv/bin/python -m uvicorn server:app --host 127.0.0.1 --port "$PORT" --log-level info
