"""Profile process memory across cold-start, request, idle phases.

Phase 0 baseline measurement for voice-input-mimo `server.py`.

Memory metrics:
  - phys_mb (PRIMARY): macOS phys_footprint via `vmmap --summary`. Matches
    Activity Monitor "Memory" column. Includes mmap'd MLX model weights —
    which is what we actually want to track. Linux: None.
  - rss_mb (BACKUP): psutil RSS. On macOS this misses mmap'd pages (often
    reads ~100 MB even though phys is 5+ GB), kept for cross-platform
    comparability.

MLX `mx.metal.get_active_memory()` only works inside the server process.
Until the server exposes an `/admin/memory` endpoint, this script profiles
process-level memory only — which already covers the unbounded-cache
regression we care about for Phase 0.

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
import platform
import subprocess
import time
from pathlib import Path

import httpx
import psutil

from _baseline_meta import git_meta, host_meta


def _parse_size_to_mb(s: str) -> float:
    s = s.strip()
    if s.endswith("G"):
        return float(s[:-1]) * 1024
    if s.endswith("M"):
        return float(s[:-1])
    if s.endswith("K"):
        return float(s[:-1]) / 1024
    return float(s) / (1024 * 1024)


def _sample_phys_footprint_mb(pid: int) -> float | None:
    """macOS Activity-Monitor-equivalent memory; None on Linux/error."""
    if platform.system() != "Darwin":
        return None
    try:
        out = subprocess.check_output(
            ["vmmap", "--summary", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return None
    for line in out.splitlines():
        if line.startswith("Physical footprint:"):
            return _parse_size_to_mb(line.split(":", 1)[1].strip())
    return None


async def _hit_server(client: httpx.AsyncClient, url: str, audio_path: Path, language: str) -> tuple[int, float]:
    with audio_path.open("rb") as f:
        files = {"file": (audio_path.name, f, "audio/wav")}
        data = {"language": language}
        t0 = time.perf_counter()
        resp = await client.post(f"{url}/v1/audio/transcriptions", files=files, data=data, timeout=120.0)
        elapsed_ms = (time.perf_counter() - t0) * 1000
    return resp.status_code, elapsed_ms


def _sample_memory(pid: int) -> dict:
    rss_mb = psutil.Process(pid).memory_info().rss / (1024 * 1024)
    phys_mb = _sample_phys_footprint_mb(pid)
    return {"rss_mb": rss_mb, "phys_mb": phys_mb}


async def _idle_sample(pid: int, duration_s: int, interval_s: float = 1.0) -> list[dict]:
    samples: list[dict] = []
    deadline = time.perf_counter() + duration_s
    t0 = time.perf_counter()
    while time.perf_counter() < deadline:
        samples.append({"t": time.perf_counter() - t0, **_sample_memory(pid)})
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

    cold = _sample_memory(args.server_pid)

    request_runs: list[dict] = []
    async with httpx.AsyncClient() as client:
        for i in range(args.runs):
            pre = _sample_memory(args.server_pid)
            status, ms = await _hit_server(client, args.server_url, args.audio, args.language)
            post = _sample_memory(args.server_pid)
            request_runs.append({
                "i": i,
                "status": status,
                "ms": ms,
                "pre": pre,
                "post": post,
                "delta_phys_mb": (
                    post["phys_mb"] - pre["phys_mb"]
                    if post["phys_mb"] is not None and pre["phys_mb"] is not None
                    else None
                ),
                "delta_rss_mb": post["rss_mb"] - pre["rss_mb"],
            })

    idle_samples = await _idle_sample(args.server_pid, args.idle_secs)
    post_idle = idle_samples[-1] if idle_samples else _sample_memory(args.server_pid)

    def _all_phys() -> list[float]:
        out = [cold["phys_mb"]] if cold["phys_mb"] is not None else []
        out += [r["post"]["phys_mb"] for r in request_runs if r["post"]["phys_mb"] is not None]
        out += [s["phys_mb"] for s in idle_samples if s.get("phys_mb") is not None]
        return out

    def _all_rss() -> list[float]:
        return [cold["rss_mb"], *(r["post"]["rss_mb"] for r in request_runs), *(s["rss_mb"] for s in idle_samples)]

    phys_values = _all_phys()
    peak_phys_mb = max(phys_values) if phys_values else None
    peak_rss_mb = max(_all_rss())

    result = {
        "schema_version": 2,
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
            "cold_phys_mb": cold["phys_mb"],
            "cold_rss_mb": cold["rss_mb"],
            "peak_phys_mb": peak_phys_mb,
            "peak_rss_mb": peak_rss_mb,
            "post_idle_phys_mb": post_idle.get("phys_mb"),
            "post_idle_rss_mb": post_idle["rss_mb"],
            "idle_drop_phys_mb": (
                peak_phys_mb - post_idle["phys_mb"]
                if peak_phys_mb is not None and post_idle.get("phys_mb") is not None
                else None
            ),
            "idle_drop_rss_mb": peak_rss_mb - post_idle["rss_mb"],
        },
        "request_runs": request_runs,
        "idle_samples": idle_samples,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    s = result["summary"]
    print(f"wrote {args.out}")
    print(f"  cold_phys_mb       = {s['cold_phys_mb']}")
    print(f"  peak_phys_mb       = {s['peak_phys_mb']}")
    print(f"  post_idle_phys_mb  = {s['post_idle_phys_mb']}")
    print(f"  idle_drop_phys_mb  = {s['idle_drop_phys_mb']}")
    print(f"  (rss for backup)   cold={s['cold_rss_mb']:.1f}  peak={s['peak_rss_mb']:.1f}  post_idle={s['post_idle_rss_mb']:.1f}")


if __name__ == "__main__":
    asyncio.run(main())
