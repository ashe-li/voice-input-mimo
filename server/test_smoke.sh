#!/usr/bin/env bash
# Smoke test for the MiMo-V2.5-ASR FastAPI server.
#
# Generates short Chinese / Chinese-English mixed speech via `say`,
# converts to wav, then POSTs to /v1/audio/transcriptions.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8765}"
URL="http://127.0.0.1:${PORT}"
TMPDIR="${TMPDIR:-/tmp}"

require() {
    command -v "$1" >/dev/null || { echo "missing: $1"; exit 1; }
}
require say
require afconvert
require curl
require jq

probe_health() {
    local n=0
    until curl -sf "${URL}/v1/health" >/dev/null 2>&1; do
        n=$((n+1))
        if [ $n -gt 60 ]; then
            echo "❌ Server did not respond within 60s. Is it running?"
            exit 1
        fi
        sleep 1
    done
    curl -s "${URL}/v1/health" | jq .
}

gen() {
    local label="$1" voice="$2" text="$3"
    local aiff="${TMPDIR}/mimo-test-${label}.aiff"
    local wav="${TMPDIR}/mimo-test-${label}.wav"
    say -v "$voice" -o "$aiff" "$text"
    # AIFF-C → WAV (16kHz mono PCM16) via macOS afconvert
    afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$wav"
    rm -f "$aiff"
    echo "$wav"
}

call() {
    local label="$1" wav="$2" lang="$3" expected="$4"
    echo
    echo "=== [${label}] expected: ${expected}"
    local resp
    resp="$(curl -sf -X POST "${URL}/v1/audio/transcriptions" \
        -F "file=@${wav}" \
        -F "language=${lang}" 2>&1)" || { echo "❌ request failed: $resp"; return 1; }
    echo "$resp" | jq -r '"text: \(.text)\nelapsed: \(.duration_ms)ms"'
}

echo "→ probing ${URL}/v1/health ..."
probe_health
echo

echo "→ generating sample audio ..."
WAV_PURE_ZH="$(gen pure-zh 'Meijia' '幫我重構這個函式並加上型別註記')"
WAV_MIXED="$(gen mixed   'Meijia' '幫我重構這個 function 然後加個 useState 給 modal')"
WAV_TECH="$(gen tech    'Meijia' '使用本地的 LLM 透過 API 來識別語音')"
echo "  pure-zh: $WAV_PURE_ZH"
echo "  mixed:   $WAV_MIXED"
echo "  tech:    $WAV_TECH"

call "pure-zh" "$WAV_PURE_ZH" "auto" "幫我重構這個函式並加上型別註記"
call "mixed"   "$WAV_MIXED"   "auto" "幫我重構這個 function 然後加個 useState 給 modal"
call "tech"    "$WAV_TECH"    "auto" "使用本地的 LLM 透過 API 來識別語音"

echo
echo "✅ smoke test complete"
