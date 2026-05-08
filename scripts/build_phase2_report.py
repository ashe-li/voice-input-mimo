#!/usr/bin/env python3
"""Build Phase 2 vs Phase 1 comparison report.

Reads:
- harness/baselines/engine-phase1-baseline.json
- harness/baselines/phase2-{high_freq,sparse,hard_ceiling,qwen_cache}-*.json (latest per scenario)

Emits:
- harness/baselines/phase2-vs-phase1.md (markdown comparison + verdicts)
- stdout summary (PASS/FAIL counts + headline numbers)

Usage:
    python3 scripts/build_phase2_report.py
"""

from __future__ import annotations

import glob
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent
BASELINE_DIR = ROOT / "harness" / "baselines"
PHASE1_FILE = BASELINE_DIR / "engine-phase1-baseline.json"
OUT_FILE = BASELINE_DIR / "phase2-vs-phase1.md"

SCENARIOS = ("high_freq", "sparse", "hard_ceiling", "qwen_cache")


def latest_snapshot(scenario: str) -> Optional[Path]:
    pattern = str(BASELINE_DIR / f"phase2-{scenario}-*.json")
    matches = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    return Path(matches[0]) if matches else None


def load_json(p: Path) -> Optional[Dict[str, Any]]:
    try:
        with p.open() as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"[warn] failed to read {p}: {e}", file=sys.stderr)
        return None


def evaluate(scenario: str, payload: Dict[str, Any]) -> Tuple[bool, List[str]]:
    """Return (pass, list_of_fail_reasons)."""
    result = payload.get("result", {})
    verdict = payload.get("verdict", {})
    reasons: List[str] = []

    if scenario == "high_freq":
        ev_exp = verdict.get("expected_evictions_done", 0)
        ev_got = result.get("asr_evictions_done")
        if ev_got != ev_exp:
            reasons.append(f"asr_evictions_done={ev_got} expected={ev_exp}")

        cold_lt = verdict.get("expected_cold_tax_total_ms_lt", 1000)
        cold_got = result.get("cold_tax_total_ms")
        if cold_got is None or cold_got >= cold_lt:
            reasons.append(f"cold_tax_total_ms={cold_got} expected<{cold_lt}")

        lvl_exp = verdict.get("expected_max_level", 3)
        lvl_got = result.get("asr_max_level_reached")
        if lvl_got != lvl_exp:
            reasons.append(f"asr_max_level_reached={lvl_got} expected={lvl_exp}")

    elif scenario == "sparse":
        ev_gte = verdict.get("expected_evictions_done_gte", 3)
        ev_got = result.get("asr_evictions_done")
        if ev_got is None or ev_got < ev_gte:
            reasons.append(f"asr_evictions_done={ev_got} expected>={ev_gte}")

        idle_lt = verdict.get("expected_phys_mb_idle_avg_lt", 500)
        idle_got = result.get("phys_mb_idle_avg")
        if idle_got is None or idle_got >= idle_lt:
            reasons.append(f"phys_mb_idle_avg={idle_got} expected<{idle_lt}")

    elif scenario == "hard_ceiling":
        cap = verdict.get("expected_evict_within_idle_s", 1800)
        at = result.get("evict_observed_at_idle_s")
        if at is None:
            reasons.append(f"evict_observed_at_idle_s=null (no evict observed in window)")
        elif at > cap:
            reasons.append(f"evict_observed_at_idle_s={at} exceeded cap={cap}")

    elif scenario == "qwen_cache":
        observed_exp = verdict.get("expected_cache_clear_observed", True)
        observed_got = result.get("cache_clear_observed")
        if observed_got != observed_exp:
            reasons.append(f"cache_clear_observed={observed_got} expected={observed_exp}")

        final_lt = verdict.get("expected_cache_final_mb_lt", 100)
        final_got = result.get("cache_final_mb")
        if final_got is None or final_got >= final_lt:
            reasons.append(f"cache_final_mb={final_got} expected<{final_lt}")

    else:
        reasons.append(f"unknown scenario: {scenario}")

    return (len(reasons) == 0, reasons)


def fmt_mb(v: Any) -> str:
    if v is None:
        return "n/a"
    try:
        return f"{float(v):.0f} MB"
    except (TypeError, ValueError):
        return str(v)


def fmt_ms(v: Any) -> str:
    if v is None:
        return "n/a"
    try:
        return f"{float(v):.0f} ms"
    except (TypeError, ValueError):
        return str(v)


def section_high_freq(payload: Dict[str, Any]) -> str:
    r = payload.get("result", {})
    v = payload.get("verdict", {})
    cfg = payload.get("config", {})
    rows = [
        f"| 設定 | calls={cfg.get('calls')}, interval={cfg.get('interval_s')}s |",
        f"| Duration | {r.get('duration_s')}s |",
        f"| asr_evictions_done | **{r.get('asr_evictions_done')}** (expected={v.get('expected_evictions_done', 0)}) |",
        f"| cold_tax_total_ms | **{fmt_ms(r.get('cold_tax_total_ms'))}** (expected<{v.get('expected_cold_tax_total_ms_lt', 1000)}) |",
        f"| asr_max_level_reached | **{r.get('asr_max_level_reached')}** (expected={v.get('expected_max_level', 3)}) |",
        f"| phys_mb p50 / p95 | {fmt_mb(r.get('phys_mb_p50'))} / {fmt_mb(r.get('phys_mb_p95'))} |",
    ]
    return "\n".join(rows)


def section_sparse(payload: Dict[str, Any]) -> str:
    r = payload.get("result", {})
    v = payload.get("verdict", {})
    cfg = payload.get("config", {})
    rows = [
        f"| 設定 | calls={cfg.get('calls')}, interval={cfg.get('interval_s')}s |",
        f"| Duration | {r.get('duration_s')}s |",
        f"| asr_evictions_done | **{r.get('asr_evictions_done')}** (expected>={v.get('expected_evictions_done_gte', 3)}) |",
        f"| cold_tax_total_ms | {fmt_ms(r.get('cold_tax_total_ms'))} |",
        f"| phys_mb_idle_avg | **{fmt_mb(r.get('phys_mb_idle_avg'))}** (expected<{v.get('expected_phys_mb_idle_avg_lt', 500)}) |",
        f"| phys_mb p50 | {fmt_mb(r.get('phys_mb_p50'))} |",
    ]
    return "\n".join(rows)


def section_hard_ceiling(payload: Dict[str, Any]) -> str:
    r = payload.get("result", {})
    v = payload.get("verdict", {})
    cfg = payload.get("config", {})
    rows = [
        f"| 設定 | warmup={cfg.get('warmup_calls')} calls × {cfg.get('warmup_interval_s')}s, idle={cfg.get('idle_duration_s')}s |",
        f"| evict_observed_at_idle_s | **{r.get('evict_observed_at_idle_s')}s** (expected within {v.get('expected_evict_within_idle_s', 1800)}s) |",
        f"| asr_loaded_final | {r.get('asr_loaded_final')} |",
        f"| phys_mb_final | {fmt_mb(r.get('phys_mb_final'))} |",
    ]
    return "\n".join(rows)


def section_qwen_cache(payload: Dict[str, Any]) -> str:
    r = payload.get("result", {})
    v = payload.get("verdict", {})
    cfg = payload.get("config", {})
    rows = [
        f"| 設定 | chats={cfg.get('chat_calls')} × {cfg.get('chat_interval_s')}s, idle={cfg.get('idle_duration_s')}s |",
        f"| Cache MB initial → after chats → final | {fmt_mb(r.get('initial_cache_mb'))} → {fmt_mb(r.get('cache_after_chats_mb'))} → **{fmt_mb(r.get('cache_final_mb'))}** |",
        f"| cache_clear_observed | **{r.get('cache_clear_observed')}** (expected={v.get('expected_cache_clear_observed', True)}) |",
        f"| cache_clear_at_idle_s | {r.get('cache_clear_at_idle_s')}s |",
    ]
    return "\n".join(rows)


SECTION_FN = {
    "high_freq": section_high_freq,
    "sparse": section_sparse,
    "hard_ceiling": section_hard_ceiling,
    "qwen_cache": section_qwen_cache,
}

SCENARIO_TITLE = {
    "high_freq": "Scenario 1 — High-frequency (8 calls / 30 min, 210s interval)",
    "sparse": "Scenario 2 — Sparse (4 calls / 30 min, 450s interval)",
    "hard_ceiling": "Scenario 3 — Hard ceiling (warmup → 1900s idle)",
    "qwen_cache": "Scenario 4 — Qwen cache idle (5 chats → 360s idle)",
}


def build_phase1_summary(p1: Dict[str, Any]) -> str:
    s = p1.get("summary", {})
    mem = s.get("memory", {})
    lat = s.get("latency", {})
    wer = s.get("wer", {})
    rows = [
        "## Phase 1 baseline (reference)",
        "",
        "| Metric | Value |",
        "|---|---|",
        f"| cold_phys_mb | {fmt_mb(mem.get('cold_phys_mb'))} |",
        f"| peak_phys_mb | {fmt_mb(mem.get('peak_phys_mb'))} |",
        f"| post_idle_phys_mb (after fixed 15s idle) | {fmt_mb(mem.get('post_idle_phys_mb'))} |",
        f"| idle_drop_phys_mb | {fmt_mb(mem.get('idle_drop_phys_mb'))} |",
        f"| cold_ms | {fmt_ms(lat.get('cold_ms'))} |",
        f"| warm_ms | {fmt_ms(lat.get('warm_ms'))} |",
        f"| steady_median_ms | {fmt_ms(lat.get('steady_median_ms'))} |",
        f"| WER | {wer.get('avg_wer', 'n/a')} |",
        "",
        "Note: Phase 1 used **fixed `idle=15s`** — every burst paid `cold_ms` ~3000 ms after each gap > 15s.",
    ]
    return "\n".join(rows)


def main() -> int:
    if not BASELINE_DIR.exists():
        print(f"[err] {BASELINE_DIR} not found", file=sys.stderr)
        return 1

    p1 = load_json(PHASE1_FILE)
    if p1 is None:
        print(f"[err] Phase 1 baseline missing: {PHASE1_FILE}", file=sys.stderr)
        return 1

    found: Dict[str, Tuple[Path, Dict[str, Any], bool, List[str]]] = {}
    for scen in SCENARIOS:
        path = latest_snapshot(scen)
        if path is None:
            print(f"[warn] no snapshot for scenario={scen}", file=sys.stderr)
            continue
        payload = load_json(path)
        if payload is None:
            continue
        passed, reasons = evaluate(scen, payload)
        found[scen] = (path, payload, passed, reasons)

    if not found:
        print("[err] no Phase 2 snapshots found", file=sys.stderr)
        return 1

    lines: List[str] = [
        "# Phase 2 vs Phase 1 — Adaptive Idle Ladder + Qwen Remote Cache Manager",
        "",
        f"Generated: {os.popen('date -Iseconds').read().strip()}",
        "",
        "## Summary verdict",
        "",
        "| Scenario | Verdict | Detail |",
        "|---|---|---|",
    ]
    pass_count = 0
    for scen in SCENARIOS:
        if scen not in found:
            lines.append(f"| {scen} | MISSING | snapshot not found |")
            continue
        _, _, passed, reasons = found[scen]
        if passed:
            pass_count += 1
            lines.append(f"| {scen} | PASS | all expected verdicts met |")
        else:
            lines.append(f"| {scen} | FAIL | {'; '.join(reasons)} |")

    total = len(found)
    lines.append("")
    lines.append(f"**Result: {pass_count} / {total} scenarios passed.**")
    lines.append("")

    lines.append(build_phase1_summary(p1))
    lines.append("")

    lines.append("## Phase 2 results (per scenario)")
    lines.append("")
    for scen in SCENARIOS:
        if scen not in found:
            lines.append(f"### {SCENARIO_TITLE[scen]}")
            lines.append("")
            lines.append("_Snapshot missing._")
            lines.append("")
            continue
        path, payload, passed, reasons = found[scen]
        lines.append(f"### {SCENARIO_TITLE[scen]}")
        lines.append("")
        lines.append(f"- Snapshot: `{path.name}`")
        lines.append(f"- Git: `{payload.get('git', {}).get('git_sha', 'n/a')[:8]}` @ {payload.get('git', {}).get('captured_at', 'n/a')}")
        lines.append(f"- Verdict: **{'PASS' if passed else 'FAIL'}**" + (f" — {'; '.join(reasons)}" if reasons else ""))
        lines.append("")
        lines.append("| Field | Value |")
        lines.append("|---|---|")
        lines.append(SECTION_FN[scen](payload))
        lines.append("")

    lines.append("## Headline numbers (Phase 1 → Phase 2 high_freq)")
    lines.append("")
    if "high_freq" in found:
        _, hf, _, _ = found["high_freq"]
        hf_r = hf.get("result", {})
        p1_mem = p1.get("summary", {}).get("memory", {})
        p1_lat = p1.get("summary", {}).get("latency", {})
        lines.extend([
            "| Metric | Phase 1 (fixed 15s) | Phase 2 (adaptive 3/7/15 min) |",
            "|---|---|---|",
            f"| Burst cold_tax | every gap >15s pays cold_ms ≈ {fmt_ms(p1_lat.get('cold_ms'))} | **{fmt_ms(hf_r.get('cold_tax_total_ms'))}** total over 8 calls |",
            f"| Idle phys_mb | drops to {fmt_mb(p1_mem.get('post_idle_phys_mb'))} after each idle | stays warm at {fmt_mb(hf_r.get('phys_mb_p50'))} (level 3) |",
            f"| Evictions during use | N (one per gap >15s) | **{hf_r.get('asr_evictions_done')}** during burst |",
        ])
        lines.append("")

    OUT_FILE.write_text("\n".join(lines) + "\n")
    print(f"[ok] wrote {OUT_FILE}")
    print(f"[summary] {pass_count}/{total} scenarios passed.")
    for scen in SCENARIOS:
        if scen not in found:
            print(f"  {scen}: MISSING")
        else:
            _, _, passed, reasons = found[scen]
            mark = "PASS" if passed else "FAIL"
            print(f"  {scen}: {mark}" + (f" ({'; '.join(reasons)})" if reasons else ""))
    missing = [s for s in SCENARIOS if s not in found]
    if missing:
        return 3
    return 0 if pass_count == total else 2


if __name__ == "__main__":
    raise SystemExit(main())
