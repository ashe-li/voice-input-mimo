#!/bin/bash
# Phase 6 E2E gate — startup wiring + status menu profile switcher + overlay label
#
# Asserts:
#   1. swift build warning-free
#   2. swift test all 143+ pass
#   3. AppDelegate calls PromptMigration.bootstrapIfNeeded() at launch and
#      reloads PromptStoreViewModel.shared
#   4. AppDelegate has activeProfileMenuItem + refreshActiveProfileMenu wiring
#      and selectProfileFromMenu(_:) routes through PromptStoreViewModel
#   5. OverlayPanel.Phase.refining carries profileLabel; AppDelegate passes
#      it on the .refining transition
#   6. Phase 1-5 gates still pass (full chain)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"

c_green "[phase6] 1/6 swift build (warning sweep)…"
BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build > "$BUILD_LOG" 2>&1; then
    c_red "swift build failed:"; cat "$BUILD_LOG"; exit 1
fi
if grep -E "warning:" "$BUILD_LOG" > /dev/null; then
    c_red "swift build emitted warnings:"; grep -E "warning:" "$BUILD_LOG"; exit 1
fi

c_green "[phase6] 2/6 swift test…"
run_swift_tests

c_green "[phase6] 3/6 AppDelegate startup wiring…"
APP_DEL="Sources/VoiceInputMimo/AppDelegate.swift"
for token in "bootstrapPromptStore" "PromptMigration" "bootstrapIfNeeded" "PromptStoreViewModel.shared"; do
    if ! grep -F "$token" "$APP_DEL" > /dev/null; then
        c_red "AppDelegate missing startup token: $token"; exit 1
    fi
done
# bootstrapPromptStore must be invoked from applicationDidFinishLaunching
if ! awk '/applicationDidFinishLaunching/,/^    }/' "$APP_DEL" | grep -F "bootstrapPromptStore" > /dev/null; then
    c_red "applicationDidFinishLaunching does not call bootstrapPromptStore"; exit 1
fi

c_green "[phase6] 4/6 Status menu profile switcher…"
for token in "activeProfileMenuItem" "refreshActiveProfileMenu" "selectProfileFromMenu" "ProfileSelection" "setActiveProfile"; do
    if ! grep -F "$token" "$APP_DEL" > /dev/null; then
        c_red "AppDelegate missing menu token: $token"; exit 1
    fi
done

c_green "[phase6] 5/6 OverlayPanel profile label…"
OVERLAY="Sources/VoiceInputMimo/OverlayPanel.swift"
if ! grep -F "profileLabel: String?" "$OVERLAY" > /dev/null; then
    c_red "OverlayPanel.Phase.refining missing profileLabel"; exit 1
fi
if ! grep -F "profileLabel:" "$APP_DEL" > /dev/null; then
    c_red "AppDelegate must pass profileLabel: on .refining"; exit 1
fi
if ! grep -F "activeProfileLabel" "$APP_DEL" > /dev/null; then
    c_red "AppDelegate missing activeProfileLabel(for:) helper"; exit 1
fi

c_green "[phase6] 6/6 Re-run earlier phase gates…"
for ph in 1 2 3 4 5; do
    if ! bash "$SCRIPT_DIR/phase${ph}_gate.sh" > /dev/null 2>&1; then
        c_red "phase${ph}_gate failed in re-run"
        bash "$SCRIPT_DIR/phase${ph}_gate.sh"
        exit 1
    fi
    c_green "  ✓ phase${ph} re-run pass"
done

c_green "✅ Phase 6 gate PASS — full chain (1→6) green"
