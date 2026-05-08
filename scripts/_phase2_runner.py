"""Shared helpers for Phase 2 bench scripts.

Provides:
    - post_transcribe(wav, base_url) → response dict + elapsed
    - admin_memory(base_url) → /admin/memory dict
    - qwen_chat(prompt, qwen_base_url) → response dict + elapsed
    - qwen_status(qwen_base_url) → /v1/status dict
    - record_snapshot(...) → list[dict] sample with phys_mb / level / cache_mb
    - emit_baseline(scenario, payload, out_dir) → write JSON to harness/baselines/
"""

from __future__ import annotations

import json
import time
import urllib.request
from pathlib import Path
from typing import Any, Optional


def http_get_json(url: str, timeout: float = 5.0) -> Optional[dict]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"[runner] GET {url} failed: {type(e).__name__}: {e}")
        return None


def http_post_json(url: str, body: dict, timeout: float = 60.0) -> Optional[dict]:
    payload = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=payload, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"[runner] POST {url} failed: {type(e).__name__}: {e}")
        return None


def http_post_empty(url: str, timeout: float = 5.0) -> bool:
    req = urllib.request.Request(url, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp.read()
        return True
    except Exception as e:
        print(f"[runner] POST {url} failed: {type(e).__name__}: {e}")
        return False


def post_transcribe(wav_path: Path, base_url: str = "http://127.0.0.1:8766",
                    request_id: str = "") -> tuple[Optional[dict], float]:
    boundary = f"----bench-{int(time.time()*1000)}"
    audio = wav_path.read_bytes()
    crlf = b"\r\n"
    body = b""
    body += f"--{boundary}\r\n".encode()
    body += f'Content-Disposition: form-data; name="file"; filename="{wav_path.name}"\r\n'.encode()
    body += b"Content-Type: audio/wav\r\n\r\n"
    body += audio + crlf
    for k, v in (("language", "auto"), ("output_locale", "zh-TW")):
        body += f"--{boundary}\r\n".encode()
        body += f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode()
        body += f"{v}\r\n".encode()
    body += f"--{boundary}--\r\n".encode()

    url = f"{base_url}/v1/audio/transcriptions"
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    if request_id:
        req.add_header("X-Request-Id", request_id)

    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
        return data, time.perf_counter() - t0
    except Exception as e:
        print(f"[runner] POST {url} failed: {type(e).__name__}: {e}")
        return None, time.perf_counter() - t0


def admin_memory(base_url: str = "http://127.0.0.1:8766") -> Optional[dict]:
    return http_get_json(f"{base_url}/admin/memory")


def qwen_chat(prompt: str, qwen_base_url: str = "http://127.0.0.1:8082",
              model: str = "qwen3-8b-mlx", max_tokens: int = 100) -> tuple[Optional[dict], float]:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.3,
    }
    t0 = time.perf_counter()
    resp = http_post_json(f"{qwen_base_url}/v1/chat/completions", body, timeout=180)
    return resp, time.perf_counter() - t0


def qwen_status(qwen_base_url: str = "http://127.0.0.1:8082") -> Optional[dict]:
    return http_get_json(f"{qwen_base_url}/v1/status")


def snapshot(base_url: str = "http://127.0.0.1:8766",
             qwen_base_url: str = "http://127.0.0.1:8082") -> dict:
    am = admin_memory(base_url) or {}
    asr = am.get("asr") or {}
    qwen_stat = am.get("qwen") or {}
    qwen_idle = qwen_stat.get("idle_window") or {}
    asr_idle = asr.get("idle") or {}
    return {
        "ts": time.time(),
        "phys_mb": (am.get("memory") or {}).get("phys_mb"),
        "rss_mb": (am.get("memory") or {}).get("rss_mb"),
        "asr_loaded": asr.get("loaded"),
        "asr_level": asr_idle.get("level"),
        "asr_window_s": asr_idle.get("current_window_seconds"),
        "asr_time_since_use_s": asr_idle.get("time_since_use_s"),
        "qwen_reachable": qwen_stat.get("reachable"),
        "qwen_level": qwen_idle.get("level"),
        "qwen_window_s": qwen_idle.get("current_window_seconds"),
        "qwen_uses_observed": qwen_stat.get("uses_observed"),
        "qwen_cache_clears_done": qwen_stat.get("cache_clears_done"),
        "qwen_cache_mb_obs": (qwen_stat.get("last_observed") or {}).get("cache_mb"),
    }


def emit_baseline(scenario: str, payload: dict,
                  out_dir: Path = Path("harness/baselines")) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    out = out_dir / f"phase2-{scenario}-{ts}.json"
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
    print(f"[runner] wrote {out}")
    return out


def list_fixtures(fixtures_dir: Path = Path("fixtures/audio")) -> list[Path]:
    files = sorted(fixtures_dir.glob("*.wav"))
    if not files:
        raise FileNotFoundError(f"No wav files in {fixtures_dir}")
    return files


def percentile(values: list[float], p: float) -> Optional[float]:
    if not values:
        return None
    sorted_v = sorted(values)
    k = (len(sorted_v) - 1) * p
    f = int(k)
    c = min(f + 1, len(sorted_v) - 1)
    if f == c:
        return float(sorted_v[f])
    return float(sorted_v[f] + (sorted_v[c] - sorted_v[f]) * (k - f))
