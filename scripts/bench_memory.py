"""Profile RSS across cold-start, request, idle phases.

Phase 0 baseline measurement for voice-input-mimo `server.py`.

Caveat: MLX `mx.metal.get_active_memory()` only works inside the server
process. Until the server exposes an `/admin/memory` endpoint, this script
profiles RSS only (which already covers the unbounded-cache regression we
care about for Phase 0).

Usage:
    python scripts/bench_memory.py \\
        --server-pid $(pgrep -f 'uvicorn server:app') \\
        --server-url http://127.0.0.1:8765 \\
        --audio fixtures/audio/zh-tw-short-01.wav \\
        --runs 5 --idle-secs 30 \\
        --out harness/runs/server-py-memory-$(date +%Y%m%d-%H%M%S).json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import time
from pathlib import Path

import httpx
import psutil

from _baseline_meta import git_meta, host_meta


async def _hit_server(client: httpx.AsyncClient, url: str, audio_path: Path, language: str) -> tuple[int, float]:
    with audio_path.open("rb") as f:
        files = {"file": (audio_path.name, f, "audio/wav")}
        data = {"language": language}
        t0 = time.perf_counter()
        resp = await client.post(f"{url}/v1/audio/transcriptions", files=files, data=data, timeout=120.0)
        elapsed_ms = (time.perf_counter() - t0) * 1000
    return resp.status_code, elapsed_ms


def _sample_rss(pid: int) -> float:
    return psutil.Process(pid).memory_info().rss / (1024 * 1024)


async def _idle_sample(pid: int, duration_s: int, interval_s: float = 1.0) -> list[dict]:
    samples: list[dict] = []
    deadline = time.perf_counter() + duration_s
    t0 = time.perf_counter()
    while time.perf_counter() < deadline:
        samples.append({"t": time.perf_counter() - t0, "rss_mb": _sample_rss(pid)})
        await asyncio.sleep(interval_s)
    return samples


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--server-url", default="http://127.0.0.1:8765")
    ap.add_argument("--server-pid", type=int, required=True)
    ap.add_argument("--audio", type=Path, required=True)
    ap.add_argument("--language", default="zh")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--idle-secs", type=int, default=30)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--repo-path", type=Path, default=Path(__file__).resolve().parent.parent)
    args = ap.parse_args()

    if not args.audio.exists():
        raise SystemExit(f"audio not found: {args.audio}")

    cold_rss = _sample_rss(args.server_pid)

    request_runs: list[dict] = []
    async with httpx.AsyncClient() as client:
        for i in range(args.runs):
            pre_rss = _sample_rss(args.server_pid)
            status, ms = await _hit_server(client, args.server_url, args.audio, args.language)
            post_rss = _sample_rss(args.server_pid)
            request_runs.append({
                "i": i,
                "status": status,
                "ms": ms,
                "pre_rss_mb": pre_rss,
                "post_rss_mb": post_rss,
                "delta_rss_mb": post_rss - pre_rss,
            })

    idle_samples = await _idle_sample(args.server_pid, args.idle_secs)
    post_idle_rss = idle_samples[-1]["rss_mb"] if idle_samples else _sample_rss(args.server_pid)
    peak_rss = max([cold_rss, *(r["post_rss_mb"] for r in request_runs), *(s["rss_mb"] for s in idle_samples)])

    result = {
        "schema_version": 1,
        "metric": "memory",
        "baseline_version": git_meta(args.repo_path),
        "host": host_meta(),
        "config": {
            "server_url": args.server_url,
            "server_pid": args.server_pid,
            "audio": str(args.audio),
            "language": args.language,
            "runs": args.runs,
            "idle_secs": args.idle_secs,
        },
        "summary": {
            "cold_rss_mb": cold_rss,
            "peak_rss_mb": peak_rss,
            "post_idle_rss_mb": post_idle_rss,
            "idle_drop_mb": peak_rss - post_idle_rss,
        },
        "request_runs": request_runs,
        "idle_samples": idle_samples,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(f"wrote {args.out}")
    print(f"  cold_rss_mb       = {cold_rss:.1f}")
    print(f"  peak_rss_mb       = {peak_rss:.1f}")
    print(f"  post_idle_rss_mb  = {post_idle_rss:.1f}")
    print(f"  idle_drop_mb      = {peak_rss - post_idle_rss:.1f}")


if __name__ == "__main__":
    asyncio.run(main())
