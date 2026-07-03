"""ASR engine — thin FastAPI shell with LazyModel + idle eviction.

Phase 1: ASR side only (no Qwen orchestration yet).

Run (server venv has mimo_mlx + opencc + fastapi):
    cd ~/Documents/voice-input-mimo-asr-engine
    PYTHONPATH=. /Users/shiun/Documents/voice-input-mimo/server/.venv/bin/python \\
        -m uvicorn engine.server:app --host 127.0.0.1 --port 8766

Endpoint parity with baseline server.py:
    POST /v1/audio/transcriptions  (form: file, language, output_locale)
    GET  /v1/health
    GET  /v1/models

Engine-only:
    GET  /admin/memory   — MemoryTracker snapshot + LazyModel status
    POST /admin/evict    — force-evict ASR model
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import functools
import json
import logging
import os
import sys
import tempfile
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Dict, List, Optional

import soundfile as sf
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse

from engine.adaptive_idle import AdaptiveIdleWindow
from engine.lifecycle import LazyModel
from engine.logsetup import emit_request_jsonl, setup_logging
from engine.memory import MemoryTracker
from engine.qwen_remote import RemoteQwenCacheManager

LOG_DIR = setup_logging()
log = logging.getLogger("engine.server")
log.info(f"engine logs at {LOG_DIR}/engine.log + transcribe.jsonl")

PRECISION = os.environ.get("MIMO_PRECISION", "int4")
MODEL_ROOT = Path(os.environ.get("MIMO_MODEL_ROOT", str(Path.home() / ".cache/mimo-asr")))
DEFAULT_LANGUAGE = os.environ.get("MIMO_DEFAULT_LANGUAGE", "auto")
OPENCC_CONFIG = os.environ.get("MIMO_OPENCC_CONFIG", "s2twp").strip()
# Ruleset lives in sibling voice-input-mimo/server repo; path is relative so it
# works on any machine where both repos are siblings under a common parent.
# Override via MIMO_ZHTW_RULESET env if layout differs.
_REPO_ROOT = Path(__file__).resolve().parent.parent
ZHTW_RULESET_PATH = Path(os.environ.get(
    "MIMO_ZHTW_RULESET",
    str(_REPO_ROOT.parent / "voice-input-mimo" / "server" / "zhtw_ruleset.json"),
))

METAL_CACHE_LIMIT_MB = int(os.environ.get("ENGINE_METAL_CACHE_LIMIT_MB", "1024"))

# Reject audio uploads larger than this. Localhost-bound but defense-in-depth.
MAX_AUDIO_BYTES = int(os.environ.get("ENGINE_MAX_AUDIO_BYTES", str(50 * 1024 * 1024)))

# Redact transcribe text in engine.log + transcribe.jsonl. Default off (dev
# convenience). Flip to 1 if you'll dictate sensitive content (tokens,
# passwords, internal docs) — text becomes "[redacted N chars]" instead of plain.
LOG_REDACT_TEXT = os.environ.get("ENGINE_LOG_REDACT_TEXT", "0").strip() == "1"

# admin endpoints (/admin/memory, /admin/evict, /admin/qwen/*) have no auth.
# uvicorn binds to whatever HOST is passed at startup. Warn loudly if not localhost.
_HOST_ENV = os.environ.get("HOST", "127.0.0.1").strip()
if _HOST_ENV not in ("127.0.0.1", "localhost", "::1", ""):
    log.warning(
        f"engine HOST={_HOST_ENV} — admin endpoints unauth, exposed beyond localhost!"
    )


def _redact(text: str) -> str:
    """Replace text with length-only marker if LOG_REDACT_TEXT enabled."""
    if not LOG_REDACT_TEXT or not text:
        return text
    return f"[redacted {len(text)} chars]"


def _parse_ladder(raw: str) -> tuple:
    parts = [float(s.strip()) for s in raw.split(",") if s.strip()]
    return tuple(parts)


IDLE_LADDER = _parse_ladder(os.environ.get("ENGINE_IDLE_LADDER_SECONDS", "180,420,900"))
IDLE_HARD_CEILING = float(os.environ.get("ENGINE_IDLE_HARD_CEILING_SECONDS", "1800"))
IDLE_CHECK_INTERVAL = float(os.environ.get("ENGINE_IDLE_CHECK_INTERVAL_SECONDS", "5"))

QWEN_ENABLE = os.environ.get("ENGINE_QWEN_ENABLE", "1") == "1"
QWEN_BASE_URL = os.environ.get("ENGINE_QWEN_BASE_URL", "http://127.0.0.1:8082")
QWEN_POLL_INTERVAL = float(os.environ.get("ENGINE_QWEN_POLL_INTERVAL_SECONDS", "5"))


def _load_mimo_asr():
    from mimo_mlx import load_asr
    MODEL_ROOT.mkdir(parents=True, exist_ok=True)
    return load_asr(precision=PRECISION, download=True, local_root=MODEL_ROOT)


_opencc = None
_zhtw_table: Optional[Dict[str, str]] = None
_zhtw_keys_sorted: Optional[List[str]] = None


def _load_opencc():
    global _opencc
    if _opencc is not None or not OPENCC_CONFIG:
        return _opencc
    try:
        from opencc import OpenCC
        _opencc = OpenCC(OPENCC_CONFIG)
        log.info(f"OpenCC loaded: config={OPENCC_CONFIG}")
    except Exception as e:
        log.warning(f"OpenCC load failed ({e}) — output left as model emits")
    return _opencc


def _load_zhtw_table() -> Dict[str, str]:
    global _zhtw_table, _zhtw_keys_sorted
    if _zhtw_table is not None:
        return _zhtw_table
    if not ZHTW_RULESET_PATH.exists():
        log.info(f"zhtw-mcp ruleset not found at {ZHTW_RULESET_PATH} — IT-vocabulary swap disabled")
        _zhtw_table = {}
        _zhtw_keys_sorted = []
        return _zhtw_table
    try:
        with open(ZHTW_RULESET_PATH, encoding="utf-8") as f:
            data = json.load(f)
        table: Dict[str, str] = {}
        for r in data.get("spelling_rules", []):
            src = r.get("from")
            targets = r.get("to") or []
            if not src or not targets:
                continue
            target = targets[0] if isinstance(targets, list) else targets
            if isinstance(target, dict):
                target = target.get("text") or target.get("term") or ""
            if isinstance(target, str) and target and target != src:
                table[src] = target
        _zhtw_table = table
        _zhtw_keys_sorted = sorted(table.keys(), key=len, reverse=True)
        log.info(f"zhtw-mcp ruleset loaded: {len(table)} rules")
    except Exception as e:
        log.warning(f"Failed to load zhtw-mcp ruleset ({e}) — IT-vocabulary swap disabled")
        _zhtw_table = {}
        _zhtw_keys_sorted = []
    return _zhtw_table


def _zhtw_swap(text: str) -> str:
    table = _load_zhtw_table()
    if not table or not _zhtw_keys_sorted:
        return text
    out = text
    for src in _zhtw_keys_sorted:
        if src in out:
            out = out.replace(src, table[src])
    return out


def _post_process(text: str, locale: str) -> str:
    if locale == "none" or not text:
        return text
    if locale == "zh-TW":
        cc = _load_opencc()
        out = text
        if cc is not None:
            try:
                out = cc.convert(out)
            except Exception as e:
                log.warning(f"OpenCC convert failed: {e}")
        return _zhtw_swap(out)
    return text


tracker = MemoryTracker()


def _collect_post_metrics() -> dict:
    """Metal cache trim + memory snapshot — blocking, kept off the event loop.

    trim_metal_cache touches Metal so it rides the dedicated inference thread;
    snapshot has no thread affinity but rides along to keep post-response
    housekeeping a single executor hop.
    """
    tracker.trim_metal_cache()
    return tracker.snapshot()


async def _evict_trim_on_infer_thread() -> None:
    """LazyModel on_evict hook — pin the Metal cache trim to the inference thread.

    evict() can fire from idle_check_loop or /admin/evict on the event-loop
    thread; running mx.metal.clear_cache() there would race an in-flight
    transcription on the mlx-infer thread. Hopping onto that same single-worker
    executor serializes the trim behind inference by construction, matching the
    transcribe + shutdown paths. Falls back to a direct call when the executor
    is not up (eviction outside an app lifespan, e.g. isolated tests). `app` is
    resolved lazily at call time, so the forward reference is safe.
    """
    executor = getattr(app.state, "infer_executor", None)
    if executor is None:
        tracker.trim_metal_cache()
        return
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(executor, tracker.trim_metal_cache)


asr_idle_window = AdaptiveIdleWindow(
    ladder_seconds=IDLE_LADDER,
    hard_ceiling_seconds=IDLE_HARD_CEILING,
)
asr_model = LazyModel(
    name="asr",
    loader=_load_mimo_asr,
    idle_window=asr_idle_window,
    on_evict=_evict_trim_on_infer_thread,
)

qwen_idle_window = AdaptiveIdleWindow(
    ladder_seconds=IDLE_LADDER,
    hard_ceiling_seconds=IDLE_HARD_CEILING,
)
qwen_manager: Optional[RemoteQwenCacheManager] = (
    RemoteQwenCacheManager(
        base_url=QWEN_BASE_URL,
        idle_window=qwen_idle_window,
        poll_interval=QWEN_POLL_INTERVAL,
    )
    if QWEN_ENABLE
    else None
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    tracker.set_metal_cache_limit_mb(METAL_CACHE_LIMIT_MB)
    # Dedicated single-thread executor for MLX inference. A private pool (not the
    # shared default threadpool behind asyncio.to_thread) guarantees every
    # transcription runs on the same OS thread — MLX + Metal have thread-affinity
    # quirks — while the Lock serializes callers so only one inference is ever in
    # flight. Both live off the event loop so /v1/health stays answerable mid-run.
    app.state.infer_executor = concurrent.futures.ThreadPoolExecutor(
        max_workers=1, thread_name_prefix="mlx-infer"
    )
    app.state.infer_lock = asyncio.Lock()
    idle_task = asyncio.create_task(
        asr_model.idle_check_loop(
            check_interval=IDLE_CHECK_INTERVAL,
            evict_guard=app.state.infer_lock,
        )
    )
    qwen_task = None
    if qwen_manager is not None:
        qwen_task = asyncio.create_task(qwen_manager.poll_loop())
    log.info(
        f"engine started — adaptive idle ladder={list(IDLE_LADDER)} "
        f"hard_ceiling={IDLE_HARD_CEILING:.0f}s "
        f"qwen_manager={'on' if qwen_manager else 'off'}"
    )
    # Accept MIMO_PRELOAD as a fallback: the Swift host (LocalASRServer) passes
    # the Settings "Preload" toggle as MIMO_PRELOAD, but this gate previously
    # only read ENGINE_PRELOAD — so the toggle was a dead switch and the engine
    # always lazy-loaded. Honour either name.
    if os.environ.get("ENGINE_PRELOAD", os.environ.get("MIMO_PRELOAD", "0")) == "1":
        await asr_model.warmup()
    try:
        yield
    finally:
        for task in (idle_task, qwen_task):
            if task is None:
                continue
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        # Evict under the inference lock (same one transcribe/idle use), then
        # drain and close the pool. Order matters: evict()'s Metal trim hops onto
        # infer_executor, so the pool must still be alive here — shut it down only
        # after the trim has run.
        async with app.state.infer_lock:
            await asr_model.evict()
        app.state.infer_executor.shutdown(wait=True)
        log.info("engine stopped")


app = FastAPI(title="voice-input-mimo ASR engine", version="0.1.0", lifespan=lifespan)


@app.get("/v1/health")
def health():
    return {
        "status": "ok",
        "asr_loaded": asr_model.is_loaded,
        "precision": PRECISION,
        "opencc_config": OPENCC_CONFIG or "off",
        "zhtw_rules_loaded": len(_zhtw_table or {}),
    }


@app.get("/v1/models")
def list_models():
    return {
        "object": "list",
        "data": [
            {"id": f"mimo-v2.5-asr-{PRECISION}", "object": "model", "owned_by": "xiaomi"},
        ],
    }


@app.post("/v1/audio/transcriptions")
async def transcribe(
    request: Request,
    file: UploadFile = File(...),
    language: Optional[str] = Form(None),
    model: Optional[str] = Form(None),
    response_format: Optional[str] = Form("json"),
    output_locale: Optional[str] = Form(None),
):
    request_id = (
        request.headers.get("X-Request-Id")
        or request.headers.get("x-request-id")
        or ""
    ).strip() or f"engine-{int(time.time()*1000)}"
    received_at = time.time()
    loop = asyncio.get_running_loop()
    raw = await file.read()
    if len(raw) > MAX_AUDIO_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"audio too large: {len(raw)} bytes (max {MAX_AUDIO_BYTES})",
        )
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(raw)
        tmp_path = Path(tmp.name)

    audio_duration_s: Optional[float] = None
    audio_sr: Optional[int] = None
    audio_ch: Optional[int] = None
    audio_fmt: Optional[str] = None
    cold_load = not asr_model.is_loaded
    raw_text = ""
    text = ""
    err: Optional[str] = None
    asr_elapsed = 0.0
    cc_elapsed = 0.0

    try:
        try:
            info = sf.info(str(tmp_path))
            audio_duration_s = info.duration
            audio_sr = info.samplerate
            audio_ch = info.channels
            audio_fmt = info.format
            log.info(
                "[req=%s] Transcribe: %s (%.1fs, %d Hz, %d ch, %s)",
                request_id, file.filename, info.duration, info.samplerate, info.channels, info.format,
            )
        except Exception as e:
            log.warning(f"[req={request_id}] sf.info failed ({e})")

        lang = (language or DEFAULT_LANGUAGE).lower()
        if lang not in ("auto", "zh", "en"):
            log.warning(f"[req={request_id}] Unknown language {lang!r} → auto")
            lang = "auto"

        # Serialize inference (belt-and-suspenders alongside the single-worker
        # executor) and run the blocking MLX call off the event loop so
        # /v1/health stays responsive while a transcription is in flight.
        async with request.app.state.infer_lock:
            asr = await asr_model.get()
            t0 = time.perf_counter()
            raw_text = await loop.run_in_executor(
                request.app.state.infer_executor,
                functools.partial(asr.transcribe, str(tmp_path), language=lang),
            )
            asr_elapsed = time.perf_counter() - t0

        locale = output_locale or "zh-TW"
        if locale.lower() == "zh-tw":
            locale = "zh-TW"
        t1 = time.perf_counter()
        text = _post_process(raw_text, locale)
        cc_elapsed = time.perf_counter() - t1

        log.info(
            "[req=%s] Transcribed in %.2fs (+ OpenCC %.0fms, locale=%s, cold=%s): %r → %r",
            request_id, asr_elapsed, cc_elapsed * 1000, locale, cold_load,
            _redact(raw_text), _redact(text),
        )

        if response_format == "text":
            # Whisper-compatible: plain UTF-8 body, NOT JSON-encoded string.
            return PlainTextResponse(content=text)
        return {
            "text": text,
            "raw_text": raw_text if text != raw_text else None,
            "language": lang,
            "output_locale": locale,
            "duration_ms": int((asr_elapsed + cc_elapsed) * 1000),
            "request_id": request_id,
        }
    except Exception as e:
        err = f"{type(e).__name__}: {e}"
        log.exception(f"[req={request_id}] Transcription failed")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        try:
            tmp_path.unlink()
        except OSError:
            pass
        # Post-response housekeeping — runs OFF the response path so that the
        # FastAPI response writes & connection flush complete immediately.
        # If this work runs synchronously in finally, URLSession on macOS
        # marks the connection unhealthy after 4s of "still busy" → forces
        # cold reconnect on next POST (~1s tax). Verified against raw
        # server.py baseline: same uvicorn, same client, the only difference
        # was these three calls in the finally block.
        idle_status = asr_model.idle_window.status() if asr_model.idle_window is not None else None
        jsonl_payload = {
            "request_id": request_id,
            "event": "transcribe",
            "received_at": received_at,
            "filename": file.filename,
            "audio_bytes": len(raw),
            "audio_duration_s": audio_duration_s,
            "audio_sr": audio_sr,
            "audio_ch": audio_ch,
            "audio_fmt": audio_fmt,
            "language": (language or DEFAULT_LANGUAGE).lower(),
            "output_locale": output_locale or "zh-TW",
            "cold_load": cold_load,
            "asr_elapsed_ms": int(asr_elapsed * 1000),
            "post_elapsed_ms": int(cc_elapsed * 1000),
            "raw_text": _redact(raw_text),
            "text": _redact(text),
            "error": err,
            "asr_idle_level": idle_status["level"] if idle_status else None,
            "asr_idle_window_s": idle_status["current_window_seconds"] if idle_status else None,
        }

        # Enqueue the housekeeping on the inference executor *now*, before this
        # handler yields, so it lands ahead of the next request's inference
        # instead of being starved behind it under continuous load. The submit
        # is synchronous; a tiny background task only awaits the result and
        # writes the jsonl, so the response still flushes without waiting.
        post_future = loop.run_in_executor(
            request.app.state.infer_executor, _collect_post_metrics
        )

        async def _finish_post_response_work():
            try:
                snap = await post_future
                jsonl_payload["phys_mb"] = snap.get("phys_mb")
                jsonl_payload["rss_mb"] = snap.get("rss_mb")
            except Exception:  # noqa: BLE001
                log.exception(f"[req={request_id}] post-response metrics failed")
            emit_request_jsonl(jsonl_payload)

        asyncio.create_task(_finish_post_response_work())


@app.get("/admin/memory")
def admin_memory():
    # Admin diagnostics — bypass TTL cache, force fresh vmmap.
    return {
        "memory": tracker.snapshot(fresh=True),
        "asr": asr_model.status(),
        "qwen": qwen_manager.status() if qwen_manager is not None else {"enabled": False},
    }


@app.post("/admin/evict")
async def admin_evict():
    # Serialize with transcribe so the eviction's Metal trim never races an
    # in-flight inference on the mlx-infer thread.
    async with app.state.infer_lock:
        await asr_model.evict()
    return {
        "evicted": True,
        "after": {
            "memory": tracker.snapshot(fresh=True),
            "asr": asr_model.status(),
        },
    }


@app.get("/admin/qwen/status")
def admin_qwen_status():
    if qwen_manager is None:
        return {"enabled": False}
    return qwen_manager.status()


@app.post("/admin/qwen/cache_clear")
async def admin_qwen_cache_clear():
    if qwen_manager is None:
        raise HTTPException(status_code=503, detail="qwen_manager disabled")
    ok = await qwen_manager.force_cache_clear()
    return {"ok": ok, "after": qwen_manager.status()}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8766, log_level="info")
