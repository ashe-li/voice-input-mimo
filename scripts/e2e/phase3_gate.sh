#!/bin/bash
# Phase 3 E2E gate — Settings refresh (AppKit form → SwiftUI panes)
#
# Asserts:
#   1. swift build is warning-free
#   2. swift test all 105+ tests pass (Phase 2 97 + Phase 3 SettingsViewModel ≥8)
#   3. SettingsViewModel is @MainActor @Observable with required state surface
#   4. SettingsWindow.swift is a thin shell — no NSGridView / NSTextField /
#      NSPopUpButton form code left behind, file size < 100 lines
#   5. 7 panes exist with #Preview blocks
#   6. SettingsRootView uses NavigationSplitView + 5 SidebarSections
#
# Manual smoke recipe (run separately after `make install`, requires
# accessibility permission for VoiceInputMimo):
#   open -a VoiceInputMimo
#   osascript -e 'tell application "System Events" to keystroke "," using {command down}'
#   # Click each sidebar entry, edit a field, close, re-open, verify
#   defaults read com.shiun.VoiceInputMimo llmAPIBaseURL
#
# CI version stays structural so the gate is fast + dependency-light.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"

c_green "[phase3] 1/6 swift build (warning sweep)…"
BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build > "$BUILD_LOG" 2>&1; then
    c_red "swift build failed:"
    cat "$BUILD_LOG"
    exit 1
fi
if grep -E "warning:" "$BUILD_LOG" > /dev/null; then
    c_red "swift build emitted warnings:"
    grep -E "warning:" "$BUILD_LOG"
    exit 1
fi

c_green "[phase3] 2/6 swift test…"
run_swift_tests

c_green "[phase3] 3/6 SettingsViewModel @MainActor @Observable surface…"
VM_FILE="Sources/VoiceInputMimo/Settings/SettingsViewModel.swift"
if ! grep -E "^@MainActor" "$VM_FILE" > /dev/null; then
    c_red "SettingsViewModel must be @MainActor"; exit 1
fi
if ! grep -E "^@Observable" "$VM_FILE" > /dev/null; then
    c_red "SettingsViewModel must use @Observable macro"; exit 1
fi
for prop in "selectedPane" "primaryShortcut" "asrBaseURL" "serverDir" "llmEnabled" "llmSuffix"; do
    if ! grep -E "var ${prop}" "$VM_FILE" > /dev/null; then
        c_red "SettingsViewModel missing var: ${prop}"; exit 1
    fi
done

c_green "[phase3] 4/6 SettingsWindow is thin shell…"
WIN_FILE="Sources/VoiceInputMimo/SettingsWindow.swift"
LINES=$(wc -l < "$WIN_FILE")
if [[ "$LINES" -gt 100 ]]; then
    c_red "SettingsWindow.swift is ${LINES} lines — should be < 100 (thin shell)"
    exit 1
fi
for forbidden in "NSGridView" "NSTextField" "NSPopUpButton" "NSButton.*checkbox"; do
    if grep -E "${forbidden}" "$WIN_FILE" > /dev/null; then
        c_red "SettingsWindow.swift still contains AppKit form code: ${forbidden}"
        exit 1
    fi
done
if ! grep -E "NSHostingController" "$WIN_FILE" > /dev/null; then
    c_red "SettingsWindow.swift must host SwiftUI via NSHostingController"
    exit 1
fi

c_green "[phase3] 5/6 7 panes exist with #Preview…"
for pane in GeneralPane ShortcutsPane SpeechPane ASRServerPane PromptsPane HistoryPane AboutPane; do
    f="Sources/VoiceInputMimo/Settings/Panes/${pane}.swift"
    if [[ ! -f "$f" ]]; then
        c_red "Missing pane: $f"; exit 1
    fi
    if ! grep -E "^#Preview" "$f" > /dev/null; then
        c_red "${pane} missing #Preview block"; exit 1
    fi
done

c_green "[phase3] 6/6 SettingsRootView uses NavigationSplitView + SidebarSections…"
ROOT_FILE="Sources/VoiceInputMimo/Settings/SettingsRootView.swift"
if ! grep -E "NavigationSplitView" "$ROOT_FILE" > /dev/null; then
    c_red "SettingsRootView must use NavigationSplitView"; exit 1
fi
SECTION_COUNT=$(grep -cE "SidebarSection" "$ROOT_FILE" || true)
if [[ "$SECTION_COUNT" -lt 4 ]]; then
    c_red "SettingsRootView should group sidebar with ≥4 SidebarSection (got ${SECTION_COUNT})"
    exit 1
fi

c_green "✅ Phase 3 gate PASS"
