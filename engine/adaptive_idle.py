"""AdaptiveIdleWindow — stepped idle ladder with hard ceiling.

Designed for high-frequency use cases on hosts with adequate RAM (e.g.
36 GB). Default ladder: 3 / 7 / 15 min; hard ceiling: 30 min.

Behavior:
    on_use():
        - First use ever: stay at level 1, record timestamp.
        - Subsequent use within current_window_seconds: level += 1 (cap at top).
        - Subsequent use after current_window_seconds: level = 1.

    should_evict():
        - True if time_since_use > current_window_seconds, OR
        - True if time_since_use > hard_ceiling_seconds (always wins).

    reset():
        - level = 1, last_use_t = None.
        - Caller invokes after evict completes.
"""

from __future__ import annotations

import time
from typing import Optional, Sequence


class AdaptiveIdleWindow:
    DEFAULT_LADDER: Sequence[float] = (180.0, 420.0, 900.0)
    DEFAULT_HARD_CEILING: float = 1800.0

    def __init__(
        self,
        ladder_seconds: Sequence[float] = DEFAULT_LADDER,
        hard_ceiling_seconds: float = DEFAULT_HARD_CEILING,
    ) -> None:
        ladder = tuple(float(s) for s in ladder_seconds)
        if not ladder:
            raise ValueError("ladder_seconds must be non-empty")
        if any(s <= 0 for s in ladder):
            raise ValueError("ladder_seconds must all be positive")
        if list(ladder) != sorted(ladder):
            raise ValueError("ladder_seconds must be ascending")
        if hard_ceiling_seconds < ladder[-1]:
            raise ValueError(
                f"hard_ceiling ({hard_ceiling_seconds}) must be >= top ladder rung ({ladder[-1]})"
            )
        self._ladder: Sequence[float] = ladder
        self._hard_ceiling: float = float(hard_ceiling_seconds)
        self._level: int = 1
        self._last_use_t: Optional[float] = None

    @property
    def level(self) -> int:
        return self._level

    @property
    def current_window_seconds(self) -> float:
        return self._ladder[self._level - 1]

    @property
    def hard_ceiling_seconds(self) -> float:
        return self._hard_ceiling

    @property
    def last_use_t(self) -> Optional[float]:
        return self._last_use_t

    def time_since_use(self, now_t: Optional[float] = None) -> float:
        if self._last_use_t is None:
            return float("inf")
        if now_t is None:
            now_t = time.monotonic()
        return now_t - self._last_use_t

    def on_use(self, now_t: Optional[float] = None) -> None:
        if now_t is None:
            now_t = time.monotonic()
        if self._last_use_t is not None:
            elapsed = now_t - self._last_use_t
            if elapsed <= self.current_window_seconds:
                self._level = min(len(self._ladder), self._level + 1)
            else:
                self._level = 1
        self._last_use_t = now_t

    def should_evict(self, now_t: Optional[float] = None) -> bool:
        if self._last_use_t is None:
            return False
        elapsed = self.time_since_use(now_t)
        if elapsed > self._hard_ceiling:
            return True
        return elapsed > self.current_window_seconds

    def reset(self) -> None:
        self._level = 1
        self._last_use_t = None

    def status(self) -> dict:
        return {
            "level": self._level,
            "current_window_seconds": self.current_window_seconds,
            "hard_ceiling_seconds": self._hard_ceiling,
            "ladder_seconds": list(self._ladder),
            "time_since_use_s": self.time_since_use() if self._last_use_t is not None else None,
        }
