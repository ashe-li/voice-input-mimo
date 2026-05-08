"""Measure WER / CER vs golden transcript yaml.

Golden YAML schema:
    fixtures/golden/transcripts.yaml:
        zh-tw-short-01.wav:
            text: "今天天氣很好"
            lang: zh-tw
        code-switch-01.wav:
            text: "我們用 Slack 開會"
            lang: zh-tw

Usage:
    python scripts/bench_wer.py \\
        --server-url http://127.0.0.1:8765 \\
        --golden fixtures/golden/transcripts.yaml \\
        --audio-dir fixtures/audio \\
        --out harness/runs/server-py-wer-$(date +%Y%m%d-%H%M%S).json
"""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path

import httpx
import yaml
from jiwer import cer, wer

from _baseline_meta import git_meta, host_meta


async def _transcribe(client: httpx.AsyncClient, url: str, audio_path: Path, language: str) -> str:
    with audio_path.open("rb") as f:
        files = {"file": (audio_path.name, f, "audio/wav")}
        data = {"language": language}
        resp = await client.post(f"{url}/v1/audio/transcriptions", files=files, data=data, timeout=120.0)
        resp.raise_for_status()
    return resp.json().get("text", "")


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--server-url", default="http://127.0.0.1:8765")
    ap.add_argument("--golden", type=Path, required=True)
    ap.add_argument("--audio-dir", type=Path, default=Path("fixtures/audio"))
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--repo-path", type=Path, default=Path(__file__).resolve().parent.parent)
    args = ap.parse_args()

    if not args.golden.exists():
        raise SystemExit(f"golden not found: {args.golden}")
    golden = yaml.safe_load(args.golden.read_text())
    if not isinstance(golden, dict):
        raise SystemExit("golden YAML must be a mapping {filename: {text, lang}}")

    items: list[dict] = []
    async with httpx.AsyncClient() as client:
        for fname, meta in golden.items():
            audio_path = args.audio_dir / fname
            if not audio_path.exists():
                items.append({"file": fname, "error": "audio missing", "skip": True})
                continue
            ref = meta["text"]
            language = meta.get("lang", "zh").split("-")[0]
            try:
                hyp = await _transcribe(client, args.server_url, audio_path, language)
            except httpx.HTTPError as e:
                items.append({"file": fname, "error": f"http: {e}", "skip": True})
                continue
            items.append({
                "file": fname,
                "lang": meta.get("lang"),
                "ref": ref,
                "hyp": hyp,
                "wer": wer(ref, hyp),
                "cer": cer(ref, hyp),
            })

    scored = [it for it in items if "wer" in it]
    avg_wer = sum(it["wer"] for it in scored) / len(scored) if scored else None
    avg_cer = sum(it["cer"] for it in scored) / len(scored) if scored else None

    result = {
        "schema_version": 1,
        "metric": "quality",
        "baseline_version": git_meta(args.repo_path),
        "host": host_meta(),
        "config": {
            "server_url": args.server_url,
            "golden": str(args.golden),
            "audio_dir": str(args.audio_dir),
        },
        "summary": {
            "avg_wer": avg_wer,
            "avg_cer": avg_cer,
            "n_scored": len(scored),
            "n_total": len(items),
        },
        "items": items,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(f"wrote {args.out}")
    if avg_wer is not None:
        print(f"  avg_wer = {avg_wer:.4f}")
        print(f"  avg_cer = {avg_cer:.4f}")
    print(f"  n_scored / n_total = {len(scored)} / {len(items)}")


if __name__ == "__main__":
    asyncio.run(main())
