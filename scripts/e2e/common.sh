#!/usr/bin/env bash
# Shared helpers for VoiceInputMimo phase E2E gate scripts.
# Source this from each phase script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RAPID_MLX_URL="${RAPID_MLX_URL:-http://127.0.0.1:8082/v1}"

c_red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
c_blue()   { printf '\033[0;34m%s\033[0m\n' "$*"; }

step() { c_blue ">>> $*"; }
ok()   { c_green "✅ $*"; }
fail() { c_red "❌ $*"; exit 1; }
warn() { c_yellow "⚠️  $*"; }

ensure_rapid_mlx_up() {
    step "Checking Rapid-MLX endpoint at ${RAPID_MLX_URL}"
    if ! curl -sf -o /dev/null --max-time 3 "${RAPID_MLX_URL%/v1}/v1/models"; then
        fail "Rapid-MLX not reachable. Start it before running E2E."
    fi
    ok "Rapid-MLX reachable"
}

run_swift_tests() {
    step "Running swift test"
    cd "$REPO_ROOT"
    if ! swift test 2>&1 | tail -20; then
        fail "swift test failed"
    fi
    ok "swift test green"
}
