"""LazyModel — load on first use, evict after configurable idle window.

Backed by asyncio.Lock so concurrent get() and evict() don't race.

Usage:
    asr = LazyModel(
        name="asr",
        loader=lambda: load_asr(precision="int4"),
        idle_seconds=15,
        on_evict=memory_tracker.trim_metal_cache,
    )

    async def transcribe(audio):
        model = await asr.get()  # load if needed; reset idle timer
        return model.transcribe(audio)

    # background:
    asyncio.create_task(asr.idle_check_loop())
"""

from __future__ import annotations

import asyncio
import gc
import logging
import time
from typing import Any, Awaitable, Callable, Optional, Union

log = logging.getLogger("engine.lifecycle")

Loader = Union[Callable[[], Any], Callable[[], Awaitable[Any]]]
EvictHook = Union[Callable[[], None], Callable[[], Awaitable[None]]]


class LazyModel:
    def __init__(
        self,
        name: str,
        loader: Loader,
        idle_seconds: float = 30.0,
        on_evict: Optional[EvictHook] = None,
    ) -> None:
        self._name = name
        self._loader = loader
        self._idle_seconds = idle_seconds
        self._on_evict = on_evict
        self._model: Any = None
        self._last_used: float = 0.0
        self._lock = asyncio.Lock()

    @property
    def name(self) -> str:
        return self._name

    @property
    def is_loaded(self) -> bool:
        return self._model is not None

    @property
    def idle_seconds(self) -> float:
        return self._idle_seconds

    def time_since_use(self) -> float:
        if self._last_used == 0.0:
            return float("inf")
        return time.monotonic() - self._last_used

    async def get(self) -> Any:
        async with self._lock:
            if self._model is None:
                t0 = time.perf_counter()
                log.info(f"[{self._name}] cold load …")
                result = self._loader()
                if asyncio.iscoroutine(result):
                    result = await result
                self._model = result
                log.info(f"[{self._name}] loaded in {time.perf_counter() - t0:.2f}s")
            self._last_used = time.monotonic()
            return self._model

    async def warmup(self) -> None:
        await self.get()

    async def evict(self) -> None:
        async with self._lock:
            if self._model is None:
                return
            elapsed = self.time_since_use()
            elapsed_str = f"{elapsed:.1f}s" if elapsed != float("inf") else "never used"
            log.info(f"[{self._name}] evicting (idle for {elapsed_str})")
            self._model = None
            self._last_used = 0.0
        gc.collect()
        if self._on_evict is not None:
            res = self._on_evict()
            if asyncio.iscoroutine(res):
                await res

    async def idle_check_loop(self, check_interval: float = 5.0) -> None:
        log.info(
            f"[{self._name}] idle_check_loop started "
            f"(idle_threshold={self._idle_seconds}s, check_interval={check_interval}s)"
        )
        try:
            while True:
                await asyncio.sleep(check_interval)
                if self.is_loaded and self.time_since_use() >= self._idle_seconds:
                    await self.evict()
        except asyncio.CancelledError:
            log.info(f"[{self._name}] idle_check_loop cancelled")
            raise
        except Exception:
            log.exception(f"[{self._name}] idle_check_loop crashed")
            raise

    def status(self) -> dict:
        return {
            "name": self._name,
            "loaded": self.is_loaded,
            "idle_seconds_threshold": self._idle_seconds,
            "time_since_use_s": self.time_since_use() if self._last_used else None,
        }
