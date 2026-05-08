"""Phase 2 bench — hard ceiling force-evict.

Simulates: 1 call to escalate to L1, then idle 35 min (> hard ceiling 30 min).
            Verifies that hard ceiling kicks in even if last_use is recent
            relative to current level window. (For testing the override path,
            not for L3 expiration which would also evict at 15 min.)

Note: with default ladder L1=180s, ceiling=1800s — at L1 the natural window
expires first (180s) so ceiling override is hard to observe. To exercise the
ceiling path, escalate to L3 first (3 quick calls within 3 min) so L3 window
is 900s but ceiling 1800s — between 900 and 1800s, ceiling becomes the binding
constraint. This bench takes that approach.

Expected behavior:
    - 3 quick calls escalate to L3
    - Idle 1900s (~32 min)
    - At ~900s: evict (L3 window expired). bench should observe phys_mb drop.
    - At ~1900s: definitely evicted.

For pure ceiling testing, set ENGINE_IDLE_LADDER_SECONDS=600,1200,3600 so
ladder top > ceiling default — but ceiling validation forbids this in
AdaptiveIdleWindow.__init__. So in practice, ceiling only matters when L3
short. For default config this bench overlaps with L3 expiration test.

Run from repo root:
    PYTHONPATH=. /Users/shiun/Documents/voice-input-mimo/server/.venv/bin/python \\
        scripts/bench_phase2_hard_ceiling.py
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
    post_transcribe,
    snapshot,
)

WARMUP_CALLS = 3
WARMUP_INTERVAL_S = 60.0
IDLE_DURATION_S = 1900.0
SAMPLE_INTERVAL_S = 60.0
SCENARIO = "hard_ceiling"


def main() -> int:
    fixtures = list_fixtures()
    am = admin_memory()
    if am is None:
        print("[bench] engine unreachable", file=sys.stderr)
        return 2
    print(f"[bench] warmup {WARMUP_CALLS} calls then idle {IDLE_DURATION_S}s")

    samples: list[dict] = []
    calls: list[dict] = []
    t_start = time.time()

    for i in range(WARMUP_CALLS):
        wav = fixtures[i % len(fixtures)]
        request_id = f"bench-hc-warmup-{i}-{int(time.time()*1000)}"
        resp, elapsed = post_transcribe(wav, request_id=request_id)
        calls.append({
            "i": i, "request_id": request_id, "wav": wav.name,
            "elapsed_ms": int(elapsed * 1000), "ok": resp is not None,
        })
        samples.append(snapshot())
        print(f"[bench] warmup {i+1}/{WARMUP_CALLS} elapsed={elapsed:.2f}s")
        if i + 1 < WARMUP_CALLS:
            time.sleep(WARMUP_INTERVAL_S)

    s = snapshot()
    samples.append(s)
    print(f"[bench] post-warmup level={s.get('asr_level')} loaded={s.get('asr_loaded')}")

    t_idle_start = time.time()
    evict_observed_at: float | None = None
    while time.time() - t_idle_start < IDLE_DURATION_S:
        s = snapshot()
        samples.append(s)
        if not s.get("asr_loaded") and evict_observed_at is None:
            evict_observed_at = time.time() - t_idle_start
            print(f"[bench] evict observed at idle+{evict_observed_at:.0f}s")
        time.sleep(SAMPLE_INTERVAL_S)

    samples.append(snapshot())
    duration_s = int(time.time() - t_start)

    payload = {
        "scenario": SCENARIO,
        "git": git_meta("."),
        "host": host_meta(),
        "config": {
            "warmup_calls": WARMUP_CALLS,
            "warmup_interval_s": WARMUP_INTERVAL_S,
            "idle_duration_s": IDLE_DURATION_S,
        },
        "result": {
            "duration_s": duration_s,
            "evict_observed_at_idle_s": evict_observed_at,
            "asr_loaded_final": samples[-1].get("asr_loaded"),
            "phys_mb_final": samples[-1].get("phys_mb"),
        },
        "calls": calls,
        "samples": samples,
        "verdict": {
            "expected_evict_within_idle_s": 1800,
        },
    }
    emit_baseline(SCENARIO, payload)
    print(f"[bench] done. evict_at={evict_observed_at}s loaded_final={samples[-1].get('asr_loaded')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
