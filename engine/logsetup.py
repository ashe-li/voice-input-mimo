"""Logging setup — file sink + structured JSON line for transcribe events.

Writes to ENGINE_LOG_DIR (default ~/Library/Logs/VoiceInputMimo/):
    engine.log         general engine log (rotating, 10 MB × 5 files)
    transcribe.jsonl   one JSON line per /v1/audio/transcriptions request

Override path via env:
    ENGINE_LOG_DIR
    ENGINE_LOG_LEVEL (default INFO)
    ENGINE_LOG_CONSOLE (default 1; set 0 to silence stderr)
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any, Optional

DEFAULT_LOG_DIR = Path.home() / "Library/Logs/VoiceInputMimo"
DEFAULT_LEVEL = "INFO"
DEFAULT_ROTATE_MAX_BYTES = 10 * 1024 * 1024
DEFAULT_ROTATE_BACKUP_COUNT = 5

_resolved_log_dir: Optional[Path] = None


def resolve_log_dir() -> Path:
    global _resolved_log_dir
    if _resolved_log_dir is not None:
        return _resolved_log_dir
    raw = os.environ.get("ENGINE_LOG_DIR", "").strip()
    path = Path(raw).expanduser() if raw else DEFAULT_LOG_DIR
    path.mkdir(parents=True, exist_ok=True)
    _resolved_log_dir = path
    return path


def setup_logging() -> Path:
    log_dir = resolve_log_dir()
    level_name = os.environ.get("ENGINE_LOG_LEVEL", DEFAULT_LEVEL).upper()
    level = getattr(logging, level_name, logging.INFO)
    console = os.environ.get("ENGINE_LOG_CONSOLE", "1") == "1"

    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")
    root = logging.getLogger()
    root.setLevel(level)

    for handler in list(root.handlers):
        root.removeHandler(handler)

    file_handler = RotatingFileHandler(
        log_dir / "engine.log",
        maxBytes=DEFAULT_ROTATE_MAX_BYTES,
        backupCount=DEFAULT_ROTATE_BACKUP_COUNT,
        encoding="utf-8",
    )
    file_handler.setFormatter(fmt)
    file_handler.setLevel(level)
    root.addHandler(file_handler)

    if console:
        stream_handler = logging.StreamHandler(stream=sys.stderr)
        stream_handler.setFormatter(fmt)
        stream_handler.setLevel(level)
        root.addHandler(stream_handler)

    return log_dir


def emit_request_jsonl(payload: dict[str, Any]) -> None:
    log_dir = resolve_log_dir()
    out = log_dir / "transcribe.jsonl"
    record = {"ts": time.time(), **payload}
    try:
        with open(out, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    except Exception as e:
        logging.getLogger("engine.logsetup").warning(f"failed to write transcribe.jsonl: {e}")
