#!/usr/bin/env bash
# Interactive: record from microphone, send to MiMo, print result.
#
# Usage:
#   ./record_test.sh [seconds]      # default 5s
#   ./record_test.sh                # 5s default
#
# Press Ctrl+C during recording to abort.
set -euo pipefail
cd "$(dirname "$0")"

SECONDS_TO_RECORD="${1:-5}"
PORT="${PORT:-8765}"
URL="http://127.0.0.1:${PORT}"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${HOME}/voice-input-mimo-recordings"
WAV="${OUTDIR}/${TS}.wav"

mkdir -p "$OUTDIR"

require() { command -v "$1" >/dev/null || { echo "missing: $1"; exit 1; }; }
require rec
require curl
require jq

echo "=== MiMo-V2.5-ASR  Manual Test ==="
echo "Server: $URL"
echo "File:   $WAV"
echo
echo "→ Recording ${SECONDS_TO_RECORD}s. Speak now (mixed Chinese/English OK)..."
echo

# 16 kHz mono PCM16 WAV — what MiMo expects
rec -q -r 16000 -c 1 -b 16 -e signed-integer "$WAV" trim 0 "$SECONDS_TO_RECORD"

echo "→ Saved: $(du -h "$WAV" | cut -f1)"
echo
echo "→ Probing $URL ..."
curl -sf "${URL}/v1/health" | jq .
echo
echo "→ Transcribing (auto language detect) ..."
RESP="$(curl -sf -X POST "${URL}/v1/audio/transcriptions" \
    -F "file=@${WAV}" \
    -F "language=auto")"
echo "$RESP" | jq .
echo
echo "Recording kept at: $WAV"
echo "(re-test with: curl -X POST $URL/v1/audio/transcriptions -F file=@$WAV -F language=auto | jq .)"
