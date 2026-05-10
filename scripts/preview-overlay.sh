#!/usr/bin/env bash
# Capture the dual-line bothReady overlay for visual verification.
# Boots the app in OVERLAY_DEMO mode (no audio, no keyboard wiring), waits
# for the overlay to render, then screenshots the overlay window only.
#
# Requires: Screen Recording permission for the parent terminal process.
#
# Usage:
#   bash scripts/preview-overlay.sh [output-path]
# Default output: /tmp/voice-input-mimo-overlay.png

set -euo pipefail

OUT="${1:-/tmp/voice-input-mimo-overlay.png}"
APP="/Applications/VoiceInputMimo.app"

if [[ ! -d "$APP" ]]; then
    echo "❌ $APP not found — run 'make install' first" >&2
    exit 1
fi

echo "→ Killing any running VoiceInputMimo instance"
pkill -f VoiceInputMimo 2>/dev/null || true
sleep 1

echo "→ Launching $APP with OVERLAY_DEMO=1"
VOICE_INPUT_MIMO_OVERLAY_DEMO=1 open "$APP"
sleep 2

echo "→ Locating overlay panel via Quartz"
WIN_ID=$(/usr/bin/python3 <<'PY'
from Quartz import (
    CGWindowListCopyWindowInfo,
    kCGWindowListOptionOnScreenOnly,
    kCGNullWindowID,
)

# The overlay is a borderless NSPanel — has no kCGWindowName. Match by
# owner + a height heuristic (overlay is ~80 px tall in dual-line mode).
infos = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) or []
candidates = []
for w in infos:
    owner = w.get("kCGWindowOwnerName", "") or ""
    if "VoiceInputMimo" not in owner:
        continue
    bounds = w.get("kCGWindowBounds", {}) or {}
    h = bounds.get("Height", 0)
    # bothReady dual-line height = 80
    if 70 <= h <= 100:
        candidates.append((int(w["kCGWindowNumber"]), bounds))

if candidates:
    print(candidates[0][0])
else:
    print("0")
PY
)

if [[ "$WIN_ID" == "0" ]]; then
    echo "❌ Overlay panel not found — demo may not have triggered" >&2
    exit 2
fi

echo "→ Capturing window id=$WIN_ID to $OUT"
screencapture -l "$WIN_ID" -o -x "$OUT"

if [[ ! -s "$OUT" ]]; then
    echo "❌ Screenshot empty — likely missing Screen Recording permission" >&2
    exit 3
fi

WH=$(sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null | awk '/pixel/ { print $2 }' | paste -sd 'x' -)
echo "✅ Captured $WH → $OUT"

# Leave the app running so the user can inspect / hover the overlay manually.
echo "→ App still running with overlay visible — kill with: pkill -f VoiceInputMimo"
