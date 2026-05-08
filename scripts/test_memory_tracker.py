"""Unit tests for MemoryTracker — focus on snapshot TTL cache.

Background: per-request transcribe finally block called snapshot() which spawned
`vmmap` subprocess. On macOS for big processes this took 1-2s per call, doubling
or tripling user-perceived ASR latency. TTL cache must keep hot path subprocess-free.

Run:
    PYTHONPATH=. python3 scripts/test_memory_tracker.py
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from engine.memory import MemoryTracker, DEFAULT_SNAPSHOT_TTL_S


class _CountingTracker(MemoryTracker):
    """MemoryTracker that counts how many times each underlying probe was called."""

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self.phys_calls = 0
        self.rss_calls = 0
        self.metal_active_calls = 0
        self.metal_cache_calls = 0

    def phys_mb(self):
        self.phys_calls += 1
        return 1234.5  # fake — avoid actual vmmap subprocess

    def rss_mb(self):
        self.rss_calls += 1
        return 100.0

    def metal_active_mb(self):
        self.metal_active_calls += 1
        return 50.0

    def metal_cache_mb(self):
        self.metal_cache_calls += 1
        return 5.0


def assert_eq(actual, expected, msg):
    assert actual == expected, f"{msg}: expected {expected}, got {actual}"


def test_first_call_invokes_probes():
    t = _CountingTracker()
    snap = t.snapshot()
    assert_eq(t.phys_calls, 1, "first snapshot calls phys_mb once")
    assert_eq(t.rss_calls, 1, "first snapshot calls rss_mb once")
    assert_eq(snap["phys_mb"], 1234.5, "first snapshot returns phys_mb value")


def test_second_call_within_ttl_uses_cache():
    t = _CountingTracker(snapshot_ttl_s=10.0)
    t.snapshot()  # warm cache
    t.snapshot()
    t.snapshot()
    t.snapshot()
    assert_eq(t.phys_calls, 1, "subsequent calls within TTL hit cache")
    assert_eq(t.rss_calls, 1, "subsequent calls within TTL hit cache")
    assert_eq(t.metal_active_calls, 1, "subsequent calls within TTL hit cache")


def test_call_after_ttl_refreshes():
    t = _CountingTracker(snapshot_ttl_s=0.05)  # 50ms TTL
    t.snapshot()
    time.sleep(0.06)
    t.snapshot()
    assert_eq(t.phys_calls, 2, "call after TTL expires re-invokes probes")


def test_fresh_kw_bypasses_cache():
    t = _CountingTracker(snapshot_ttl_s=10.0)
    t.snapshot()
    t.snapshot(fresh=True)
    t.snapshot(fresh=True)
    assert_eq(t.phys_calls, 3, "fresh=True always invokes probes")


def test_default_ttl_is_five_seconds():
    assert_eq(DEFAULT_SNAPSHOT_TTL_S, 5.0, "default TTL is 5s")


def test_cached_dict_identity():
    """Same cached snapshot reference returned (proves cache hit, no rebuild)."""
    t = _CountingTracker(snapshot_ttl_s=10.0)
    s1 = t.snapshot()
    s2 = t.snapshot()
    assert s1 is s2, "cached snapshot returns same dict reference"


def test_snapshot_hot_path_overhead_under_1ms():
    """Per-request transcribe finally must not pay vmmap. Verify cache hit < 1ms."""
    t = _CountingTracker(snapshot_ttl_s=10.0)
    t.snapshot()  # warm cache
    n = 1000
    start = time.perf_counter()
    for _ in range(n):
        t.snapshot()
    elapsed_ms = (time.perf_counter() - start) * 1000
    avg_ms = elapsed_ms / n
    assert avg_ms < 0.1, f"cached snapshot avg {avg_ms:.4f}ms exceeds 0.1ms budget"
    assert_eq(t.phys_calls, 1, "1000 cached calls should not re-invoke probes")


def test_different_pids_separate_state():
    """Per-instance cache; not global."""
    t1 = _CountingTracker()
    t2 = _CountingTracker()
    t1.snapshot()
    assert_eq(t2.phys_calls, 0, "t2 cache untouched by t1.snapshot()")
    t2.snapshot()
    assert_eq(t1.phys_calls, 1, "t1 unchanged by t2.snapshot()")
    assert_eq(t2.phys_calls, 1, "t2 invoked once after own snapshot()")


def main():
    tests = [
        test_first_call_invokes_probes,
        test_second_call_within_ttl_uses_cache,
        test_call_after_ttl_refreshes,
        test_fresh_kw_bypasses_cache,
        test_default_ttl_is_five_seconds,
        test_cached_dict_identity,
        test_snapshot_hot_path_overhead_under_1ms,
        test_different_pids_separate_state,
    ]
    failed = 0
    for fn in tests:
        try:
            fn()
            print(f"  PASS  {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL  {fn.__name__}: {e}")
        except Exception as e:
            failed += 1
            print(f"  ERR   {fn.__name__}: {type(e).__name__}: {e}")
    print()
    if failed:
        print(f"FAILED {failed}/{len(tests)}")
        sys.exit(1)
    print(f"OK {len(tests)}/{len(tests)} tests passed")


if __name__ == "__main__":
    main()
