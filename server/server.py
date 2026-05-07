"""MiMo-V2.5-ASR FastAPI server (Whisper-compat).

Endpoint:
  POST /v1/audio/transcriptions   (multipart: file, language)
  GET  /v1/health
  GET  /v1/models

Run:
  uvicorn server:app --host 127.0.0.1 --port 8765
"""
from __future__ import annotations

import io
import json
import logging
import os
import sys
import tempfile
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Dict, Optional

import soundfile as sf
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("mimo-asr")

PRECISION = os.environ.get("MIMO_PRECISION", "int4")
MODEL_ROOT = Path(os.environ.get("MIMO_MODEL_ROOT", str(Path.home() / ".cache/mimo-asr")))
DEFAULT_LANGUAGE = os.environ.get("MIMO_DEFAULT_LANGUAGE", "auto")
# OpenCC config: s2twp (Taiwan + phrase swap), s2tw (character only), s2t (basic), or "" (off)
OPENCC_CONFIG = os.environ.get("MIMO_OPENCC_CONFIG", "s2twp").strip()
# Path to zhtw-mcp ruleset (sysprog21/zhtw-mcp). Empty string disables.
ZHTW_RULESET_PATH = Path(
    os.environ.get("MIMO_ZHTW_RULESET", str(Path(__file__).parent / "zhtw_ruleset.json"))
)

_asr = None
_opencc = None
_zhtw_table: Optional[Dict[str, str]] = None
_zhtw_keys_sorted: Optional[list] = None


def _load_opencc():
    """Lazy-load OpenCC converter."""
    global _opencc
    if _opencc is not None or not OPENCC_CONFIG:
        return _opencc
    try:
        from opencc import OpenCC
        _opencc = OpenCC(OPENCC_CONFIG)
        log.info("OpenCC loaded: config=%s", OPENCC_CONFIG)
    except Exception as e:
        log.warning("OpenCC load failed (%s) — output will be left as model emits", e)
        _opencc = None
    return _opencc


def _load_zhtw_table() -> Dict[str, str]:
    """Lazy-load zhtw-mcp ruleset (sysprog21/zhtw-mcp)."""
    global _zhtw_table, _zhtw_keys_sorted
    if _zhtw_table is not None:
        return _zhtw_table
    if not ZHTW_RULESET_PATH.exists():
        log.info("zhtw-mcp ruleset not found at %s — IT-vocabulary swap disabled", ZHTW_RULESET_PATH)
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
        # Sort longest-first so multi-char phrases match before substrings
        _zhtw_keys_sorted = sorted(table.keys(), key=len, reverse=True)
        log.info("zhtw-mcp ruleset loaded: %d rules", len(table))
    except Exception as e:
        log.warning("Failed to load zhtw-mcp ruleset (%s) — IT-vocabulary swap disabled", e)
        _zhtw_table = {}
        _zhtw_keys_sorted = []
    return _zhtw_table


def _zhtw_swap(text: str) -> str:
    """Apply zhtw-mcp IT-vocabulary substitutions on top of OpenCC output."""
    table = _load_zhtw_table()
    if not table or not _zhtw_keys_sorted:
        return text
    out = text
    for src in _zhtw_keys_sorted:
        if src in out:
            out = out.replace(src, table[src])
    return out


def _post_process(text: str, locale: str) -> str:
    """Apply locale post-processing. locale: 'zh-TW' | 'zh-CN' | 'none'.

    For zh-TW: OpenCC s2twp first (broad cross-strait normalization),
    then zhtw-mcp IT-vocabulary swap (e.g. 主線程→主執行緒, 網關→閘道器).
    """
    if locale == "none" or not text:
        return text
    if locale == "zh-TW":
        cc = _load_opencc()
        out = text
        if cc is not None:
            try:
                out = cc.convert(out)
            except Exception as e:
                log.warning("OpenCC convert failed: %s", e)
        out = _zhtw_swap(out)
        return out
    return text


def _load_model():
    """Lazy-load the ASR model on first request."""
    global _asr
    if _asr is not None:
        return _asr
    log.info("Loading MiMo-V2.5-ASR (precision=%s, root=%s) ...", PRECISION, MODEL_ROOT)
    from mimo_mlx import load_asr  # imported lazily to avoid heavy startup

    MODEL_ROOT.mkdir(parents=True, exist_ok=True)
    t0 = time.perf_counter()
    _asr = load_asr(precision=PRECISION, download=True, local_root=MODEL_ROOT)
    log.info("Model loaded in %.1fs", time.perf_counter() - t0)
    return _asr


@asynccontextmanager
async def lifespan(app: FastAPI):
    if os.environ.get("MIMO_PRELOAD", "0") == "1":
        _load_model()
    yield


app = FastAPI(title="MiMo-V2.5-ASR", version="0.1.0", lifespan=lifespan)


@app.get("/v1/health")
def health():
    return {
        "status": "ok",
        "model_loaded": _asr is not None,
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
    model: Optional[str] = Form(None),  # accepted but ignored (whisper-compat)
    response_format: Optional[str] = Form("json"),
    output_locale: Optional[str] = Form(None),  # 'zh-TW' (default) | 'none'
):
    """Whisper-compatible transcription endpoint."""
    asr = _load_model()
    raw = await file.read()
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"

    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(raw)
        tmp_path = Path(tmp.name)

    try:
        # Sanity check + log audio metadata
        try:
            info = sf.info(str(tmp_path))
            log.info(
                "Transcribe: %s (%.1fs, %d Hz, %d ch, %s)",
                file.filename, info.duration, info.samplerate, info.channels, info.format,
            )
        except Exception as e:
            log.warning("sf.info failed (%s) — passing file as-is", e)

        lang = (language or DEFAULT_LANGUAGE).lower()
        if lang not in ("auto", "zh", "en"):
            log.warning("Unknown language %r → auto", lang)
            lang = "auto"

        t0 = time.perf_counter()
        raw_text = asr.transcribe(str(tmp_path), language=lang)
        asr_elapsed = time.perf_counter() - t0

        # Post-process: simplified → traditional Taiwan (default)
        locale = (output_locale or "zh-TW").lower()
        if locale == "zh-tw": locale = "zh-TW"
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
        try:
            tmp_path.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="info")
