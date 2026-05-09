#!/usr/bin/env bash
# Phase 1 (logic foundation) E2E acceptance gate.
#
# What "E2E" means for Phase 1: the data layer wires up to a real LLM endpoint
# (Rapid-MLX) and produces output that meets the v1 baseline. AppDelegate is
# not yet wired (that's Phase 6), so this gate exercises:
#   1. swift test — all 91 unit tests must pass
#   2. bench_refine_prompt_ab.py --gate — v1-store hit count >= v1 baseline
#
# The bench script renders the builtin Default Refine profile through
# PromptComposer (the same code path that LLMRefiner.resolveSystemPrompt uses
# at runtime), so this is an end-to-end check of the rendering pipeline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"

step "Phase 1 E2E acceptance gate"

ensure_rapid_mlx_up
run_swift_tests

step "Running 3-way backtest (v0 / v1 / v1-store) with --gate"
mkdir -p harness
REPORT="harness/e2e-phase1-$(date +%Y%m%d-%H%M%S).md"
if ! python3 scripts/bench_refine_prompt_ab.py \
        --base-url "$RAPID_MLX_URL" \
        --gate \
        --out-md "$REPORT"; then
    fail "Phase 1 gate failed — see report: $REPORT"
fi

ok "Phase 1 E2E gate PASS"
echo ""
c_blue "Report: $REPORT"
