"""Phase 2 bench — sparse use case (~7-8 min between calls).

Simulates: user does voice-input every 7-8 minutes for 30 minutes
            → 4 transcribe calls.

Expected behavior (per Phase 2 design with ladder 3/7/15 min):
    - L1 (180s) expires before next call → evict, reset to L1
    - Each call after first: cold_tax ~2300 ms (reload from disk)
    - phys_mb between calls drops to ~200 MB (idle)
    - asr_evictions_done >= 3

Run from repo root:
    PYTHONPATH=. /Users/shiun/Documents/voice-input-mimo/server/.venv/bin/python \\
        scripts/bench_phase2_sparse.py
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

CALLS = 4
INTERVAL_S = 450.0
SAMPLE_INTERVAL_S = 30.0
SCENARIO = "sparse"


def main() -> int:
    fixtures = list_fixtures()
    am = admin_memory()
    if am is None:
        print("[bench] engine unreachable", file=sys.stderr)
        return 2
    print(f"[bench] start scenario={SCENARIO} calls={CALLS} interval={INTERVAL_S}s")

    samples: list[dict] = []
    calls: list[dict] = []
    cold_tax_total_ms = 0
    cold_tax_count = 0
    t_start = time.time()

    for i in range(CALLS):
        wav = fixtures[i % len(fixtures)]
        request_id = f"bench-sparse-{i}-{int(time.time()*1000)}"
        was_loaded = (admin_memory() or {}).get("asr", {}).get("loaded")
        resp, elapsed = post_transcribe(wav, request_id=request_id)
        was_cold = not bool(was_loaded)
        if was_cold:
            cold_tax_total_ms += int(elapsed * 1000)
            cold_tax_count += 1
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

    phys_values = [s["phys_mb"] for s in samples if s.get("phys_mb") is not None]
    idle_phys = [s["phys_mb"] for s in samples
                 if s.get("phys_mb") is not None and not s.get("asr_loaded")]

    payload = {
        "scenario": SCENARIO,
        "git": git_meta("."),
        "host": host_meta(),
        "config": {"calls": CALLS, "interval_s": INTERVAL_S},
        "result": {
            "duration_s": duration_s,
            "asr_evictions_done": cold_tax_count,
            "cold_tax_total_ms": cold_tax_total_ms,
            "phys_mb_p50": percentile(phys_values, 0.50),
            "phys_mb_idle_avg": (sum(idle_phys) / len(idle_phys)) if idle_phys else None,
        },
        "calls": calls,
        "samples": samples,
        "verdict": {
            "expected_evictions_done_gte": 3,
            "expected_phys_mb_idle_avg_lt": 500,
        },
    }
    emit_baseline(SCENARIO, payload)
    print(f"[bench] done. evictions={cold_tax_count} cold_tax={cold_tax_total_ms}ms "
          f"idle_avg={payload['result']['phys_mb_idle_avg']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
