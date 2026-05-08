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
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

from engine.lifecycle import LazyModel
from engine.memory import MemoryTracker

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("engine.server")

PRECISION = os.environ.get("MIMO_PRECISION", "int4")
MODEL_ROOT = Path(os.environ.get("MIMO_MODEL_ROOT", str(Path.home() / ".cache/mimo-asr")))
DEFAULT_LANGUAGE = os.environ.get("MIMO_DEFAULT_LANGUAGE", "auto")
OPENCC_CONFIG = os.environ.get("MIMO_OPENCC_CONFIG", "s2twp").strip()
ZHTW_RULESET_PATH = Path(os.environ.get(
    "MIMO_ZHTW_RULESET",
    "/Users/shiun/Documents/voice-input-mimo/server/zhtw_ruleset.json",
))

ASR_IDLE_SECONDS = float(os.environ.get("ENGINE_ASR_IDLE_SECONDS", "15"))
METAL_CACHE_LIMIT_MB = int(os.environ.get("ENGINE_METAL_CACHE_LIMIT_MB", "1024"))


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
asr_model = LazyModel(
    name="asr",
    loader=_load_mimo_asr,
    idle_seconds=ASR_IDLE_SECONDS,
    on_evict=tracker.trim_metal_cache,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    tracker.set_metal_cache_limit_mb(METAL_CACHE_LIMIT_MB)
    idle_task = asyncio.create_task(asr_model.idle_check_loop())
    log.info("engine started — idle eviction running")
    if os.environ.get("ENGINE_PRELOAD", "0") == "1":
        await asr_model.warmup()
    try:
        yield
    finally:
        idle_task.cancel()
        try:
            await idle_task
        except (asyncio.CancelledError, Exception):
            pass
        await asr_model.evict()
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
    file: UploadFile = File(...),
    language: Optional[str] = Form(None),
    model: Optional[str] = Form(None),
    response_format: Optional[str] = Form("json"),
    output_locale: Optional[str] = Form(None),
):
    raw = await file.read()
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(raw)
        tmp_path = Path(tmp.name)

    try:
        try:
            info = sf.info(str(tmp_path))
            log.info(
                "Transcribe: %s (%.1fs, %d Hz, %d ch, %s)",
                file.filename, info.duration, info.samplerate, info.channels, info.format,
            )
        except Exception as e:
            log.warning(f"sf.info failed ({e})")

        lang = (language or DEFAULT_LANGUAGE).lower()
        if lang not in ("auto", "zh", "en"):
            log.warning(f"Unknown language {lang!r} → auto")
            lang = "auto"

        asr = await asr_model.get()
        t0 = time.perf_counter()
        raw_text = asr.transcribe(str(tmp_path), language=lang)
        asr_elapsed = time.perf_counter() - t0

        locale = output_locale or "zh-TW"
        if locale.lower() == "zh-tw":
            locale = "zh-TW"
        t1 = time.perf_counter()
        text = _post_process(raw_text, locale)
        cc_elapsed = time.perf_counter() - t1

        log.info(
            "Transcribed in %.2fs (+ OpenCC %.0fms, locale=%s): %r → %r",
            asr_elapsed, cc_elapsed * 1000, locale, raw_text, text,
        )

        if response_format == "text":
            return JSONResponse(content=text, media_type="text/plain")
        return {
            "text": text,
            "raw_text": raw_text if text != raw_text else None,
            "language": lang,
            "output_locale": locale,
            "duration_ms": int((asr_elapsed + cc_elapsed) * 1000),
        }
    except Exception as e:
        log.exception("Transcription failed")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        tracker.trim_metal_cache()
        try:
            tmp_path.unlink()
        except OSError:
            pass


@app.get("/admin/memory")
def admin_memory():
    return {
        "memory": tracker.snapshot(),
        "asr": asr_model.status(),
    }


@app.post("/admin/evict")
async def admin_evict():
    await asr_model.evict()
    return {
        "evicted": True,
        "after": {
            "memory": tracker.snapshot(),
            "asr": asr_model.status(),
        },
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8766, log_level="info")
