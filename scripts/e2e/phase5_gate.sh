#!/bin/bash
# Phase 5 E2E gate — ClipboardHistory SwiftUI cards
#
# Asserts:
#   1. swift build warning-free
#   2. swift test all 143+ pass (Phase 4B 133 + Phase 5 ≥10)
#   3. ClipboardArchiveViewModel = @MainActor @Observable with required state
#      (entries / kindFilter / timeBucket / selectedEntryID + filteredEntries)
#   4. ClipboardHistoryView is SwiftUI (NavigationSplitView) with sidebar
#      filters and LazyVGrid card grid
#   5. ClipboardHistoryWindow is thin NSWindow shell (< 80 lines, no
#      NSTableView / NSTextView / dataSource clutter)
#   6. HistoryPane embeds ClipboardHistoryView (no placeholder copy)
#   7. AppKit isolation: SwiftUI History view + view model must not
#      leak NSTableView / NSPanel into the data layer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"

c_green "[phase5] 1/7 swift build (warning sweep)…"
BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build > "$BUILD_LOG" 2>&1; then
    c_red "swift build failed:"; cat "$BUILD_LOG"; exit 1
fi
if grep -E "warning:" "$BUILD_LOG" > /dev/null; then
    c_red "swift build emitted warnings:"; grep -E "warning:" "$BUILD_LOG"; exit 1
fi

c_green "[phase5] 2/7 swift test…"
run_swift_tests

c_green "[phase5] 3/7 ClipboardArchiveViewModel = @MainActor @Observable…"
VM="Sources/VoiceInputMimo/History/ClipboardArchiveViewModel.swift"
if [[ ! -f "$VM" ]]; then
    c_red "Missing $VM"; exit 1
fi
if ! grep -E "^@MainActor" "$VM" > /dev/null; then
    c_red "ClipboardArchiveViewModel must be @MainActor"; exit 1
fi
if ! grep -E "^@Observable" "$VM" > /dev/null; then
    c_red "ClipboardArchiveViewModel must use @Observable"; exit 1
fi
for prop in "entries" "kindFilter" "timeBucket" "selectedEntryID" "filteredEntries"; do
    if ! grep -E "var ${prop}" "$VM" > /dev/null; then
        c_red "ClipboardArchiveViewModel missing var: ${prop}"; exit 1
    fi
done

c_green "[phase5] 4/7 ClipboardHistoryView is SwiftUI (split + grid)…"
HV="Sources/VoiceInputMimo/History/ClipboardHistoryView.swift"
if [[ ! -f "$HV" ]]; then
    c_red "Missing $HV"; exit 1
fi
for token in "NavigationSplitView" "LazyVGrid" "ContentUnavailableView"; do
    if ! grep -F "$token" "$HV" > /dev/null; then
        c_red "ClipboardHistoryView must use ${token}"; exit 1
    fi
done
if ! grep -E "^#Preview" "$HV" > /dev/null; then
    c_red "ClipboardHistoryView missing #Preview"; exit 1
fi

c_green "[phase5] 5/7 ClipboardHistoryWindow is thin NSWindow shell…"
SHELL_FILE="Sources/VoiceInputMimo/ClipboardHistoryWindow.swift"
LINE_COUNT=$(wc -l < "$SHELL_FILE")
if (( LINE_COUNT > 80 )); then
    c_red "ClipboardHistoryWindow.swift is $LINE_COUNT lines (> 80) — should be a thin shell"; exit 1
fi
if grep -vE "^[[:space:]]*///" "$SHELL_FILE" | grep -E "NSTableView|NSTextView|NSTableColumn|dataSource|NSTableViewDelegate" > /dev/null; then
    c_red "ClipboardHistoryWindow.swift still contains AppKit table widgets"; exit 1
fi
if ! grep -F "NSHostingController" "$SHELL_FILE" > /dev/null; then
    c_red "ClipboardHistoryWindow.swift must host SwiftUI via NSHostingController"; exit 1
fi
if ! grep -F "ClipboardHistoryView" "$SHELL_FILE" > /dev/null; then
    c_red "ClipboardHistoryWindow.swift must instantiate ClipboardHistoryView"; exit 1
fi

c_green "[phase5] 6/7 HistoryPane embeds ClipboardHistoryView…"
HP="Sources/VoiceInputMimo/Settings/Panes/HistoryPane.swift"
if ! grep -F "ClipboardHistoryView()" "$HP" > /dev/null; then
    c_red "HistoryPane must embed ClipboardHistoryView()"; exit 1
fi
if grep -vE "^[[:space:]]*///" "$HP" | grep -E "Phase 5|placeholder|Coming in Phase" > /dev/null; then
    c_red "HistoryPane still contains placeholder copy"; exit 1
fi

c_green "[phase5] 7/7 No AppKit table widgets in History/ SwiftUI layer…"
if grep -lE "NSTableView|NSTableColumn|NSTableViewDelegate" Sources/VoiceInputMimo/History/*.swift > /dev/null 2>&1; then
    c_red "History/ SwiftUI layer must not import AppKit table widgets"; exit 1
fi

c_green "✅ Phase 5 gate PASS"
