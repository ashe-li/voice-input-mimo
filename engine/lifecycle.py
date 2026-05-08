"""LazyModel — load on first use, evict after configurable idle window.

Backed by asyncio.Lock so concurrent get() and evict() don't race.

Two idle modes:
    - fixed: pass `idle_seconds=N` for a static threshold (legacy Phase 1).
    - adaptive: pass `idle_window=AdaptiveIdleWindow(...)` for stepped ladder.

Usage:
    asr = LazyModel(
        name="asr",
        loader=lambda: load_asr(precision="int4"),
        idle_window=AdaptiveIdleWindow(),  # 3/7/15 min default
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

from engine.adaptive_idle import AdaptiveIdleWindow

log = logging.getLogger("engine.lifecycle")

Loader = Union[Callable[[], Any], Callable[[], Awaitable[Any]]]
EvictHook = Union[Callable[[], None], Callable[[], Awaitable[None]]]


class LazyModel:
    def __init__(
        self,
        name: str,
        loader: Loader,
        idle_seconds: Optional[float] = None,
        idle_window: Optional[AdaptiveIdleWindow] = None,
        on_evict: Optional[EvictHook] = None,
    ) -> None:
        if idle_seconds is None and idle_window is None:
            raise ValueError("LazyModel requires idle_seconds or idle_window")
        if idle_seconds is not None and idle_window is not None:
            raise ValueError("LazyModel: pick one of idle_seconds / idle_window, not both")
        self._name = name
        self._loader = loader
        self._idle_seconds = idle_seconds
        self._idle_window = idle_window
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
    def idle_seconds(self) -> Optional[float]:
        return self._idle_seconds

    @property
    def idle_window(self) -> Optional[AdaptiveIdleWindow]:
        return self._idle_window

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
            now_t = time.monotonic()
            self._last_used = now_t
            if self._idle_window is not None:
                self._idle_window.on_use(now_t)
                log.debug(
                    f"[{self._name}] idle level={self._idle_window.level} "
                    f"window={self._idle_window.current_window_seconds:.0f}s"
                )
            return self._model

    async def warmup(self) -> None:
        await self.get()

    async def evict(self) -> None:
        async with self._lock:
            if self._model is None:
                return
            elapsed = self.time_since_use()
            elapsed_str = f"{elapsed:.1f}s" if elapsed != float("inf") else "never used"
            mode_str = (
                f"adaptive L{self._idle_window.level}/{self._idle_window.current_window_seconds:.0f}s"
                if self._idle_window is not None
                else f"fixed {self._idle_seconds}s"
            )
            log.info(f"[{self._name}] evicting (idle for {elapsed_str}, mode={mode_str})")
            self._model = None
            self._last_used = 0.0
            if self._idle_window is not None:
                self._idle_window.reset()
        gc.collect()
        if self._on_evict is not None:
            res = self._on_evict()
            if asyncio.iscoroutine(res):
                await res

    def _expired(self) -> bool:
        if not self.is_loaded:
            return False
        if self._idle_window is not None:
            return self._idle_window.should_evict()
        return self.time_since_use() >= (self._idle_seconds or float("inf"))

    async def idle_check_loop(self, check_interval: float = 5.0) -> None:
        if self._idle_window is not None:
            log.info(
                f"[{self._name}] idle_check_loop started "
                f"(adaptive ladder={self._idle_window.status()['ladder_seconds']}, "
                f"hard_ceiling={self._idle_window.hard_ceiling_seconds:.0f}s, "
                f"check_interval={check_interval}s)"
            )
        else:
            log.info(
                f"[{self._name}] idle_check_loop started "
                f"(fixed idle_threshold={self._idle_seconds}s, check_interval={check_interval}s)"
            )
        try:
            while True:
                await asyncio.sleep(check_interval)
                if self._expired():
                    await self.evict()
        except asyncio.CancelledError:
            log.info(f"[{self._name}] idle_check_loop cancelled")
            raise
        except Exception:
            log.exception(f"[{self._name}] idle_check_loop crashed")
            raise

    def status(self) -> dict:
        d: dict = {
            "name": self._name,
            "loaded": self.is_loaded,
            "time_since_use_s": self.time_since_use() if self._last_used else None,
        }
        if self._idle_window is not None:
            d["mode"] = "adaptive"
            d["idle"] = self._idle_window.status()
        else:
            d["mode"] = "fixed"
            d["idle_seconds_threshold"] = self._idle_seconds
        return d
