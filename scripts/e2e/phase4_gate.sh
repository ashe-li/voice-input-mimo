#!/bin/bash
# Phase 4 E2E gate (Phase 4A — Prompts pane: profile editing UI)
#
# Asserts:
#   1. swift build warning-free
#   2. swift test all 119+ pass (Phase 3 105 + Phase 4A ≥14)
#   3. PromptsPaneViewModel is @MainActor @Observable with required state
#   4. PromptStoreViewModel exposes Phase 4 mutation API
#      (saveProfile / deleteProfile / saveSkill / deleteSkill / setActiveProfile)
#   5. ProfileSidebar / ProfileEditor / PromptTestPanel exist with #Preview
#   6. PromptsPane uses HSplitView with the 3 child views (no placeholder text)
#
# Phase 4B follow-up (deferred): SkillsLibraryView, Import/Export adapter.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"

c_green "[phase4] 1/6 swift build (warning sweep)…"
BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build > "$BUILD_LOG" 2>&1; then
    c_red "swift build failed:"; cat "$BUILD_LOG"; exit 1
fi
if grep -E "warning:" "$BUILD_LOG" > /dev/null; then
    c_red "swift build emitted warnings:"; grep -E "warning:" "$BUILD_LOG"; exit 1
fi

c_green "[phase4] 2/6 swift test…"
run_swift_tests

c_green "[phase4] 3/6 PromptsPaneViewModel = @MainActor @Observable…"
PANE_VM="Sources/VoiceInputMimo/Settings/Prompts/PromptsPaneViewModel.swift"
if ! grep -E "^@MainActor" "$PANE_VM" > /dev/null; then
    c_red "PromptsPaneViewModel must be @MainActor"; exit 1
fi
if ! grep -E "^@Observable" "$PANE_VM" > /dev/null; then
    c_red "PromptsPaneViewModel must use @Observable macro"; exit 1
fi
for prop in "selectedMode" "selectedProfileID" "draft" "testInput" "testHistory" "isRunning"; do
    if ! grep -E "var ${prop}" "$PANE_VM" > /dev/null; then
        c_red "PromptsPaneViewModel missing var: ${prop}"; exit 1
    fi
done

c_green "[phase4] 4/6 PromptStoreViewModel mutation API…"
STORE_VM="Sources/VoiceInputMimo/Prompts/PromptStoreViewModel.swift"
for fn in "saveProfile" "deleteProfile" "saveSkill" "deleteSkill" "setActiveProfile"; do
    if ! grep -E "func ${fn}" "$STORE_VM" > /dev/null; then
        c_red "PromptStoreViewModel missing mutation: ${fn}"; exit 1
    fi
done

c_green "[phase4] 5/6 3-column views exist with #Preview…"
for view in ProfileSidebar ProfileEditor PromptTestPanel; do
    f="Sources/VoiceInputMimo/Settings/Prompts/${view}.swift"
    if [[ ! -f "$f" ]]; then
        c_red "Missing view: $f"; exit 1
    fi
    if ! grep -E "^#Preview" "$f" > /dev/null; then
        c_red "${view} missing #Preview block"; exit 1
    fi
done

c_green "[phase4] 6/6 PromptsPane uses HSplitView + 3 children…"
PROMPTS_PANE="Sources/VoiceInputMimo/Settings/Panes/PromptsPane.swift"
if ! grep -E "HSplitView" "$PROMPTS_PANE" > /dev/null; then
    c_red "PromptsPane must use HSplitView"; exit 1
fi
for child in "ProfileSidebar()" "ProfileEditor()" "PromptTestPanel()"; do
    if ! grep -F "$child" "$PROMPTS_PANE" > /dev/null; then
        c_red "PromptsPane must instantiate ${child}"; exit 1
    fi
done
if grep -E "Coming in Phase|placeholder" "$PROMPTS_PANE" > /dev/null; then
    c_red "PromptsPane still contains placeholder copy"; exit 1
fi

c_green "✅ Phase 4A gate PASS"
