#!/bin/bash
# Phase 4 E2E gate (Phase 4A + 4B — Prompts pane: profiles + skills library + import/export)
#
# Asserts:
#   1. swift build warning-free
#   2. swift test all 133+ pass (Phase 3 105 + 4A 14 + 4B 14)
#   3. PromptsPaneViewModel is @MainActor @Observable with required state
#      including the 4B paneMode + skill-mode fields
#   4. PromptStoreViewModel exposes Phase 4 mutation API plus 4B export/import
#   5. ProfileSidebar / ProfileEditor / PromptTestPanel exist with #Preview
#      and SkillSidebar / SkillEditor exist with #Preview
#   6. PromptsPane uses HSplitView with profile + skill children, segmented
#      mode picker, and Import/Export buttons (no placeholder text)
#   7. PromptIO bundle codec + PromptImportPlanner exist; AppKit adapter is
#      isolated to the Settings module

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"

c_green "[phase4] 1/7 swift build (warning sweep)…"
BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build > "$BUILD_LOG" 2>&1; then
    c_red "swift build failed:"; cat "$BUILD_LOG"; exit 1
fi
if grep -E "warning:" "$BUILD_LOG" > /dev/null; then
    c_red "swift build emitted warnings:"; grep -E "warning:" "$BUILD_LOG"; exit 1
fi

c_green "[phase4] 2/7 swift test…"
run_swift_tests

c_green "[phase4] 3/7 PromptsPaneViewModel = @MainActor @Observable…"
PANE_VM="Sources/VoiceInputMimo/Settings/Prompts/PromptsPaneViewModel.swift"
if ! grep -E "^@MainActor" "$PANE_VM" > /dev/null; then
    c_red "PromptsPaneViewModel must be @MainActor"; exit 1
fi
if ! grep -E "^@Observable" "$PANE_VM" > /dev/null; then
    c_red "PromptsPaneViewModel must use @Observable macro"; exit 1
fi
for prop in "selectedMode" "selectedProfileID" "draft" "testInput" "testHistory" "isRunning" "paneMode" "selectedSkillID" "skillDraft"; do
    if ! grep -E "var ${prop}" "$PANE_VM" > /dev/null; then
        c_red "PromptsPaneViewModel missing var: ${prop}"; exit 1
    fi
done

c_green "[phase4] 4/7 PromptStoreViewModel mutation + import/export API…"
STORE_VM="Sources/VoiceInputMimo/Prompts/PromptStoreViewModel.swift"
for fn in "saveProfile" "deleteProfile" "saveSkill" "deleteSkill" "setActiveProfile" "exportSnapshot" "applyImport"; do
    if ! grep -E "func ${fn}" "$STORE_VM" > /dev/null; then
        c_red "PromptStoreViewModel missing method: ${fn}"; exit 1
    fi
done

c_green "[phase4] 5/7 Prompts views exist with #Preview…"
for view in ProfileSidebar ProfileEditor PromptTestPanel SkillSidebar SkillEditor; do
    f="Sources/VoiceInputMimo/Settings/Prompts/${view}.swift"
    if [[ ! -f "$f" ]]; then
        c_red "Missing view: $f"; exit 1
    fi
    if ! grep -E "^#Preview" "$f" > /dev/null; then
        c_red "${view} missing #Preview block"; exit 1
    fi
done

c_green "[phase4] 6/7 PromptsPane uses HSplitView + mode picker + IO buttons…"
PROMPTS_PANE="Sources/VoiceInputMimo/Settings/Panes/PromptsPane.swift"
if ! grep -E "HSplitView" "$PROMPTS_PANE" > /dev/null; then
    c_red "PromptsPane must use HSplitView"; exit 1
fi
for child in "ProfileSidebar()" "ProfileEditor()" "PromptTestPanel()" "SkillSidebar()" "SkillEditor()"; do
    if ! grep -F "$child" "$PROMPTS_PANE" > /dev/null; then
        c_red "PromptsPane must instantiate ${child}"; exit 1
    fi
done
for token in "PromptsPaneMode" "Import…" "Export…"; do
    if ! grep -F "$token" "$PROMPTS_PANE" > /dev/null; then
        c_red "PromptsPane must reference ${token}"; exit 1
    fi
done
if grep -vE "^[[:space:]]*///" "$PROMPTS_PANE" | grep -E "Coming in Phase|TODO: placeholder" > /dev/null; then
    c_red "PromptsPane still contains placeholder copy"; exit 1
fi

c_green "[phase4] 7/7 PromptIO codec + adapter…"
PROMPT_IO="Sources/VoiceInputMimo/Prompts/PromptIO.swift"
if [[ ! -f "$PROMPT_IO" ]]; then
    c_red "Missing PromptIO.swift"; exit 1
fi
for sym in "struct PromptBundle" "enum PromptIO" "enum PromptImportPlanner" "PromptImportStrategy"; do
    if ! grep -F "$sym" "$PROMPT_IO" > /dev/null; then
        c_red "PromptIO.swift missing symbol: $sym"; exit 1
    fi
done
ADAPTER="Sources/VoiceInputMimo/Settings/Prompts/PromptImportExportAdapter.swift"
if [[ ! -f "$ADAPTER" ]]; then
    c_red "Missing PromptImportExportAdapter.swift"; exit 1
fi
if ! grep -E "^@MainActor" "$ADAPTER" > /dev/null; then
    c_red "PromptImportExportAdapter must be @MainActor"; exit 1
fi
# AppKit adapter must not leak into the Prompts data layer
if grep -l "import AppKit" Sources/VoiceInputMimo/Prompts/*.swift > /dev/null 2>&1; then
    c_red "AppKit must not be imported in Prompts data layer"; exit 1
fi

c_green "✅ Phase 4 gate PASS (4A + 4B)"
