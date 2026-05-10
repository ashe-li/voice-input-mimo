#!/bin/bash
# Phase 2 E2E gate — SwiftUI Hybrid foundation
#
# Asserts:
#   1. swift build is warning-free (-warnings-as-errors via parsing)
#   2. swift test all 97+ tests pass (Phase 1 91 + Phase 2 ViewModel ≥6)
#   3. Sendable conformance: 4 data models + RefineMode declare Sendable
#   4. PromptStoreViewModel is @MainActor @Observable
#   5. PromptStore declares @unchecked Sendable (with documented rationale)
#   6. 5 SwiftUI shared components each ship with #Preview
#
# Phase 2 introduces no UI surface yet — Phase 3 will wire components into
# the Settings window. So this gate is purely structural + unit tests; no
# osascript driver / no end-user-visible flow yet.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"

c_green "[phase2] 1/6 swift build (warning sweep)…"
BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build > "$BUILD_LOG" 2>&1; then
    c_red "swift build failed:"
    cat "$BUILD_LOG"
    exit 1
fi
if grep -E "warning:" "$BUILD_LOG" > /dev/null; then
    c_red "swift build emitted warnings — Phase 2 gate fails on any warning:"
    grep -E "warning:" "$BUILD_LOG"
    exit 1
fi

c_green "[phase2] 2/6 swift test…"
run_swift_tests

c_green "[phase2] 3/6 Sendable conformance on data models…"
PROFILE_FILE="Sources/VoiceInputMimo/Prompts/PromptProfile.swift"
REFINER_FILE="Sources/VoiceInputMimo/LLMRefiner.swift"
for type in "SkillCategory" "PromptSkill" "PromptProfile" "ActiveSelection"; do
    if ! grep -E "(struct|enum) ${type}.*Sendable" "$PROFILE_FILE" > /dev/null; then
        c_red "Missing Sendable conformance on ${type}"
        exit 1
    fi
done
if ! grep -E "enum RefineMode.*Sendable" "$REFINER_FILE" > /dev/null; then
    c_red "Missing Sendable conformance on RefineMode"
    exit 1
fi

c_green "[phase2] 4/6 PromptStoreViewModel = @MainActor @Observable…"
VM_FILE="Sources/VoiceInputMimo/Prompts/PromptStoreViewModel.swift"
if ! grep -E "^@MainActor" "$VM_FILE" > /dev/null; then
    c_red "PromptStoreViewModel must be @MainActor"
    exit 1
fi
if ! grep -E "^@Observable" "$VM_FILE" > /dev/null; then
    c_red "PromptStoreViewModel must use @Observable macro"
    exit 1
fi

c_green "[phase2] 5/6 PromptStore declares @unchecked Sendable…"
if ! grep -E "PromptStoreProviding, @unchecked Sendable" Sources/VoiceInputMimo/Prompts/PromptStore.swift > /dev/null; then
    c_red "PromptStore must conform to PromptStoreProviding + @unchecked Sendable"
    exit 1
fi

c_green "[phase2] 6/6 5 SwiftUI components each ship #Preview…"
for component in HostingWindow SectionHeading CardModifier SidebarSection IconButton; do
    file="Sources/VoiceInputMimo/UI/Components/${component}.swift"
    if [[ ! -f "$file" ]]; then
        c_red "Missing component: $file"
        exit 1
    fi
    if ! grep -E "^#Preview" "$file" > /dev/null; then
        c_red "${component} missing #Preview block"
        exit 1
    fi
done

c_green "✅ Phase 2 gate PASS"
