"""MemoryTracker — process memory + MLX cache helpers.

Primary metric on macOS is `phys_footprint` via `vmmap --summary` (matches
Activity Monitor "Memory" column). psutil RSS is kept as cross-platform
backup; on macOS it misses mmap'd MLX weights and reports a wrong-by-50×
number.

KB pattern: macos-mlx-process-memory-vmmap-not-psutil-rss.md
"""

from __future__ import annotations

import logging
import os
import platform
import subprocess
from typing import Optional

import psutil

log = logging.getLogger("engine.memory")


def _parse_size_to_mb(s: str) -> float:
    s = s.strip()
    if s.endswith("G"):
        return float(s[:-1]) * 1024
    if s.endswith("M"):
        return float(s[:-1])
    if s.endswith("K"):
        return float(s[:-1]) / 1024
    return float(s) / (1024 * 1024)


class MemoryTracker:
    """Process memory + MLX cache observability."""

    def __init__(self, pid: Optional[int] = None) -> None:
        self._pid = pid or os.getpid()
        self._process = psutil.Process(self._pid)

    @property
    def pid(self) -> int:
        return self._pid

    def rss_mb(self) -> float:
        return self._process.memory_info().rss / (1024 * 1024)

    def phys_mb(self) -> Optional[float]:
        if platform.system() != "Darwin":
            return None
        try:
            out = subprocess.check_output(
                ["vmmap", "--summary", str(self._pid)],
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

    def _metal_query(self, name: str) -> Optional[int]:
        """Call mx.<name> first (new MLX API), fall back to mx.metal.<name>."""
        try:
            import mlx.core as mx
        except ImportError:
            return None
        fn = getattr(mx, name, None)
        if fn is None:
            fn = getattr(mx.metal, name, None)
        if fn is None:
            return None
        try:
            return fn()
        except Exception:
            return None

    def metal_active_mb(self) -> Optional[float]:
        v = self._metal_query("get_active_memory")
        return v / (1024 * 1024) if v is not None else None

    def metal_cache_mb(self) -> Optional[float]:
        v = self._metal_query("get_cache_memory")
        return v / (1024 * 1024) if v is not None else None

    def trim_metal_cache(self) -> None:
        try:
            import mlx.core as mx
        except ImportError:
            return
        try:
            mx.metal.clear_cache()
        except Exception as e:
            log.warning(f"trim_metal_cache failed: {e}")

    def set_metal_cache_limit_mb(self, mb: int) -> None:
        try:
            import mlx.core as mx
        except ImportError:
            return
        try:
            mx.metal.set_cache_limit(mb * 1024 * 1024)
            log.info(f"set MLX Metal cache limit to {mb} MB")
        except Exception as e:
            log.warning(f"set_metal_cache_limit failed: {e}")

    def snapshot(self) -> dict:
        return {
            "pid": self._pid,
            "rss_mb": self.rss_mb(),
            "phys_mb": self.phys_mb(),
            "metal_active_mb": self.metal_active_mb(),
            "metal_cache_mb": self.metal_cache_mb(),
        }
