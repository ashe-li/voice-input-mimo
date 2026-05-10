#!/usr/bin/env bash
# Preview E2E — capture the Clipboard History window for visual inspection.
#
# Closes the gap "I wrote SwiftUI, build passed, but I can't see what it
# looks like". Launches the installed app in preview mode, opens the
# Clipboard History window, screenshots it to a known path, and reports
# the path so the agent (or human) can `Read` the image.
#
# Requires: Screen Recording permission for the parent terminal (granted
# once via System Settings → Privacy → Screen Recording).
#
# Usage:
#   bash scripts/preview-screenshot.sh [output-path]
# Default output: /tmp/voice-input-mimo-clipboard-history.png

set -euo pipefail

OUT="${1:-/tmp/voice-input-mimo-clipboard-history.png}"
APP="/Applications/VoiceInputMimo.app"

if [[ ! -d "$APP" ]]; then
    echo "❌ $APP not found — run 'make install' first" >&2
    exit 1
fi

echo "→ Killing any running VoiceInputMimo instance"
pkill -f VoiceInputMimo 2>/dev/null || true
sleep 1

echo "→ Launching $APP with PREVIEW=1"
VOICE_INPUT_MIMO_PREVIEW=1 open "$APP"
sleep 3

echo "→ Triggering Clipboard History window (⌘⌥H)"
osascript <<'OSA'
tell application "System Events"
    tell process "VoiceInputMimo"
        set frontmost to true
    end tell
    keystroke "h" using {command down, option down}
end tell
OSA
sleep 2

echo "→ Locating Clipboard History window via Quartz"
WIN_ID=$(python3 <<'PY'
from Quartz import (
    CGWindowListCopyWindowInfo,
    kCGWindowListOptionOnScreenOnly,
    kCGNullWindowID,
)

infos = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) or []
for w in infos:
    owner = w.get("kCGWindowOwnerName", "")
    name = w.get("kCGWindowName", "") or ""
    if "VoiceInputMimo" in owner and "Clipboard History" in name:
        print(int(w["kCGWindowNumber"]))
        break
else:
    print("0")
PY
)

if [[ "$WIN_ID" == "0" ]]; then
    echo "❌ Clipboard History window not found — keystroke may not have triggered" >&2
    echo "   (Check Accessibility permission for the parent process)" >&2
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
