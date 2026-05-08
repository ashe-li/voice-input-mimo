"""Phase 2 bench — high-frequency use case (~3.5 min between calls).

Simulates: user does voice-input every 3-4 minutes for 30 minutes
            → 8 transcribe calls.

Expected behavior (per Phase 2 design with ladder 3/7/15 min):
    - L1 → L2 escalates after 2nd call
    - L2 → L3 escalates after 3rd call
    - From L3 onward each call resets within window → stays L3
    - asr_evictions_done = 0 (never expires)
    - cold_tax_total_ms = 0 (no reload)
    - phys_mb stays around peak transcribe value (~6450 MB)

Run from repo root:
    PYTHONPATH=. /Users/shiun/Documents/voice-input-mimo/server/.venv/bin/python \\
        scripts/bench_phase2_high_freq.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

from scripts._baseline_meta import git_meta, host_meta
from scripts._phase2_runner import (
    admin_memory,
    emit_baseline,
    list_fixtures,
    percentile,
    post_transcribe,
    snapshot,
)

CALLS = 8
INTERVAL_S = 210.0
SAMPLE_INTERVAL_S = 30.0
SCENARIO = "high_freq"


def main() -> int:
    fixtures = list_fixtures()
    am = admin_memory()
    if am is None:
        print("[bench] engine unreachable at 127.0.0.1:8766", file=sys.stderr)
        return 2
    print(f"[bench] start scenario={SCENARIO} calls={CALLS} interval={INTERVAL_S}s")

    samples: list[dict] = []
    calls: list[dict] = []
    cold_tax_total_ms = 0
    t_start = time.time()

    for i in range(CALLS):
        wav = fixtures[i % len(fixtures)]
        request_id = f"bench-hf-{i}-{int(time.time()*1000)}"
        was_loaded = (admin_memory() or {}).get("asr", {}).get("loaded")
        resp, elapsed = post_transcribe(wav, request_id=request_id)
        was_cold = not bool(was_loaded)
        if was_cold:
            cold_tax_total_ms += int(elapsed * 1000)
        calls.append({
            "i": i,
            "request_id": request_id,
            "wav": wav.name,
            "elapsed_ms": int(elapsed * 1000),
            "was_cold": was_cold,
            "ok": resp is not None,
        })
        samples.append(snapshot())
        print(f"[bench] call {i+1}/{CALLS} elapsed={elapsed:.2f}s cold={was_cold}")

        if i + 1 < CALLS:
            t_target = (i + 1) * INTERVAL_S
            while time.time() - t_start < t_target:
                samples.append(snapshot())
                remain = t_target - (time.time() - t_start)
                time.sleep(min(SAMPLE_INTERVAL_S, max(1.0, remain)))

    samples.append(snapshot())
    duration_s = int(time.time() - t_start)

    asr_evictions_done = sum(1 for c in calls if c["was_cold"] and c["i"] > 0)
    phys_values = [s["phys_mb"] for s in samples if s.get("phys_mb") is not None]
    levels = [s["asr_level"] for s in samples if s.get("asr_level") is not None]

    payload = {
        "scenario": SCENARIO,
        "git": git_meta("."),
        "host": host_meta(),
        "config": {
            "calls": CALLS,
            "interval_s": INTERVAL_S,
            "sample_interval_s": SAMPLE_INTERVAL_S,
        },
        "result": {
            "duration_s": duration_s,
            "asr_evictions_done": asr_evictions_done,
            "cold_tax_total_ms": cold_tax_total_ms,
            "asr_max_level_reached": max(levels) if levels else None,
            "phys_mb_p50": percentile(phys_values, 0.50),
            "phys_mb_p95": percentile(phys_values, 0.95),
            "phys_mb_min": min(phys_values) if phys_values else None,
            "phys_mb_max": max(phys_values) if phys_values else None,
        },
        "calls": calls,
        "samples": samples,
        "verdict": {
            "expected_evictions_done": 0,
            "expected_cold_tax_total_ms_lt": 1000,
            "expected_max_level": 3,
        },
    }
    emit_baseline(SCENARIO, payload)
    print(f"[bench] done. evictions={asr_evictions_done} cold_tax={cold_tax_total_ms}ms "
          f"max_level={payload['result']['asr_max_level_reached']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
