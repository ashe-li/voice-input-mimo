"""RemoteQwenCacheManager — adaptive idle for remote Rapid-MLX Qwen.

Rapid-MLX provides no in-process model unload. Best-effort eviction:
    POST /v1/cache/clear → releases prompt/prefix KV cache (~1.4 GB max).

Use detection (no app-side cooperation required):
    GET /v1/status → root.total_requests_processed (monotonic counter,
    +1 per request) is the primary signal.
    Secondary fallback: cache.evictions / cache.current_memory_mb change
    (only fire when prefix cache is mutated, which is sparse — once cache
    fills and steady-states, evictions/cache_mb plateau even under load).
    Any of the three changing between polls is treated as a "use" signal.

Behavior:
    - Poll every poll_interval seconds.
    - On use detected: idle_window.on_use().
    - On idle expired: POST /v1/cache/clear, idle_window.reset().
    - Qwen unreachable: log once and skip until it comes back.
"""

from __future__ import annotations

import asyncio
import json
import logging
import urllib.error
import urllib.request
from typing import Optional

from engine.adaptive_idle import AdaptiveIdleWindow

log = logging.getLogger("engine.qwen_remote")


class RemoteQwenCacheManager:
    def __init__(
        self,
        base_url: str,
        idle_window: AdaptiveIdleWindow,
        poll_interval: float = 5.0,
    ) -> None:
        self._base_url: str = base_url.rstrip("/")
        self._idle_window: AdaptiveIdleWindow = idle_window
        self._poll_interval: float = float(poll_interval)
        self._last_evictions: Optional[int] = None
        self._last_cache_mb: Optional[float] = None
        self._last_total_requests: Optional[int] = None
        self._reachable: bool = True
        self._cache_clears_done: int = 0
        self._uses_observed: int = 0

    @property
    def base_url(self) -> str:
        return self._base_url

    @property
    def idle_window(self) -> AdaptiveIdleWindow:
        return self._idle_window

    @staticmethod
    def _sync_get_json(url: str, timeout: float = 3.0) -> Optional[dict]:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read())

    @staticmethod
    def _sync_post(url: str, timeout: float = 5.0) -> None:
        req = urllib.request.Request(url, method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp.read()

    async def _get_status(self) -> Optional[dict]:
        url = f"{self._base_url}/v1/status"
        try:
            return await asyncio.to_thread(self._sync_get_json, url)
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError) as e:
            log.debug(f"GET {url} failed: {type(e).__name__}: {e}")
            return None
        except Exception as e:
            log.warning(f"GET {url} unexpected error: {type(e).__name__}: {e}")
            return None

    async def _post_cache_clear(self) -> bool:
        url = f"{self._base_url}/v1/cache/clear"
        try:
            await asyncio.to_thread(self._sync_post, url)
            return True
        except Exception as e:
            log.warning(f"POST {url} failed: {type(e).__name__}: {e}")
            return False

    async def force_cache_clear(self) -> bool:
        ok = await self._post_cache_clear()
        if ok:
            self._cache_clears_done += 1
            self._idle_window.reset()
            self._last_evictions = None
            self._last_cache_mb = None
            self._last_total_requests = None
            log.info(f"qwen force cache_clear OK ({self._cache_clears_done} total)")
        return ok

    def _detect_use(self, evictions: int, cache_mb: float, total_requests: int) -> bool:
        if (
            self._last_evictions is None
            or self._last_cache_mb is None
            or self._last_total_requests is None
        ):
            return False
        if total_requests != self._last_total_requests:
            return True
        if evictions != self._last_evictions:
            return True
        return abs(cache_mb - self._last_cache_mb) > 1.0

    async def poll_loop(self) -> None:
        log.info(
            f"qwen poll_loop started (base={self._base_url}, "
            f"poll_interval={self._poll_interval}s, "
            f"ladder={self._idle_window.status()['ladder_seconds']}, "
            f"hard_ceiling={self._idle_window.hard_ceiling_seconds:.0f}s)"
        )
        try:
            while True:
                await asyncio.sleep(self._poll_interval)
                status = await self._get_status()
                if status is None:
                    if self._reachable:
                        log.warning(
                            f"qwen unreachable at {self._base_url} — "
                            f"skipping idle management until it returns"
                        )
                    self._reachable = False
                    continue
                if not self._reachable:
                    log.info(f"qwen reachable again at {self._base_url}")
                    self._reachable = True

                cache = status.get("cache", {}) or {}
                evictions = int(cache.get("evictions", 0) or 0)
                cache_mb = float(cache.get("current_memory_mb", 0.0) or 0.0)
                total_requests = int(status.get("total_requests_processed", 0) or 0)

                if self._detect_use(evictions, cache_mb, total_requests):
                    self._idle_window.on_use()
                    self._uses_observed += 1
                    log.debug(
                        f"qwen use detected: total_requests {self._last_total_requests}→{total_requests}, "
                        f"evictions {self._last_evictions}→{evictions}, "
                        f"cache_mb {self._last_cache_mb:.0f}→{cache_mb:.0f}, "
                        f"level={self._idle_window.level} "
                        f"window={self._idle_window.current_window_seconds:.0f}s"
                    )

                self._last_evictions = evictions
                self._last_cache_mb = cache_mb
                self._last_total_requests = total_requests

                if self._idle_window.should_evict():
                    log.info(
                        f"qwen idle expired (level={self._idle_window.level}, "
                        f"time_since_use={self._idle_window.time_since_use():.0f}s, "
                        f"cache_mb={cache_mb:.0f}) — cache_clear"
                    )
                    if await self._post_cache_clear():
                        self._cache_clears_done += 1
                        self._idle_window.reset()
                        refreshed = await self._get_status()
                        if refreshed is not None:
                            new_cache = refreshed.get("cache", {}) or {}
                            self._last_evictions = int(new_cache.get("evictions", 0) or 0)
                            self._last_cache_mb = float(new_cache.get("current_memory_mb", 0.0) or 0.0)
                            self._last_total_requests = int(refreshed.get("total_requests_processed", 0) or 0)
        except asyncio.CancelledError:
            log.info("qwen poll_loop cancelled")
            raise
        except Exception:
            log.exception("qwen poll_loop crashed")
            raise

    def status(self) -> dict:
        return {
            "base_url": self._base_url,
            "reachable": self._reachable,
            "poll_interval_s": self._poll_interval,
            "cache_clears_done": self._cache_clears_done,
            "uses_observed": self._uses_observed,
            "last_observed": {
                "evictions": self._last_evictions,
                "cache_mb": self._last_cache_mb,
                "total_requests": self._last_total_requests,
            },
            "idle_window": self._idle_window.status(),
        }
