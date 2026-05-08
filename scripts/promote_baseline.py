"""Promote three bench run JSONs into a unified baseline snapshot.

Usage:
    python scripts/promote_baseline.py \\
        --memory  harness/runs/server-py-memory-<ts>.json \\
        --latency harness/runs/server-py-latency-<ts>.json \\
        --wer     harness/runs/server-py-wer-<ts>.json \\
        --name    server.py \\
        --out     harness/baselines/server-py-baseline.json
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


def _load(p: Path) -> dict:
    return json.loads(p.read_text())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--memory", type=Path, required=True)
    ap.add_argument("--latency", type=Path, required=True)
    ap.add_argument("--wer", type=Path, required=True)
    ap.add_argument("--name", default="server.py")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    mem = _load(args.memory)
    lat = _load(args.latency)
    wer = _load(args.wer)

    baseline = {
        "schema_version": 1,
        "engine": args.name,
        "promoted_from": {
            "memory": args.memory.name,
            "latency": args.latency.name,
            "wer": args.wer.name,
        },
        "promoted_at": datetime.now(timezone.utc).isoformat(),
        "baseline_version": mem["baseline_version"],
        "host": mem["host"],
        "summary": {
            "memory": mem["summary"],
            "latency": lat["summary"],
            "wer": wer["summary"],
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(baseline, indent=2, ensure_ascii=False))

    s = baseline["summary"]
    print(f"wrote {args.out}")
    print(f"  memory.peak_phys_mb       = {s['memory']['peak_phys_mb']}")
    print(f"  memory.post_idle_phys_mb  = {s['memory']['post_idle_phys_mb']}")
    print(f"  memory.idle_drop_phys_mb  = {s['memory']['idle_drop_phys_mb']}")
    print(f"  latency.cold_ms           = {s['latency']['cold_ms']}")
    print(f"  latency.steady_median_ms  = {s['latency']['steady_median_ms']}")
    print(f"  latency.steady_p95_ms     = {s['latency']['steady_p95_ms']}")
    print(f"  wer.avg_wer               = {s['wer']['avg_wer']}")
    print(f"  wer.avg_cer               = {s['wer']['avg_cer']}")


if __name__ == "__main__":
    main()
