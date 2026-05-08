"""Phase 2 bench — Qwen cache_clear via adaptive idle.

Simulates: 5 chat completions to fill Qwen prefix cache, then idle 5+ min
            (> L1 180s) → expect engine.qwen_remote to detect use, escalate
            to L1 → expire → POST /v1/cache/clear → cache_mb drops to ~0.

Caveat: this bench targets the Rapid-MLX instance at port 8082 directly. If
the user's voice-input app routes LLM refining through LM Studio (port 1234)
instead, this bench validates engine→Rapid-MLX wiring but does NOT validate
that real app traffic triggers the cache_clear. To validate end-to-end,
point voice-input app's `llmAPIBaseURL` to http://127.0.0.1:8082/v1.

Run from repo root:
    PYTHONPATH=. /Users/shiun/Documents/voice-input-mimo/server/.venv/bin/python \\
        scripts/bench_phase2_qwen_cache.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

from scripts._baseline_meta import git_meta, host_meta
from scripts._phase2_runner import (
    admin_memory,
    emit_baseline,
    qwen_chat,
    qwen_status,
    snapshot,
)

CHAT_CALLS = 5
CHAT_INTERVAL_S = 10.0
IDLE_DURATION_S = 360.0
SAMPLE_INTERVAL_S = 15.0
SCENARIO = "qwen_cache"

PROMPTS = [
    "Translate to English: 你好世界",
    "Summarize: PostgreSQL is a relational DBMS.",
    "What is 25 * 17?",
    "Reply with one word: 紅色 in English",
    "Count to three.",
]


def main() -> int:
    am = admin_memory()
    if am is None:
        print("[bench] engine unreachable", file=sys.stderr)
        return 2
    qstat = qwen_status()
    if qstat is None:
        print("[bench] qwen unreachable at 127.0.0.1:8082", file=sys.stderr)
        return 2

    initial_cache_mb = (qstat.get("cache") or {}).get("current_memory_mb", 0.0)
    initial_evictions = (qstat.get("cache") or {}).get("evictions", 0)
    print(f"[bench] start scenario={SCENARIO} initial_cache_mb={initial_cache_mb:.0f}")

    samples: list[dict] = []
    chats: list[dict] = []
    t_start = time.time()

    for i in range(CHAT_CALLS):
        prompt = PROMPTS[i % len(PROMPTS)]
        resp, elapsed = qwen_chat(prompt)
        ok = resp is not None and "choices" in resp
        content = ""
        if ok:
            try:
                content = resp["choices"][0]["message"]["content"][:120]
            except (KeyError, IndexError, TypeError):
                content = ""
        chats.append({
            "i": i, "prompt": prompt, "elapsed_ms": int(elapsed * 1000),
            "ok": ok, "content_preview": content,
        })
        samples.append(snapshot())
        print(f"[bench] chat {i+1}/{CHAT_CALLS} elapsed={elapsed:.1f}s ok={ok}")
        if i + 1 < CHAT_CALLS:
            time.sleep(CHAT_INTERVAL_S)

    qstat_after = qwen_status() or {}
    cache_after_calls = (qstat_after.get("cache") or {}).get("current_memory_mb", 0.0)
    print(f"[bench] post-chat cache_mb={cache_after_calls:.0f} — entering idle")

    cache_clear_observed = False
    cache_clear_at: float | None = None
    t_idle_start = time.time()
    while time.time() - t_idle_start < IDLE_DURATION_S:
        s = snapshot()
        samples.append(s)
        s["qwen_status_cache_mb"] = (
            (qwen_status() or {}).get("cache", {}).get("current_memory_mb")
        )
        if (s.get("qwen_cache_clears_done") or 0) > 0 and not cache_clear_observed:
            cache_clear_observed = True
            cache_clear_at = time.time() - t_idle_start
            print(f"[bench] cache_clear observed at idle+{cache_clear_at:.0f}s")
        time.sleep(SAMPLE_INTERVAL_S)

    qstat_final = qwen_status() or {}
    cache_final = (qstat_final.get("cache") or {}).get("current_memory_mb", 0.0)
    samples.append(snapshot())
    duration_s = int(time.time() - t_start)

    payload = {
        "scenario": SCENARIO,
        "git": git_meta("."),
        "host": host_meta(),
        "config": {
            "chat_calls": CHAT_CALLS,
            "chat_interval_s": CHAT_INTERVAL_S,
            "idle_duration_s": IDLE_DURATION_S,
        },
        "result": {
            "duration_s": duration_s,
            "initial_cache_mb": initial_cache_mb,
            "cache_after_chats_mb": cache_after_calls,
            "cache_final_mb": cache_final,
            "cache_clear_observed": cache_clear_observed,
            "cache_clear_at_idle_s": cache_clear_at,
        },
        "chats": chats,
        "samples": samples,
        "verdict": {
            "expected_cache_clear_observed": True,
            "expected_cache_final_mb_lt": 100,
        },
    }
    emit_baseline(SCENARIO, payload)
    print(f"[bench] done. cache {initial_cache_mb:.0f}→{cache_after_calls:.0f}→{cache_final:.0f}MB "
          f"clear_observed={cache_clear_observed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
