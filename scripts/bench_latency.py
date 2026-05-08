"""Profile cold-start vs warm vs steady-state latency.

MiMo-V2.5-ASR is batch decode (no streaming TTFT). For batch ASR,
`batch_total_ms` is the user-facing latency. If streaming is added later,
record first-partial timing here too.

Usage:
    python scripts/bench_latency.py \\
        --server-url http://127.0.0.1:8765 \\
        --audio fixtures/audio/zh-tw-short-01.wav \\
        --runs 10 \\
        --out harness/runs/server-py-latency-$(date +%Y%m%d-%H%M%S).json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import time
from pathlib import Path

import httpx

from _baseline_meta import git_meta, host_meta


async def _hit(client: httpx.AsyncClient, url: str, audio_path: Path, language: str) -> dict:
    with audio_path.open("rb") as f:
        files = {"file": (audio_path.name, f, "audio/wav")}
        data = {"language": language}
        t0 = time.perf_counter()
        resp = await client.post(f"{url}/v1/audio/transcriptions", files=files, data=data, timeout=120.0)
        elapsed_ms = (time.perf_counter() - t0) * 1000
    return {"status": resp.status_code, "ms": elapsed_ms, "ok": resp.status_code == 200}


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--server-url", default="http://127.0.0.1:8765")
    ap.add_argument("--audio", type=Path, required=True)
    ap.add_argument("--language", default="zh")
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--repo-path", type=Path, default=Path(__file__).resolve().parent.parent)
    args = ap.parse_args()

    if not args.audio.exists():
        raise SystemExit(f"audio not found: {args.audio}")

    timings: list[dict] = []
    async with httpx.AsyncClient() as client:
        for i in range(args.runs):
            r = await _hit(client, args.server_url, args.audio, args.language)
            r["i"] = i
            timings.append(r)

    successes_ms = [t["ms"] for t in timings if t["ok"]]
    cold_ms = timings[0]["ms"] if timings else None
    warm_ms = timings[1]["ms"] if len(timings) >= 2 else None
    steady_median = statistics.median(successes_ms[2:]) if len(successes_ms) >= 3 else None
    steady_p95 = (
        statistics.quantiles(successes_ms[2:], n=20)[18]
        if len(successes_ms) >= 5 else None
    )

    result = {
        "schema_version": 1,
        "metric": "latency",
        "baseline_version": git_meta(args.repo_path),
        "host": host_meta(),
        "config": {
            "server_url": args.server_url,
            "audio": str(args.audio),
            "language": args.language,
            "runs": args.runs,
        },
        "summary": {
            "cold_ms": cold_ms,
            "warm_ms": warm_ms,
            "steady_median_ms": steady_median,
            "steady_p95_ms": steady_p95,
            "n_success": len(successes_ms),
            "n_total": len(timings),
        },
        "all_timings_ms": timings,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(f"wrote {args.out}")
    print(f"  cold_ms         = {cold_ms:.1f}" if cold_ms is not None else "  cold_ms         = N/A")
    print(f"  warm_ms         = {warm_ms:.1f}" if warm_ms is not None else "  warm_ms         = N/A")
    print(f"  steady_median   = {steady_median:.1f}" if steady_median is not None else "  steady_median   = N/A")
    print(f"  steady_p95      = {steady_p95:.1f}" if steady_p95 is not None else "  steady_p95      = N/A")


if __name__ == "__main__":
    asyncio.run(main())
