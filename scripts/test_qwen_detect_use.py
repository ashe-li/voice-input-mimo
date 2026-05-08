"""Assertion-based unit tests for RemoteQwenCacheManager._detect_use.

Run from repo root:
    PYTHONPATH=. /Users/shiun/Documents/voice-input-mimo/server/.venv/bin/python \
        scripts/test_qwen_detect_use.py

Background — why these tests exist:
    Original detect_use only watched cache.evictions / cache_mb. Once Qwen's
    prefix cache fills (memory_utilization → 99%) and stabilises, evictions
    stop incrementing and cache_mb plateaus. Engine sees uses_observed=0
    even when 10+ requests are flowing through. Idle ladder never starts
    → cache_clear never fires.

    Fix: also watch root.total_requests_processed (monotonic, +1/request).
"""

from __future__ import annotations

import sys

from engine.adaptive_idle import AdaptiveIdleWindow
from engine.qwen_remote import RemoteQwenCacheManager


def _mgr() -> RemoteQwenCacheManager:
    return RemoteQwenCacheManager(
        base_url="http://127.0.0.1:8082",
        idle_window=AdaptiveIdleWindow(),
    )


def test_first_poll_returns_false() -> None:
    m = _mgr()
    assert m._detect_use(evictions=3, cache_mb=3115.0, total_requests=10) is False


def test_total_requests_increment_detects_use() -> None:
    m = _mgr()
    m._last_evictions = 3
    m._last_cache_mb = 3115.0
    m._last_total_requests = 10
    assert m._detect_use(evictions=3, cache_mb=3115.0, total_requests=11) is True


def test_evictions_change_detects_use() -> None:
    m = _mgr()
    m._last_evictions = 3
    m._last_cache_mb = 3115.0
    m._last_total_requests = 10
    assert m._detect_use(evictions=4, cache_mb=3115.0, total_requests=10) is True


def test_cache_mb_jitter_under_1mb_no_use() -> None:
    m = _mgr()
    m._last_evictions = 3
    m._last_cache_mb = 3115.0
    m._last_total_requests = 10
    assert m._detect_use(evictions=3, cache_mb=3115.5, total_requests=10) is False


def test_cache_mb_jump_over_1mb_detects_use() -> None:
    m = _mgr()
    m._last_evictions = 3
    m._last_cache_mb = 3115.0
    m._last_total_requests = 10
    assert m._detect_use(evictions=3, cache_mb=3120.0, total_requests=10) is True


def test_steady_state_no_evictions_no_cache_change_but_requests_flowing() -> None:
    """Real bug: prefix cache full, evictions/cache_mb stable, requests flowing.

    Old behaviour: detect_use=False → uses_observed stays 0 → idle never starts.
    New behaviour: total_requests delta detects use even when cache plateaued.
    """
    m = _mgr()
    m._last_evictions = 3
    m._last_cache_mb = 3115.97
    m._last_total_requests = 10
    # 5 more requests flow, cache state unchanged (typical post-fill)
    assert m._detect_use(evictions=3, cache_mb=3115.97, total_requests=15) is True


def test_no_change_no_use() -> None:
    m = _mgr()
    m._last_evictions = 3
    m._last_cache_mb = 3115.0
    m._last_total_requests = 10
    assert m._detect_use(evictions=3, cache_mb=3115.0, total_requests=10) is False


def test_status_includes_total_requests() -> None:
    m = _mgr()
    m._last_evictions = 3
    m._last_cache_mb = 3115.0
    m._last_total_requests = 10
    s = m.status()
    assert s["last_observed"]["total_requests"] == 10
    assert s["last_observed"]["evictions"] == 3
    assert s["last_observed"]["cache_mb"] == 3115.0


def main() -> int:
    tests = [
        test_first_poll_returns_false,
        test_total_requests_increment_detects_use,
        test_evictions_change_detects_use,
        test_cache_mb_jitter_under_1mb_no_use,
        test_cache_mb_jump_over_1mb_detects_use,
        test_steady_state_no_evictions_no_cache_change_but_requests_flowing,
        test_no_change_no_use,
        test_status_includes_total_requests,
    ]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"  [OK] {t.__name__}")
        except AssertionError as e:
            print(f"  [FAIL] {t.__name__}: {e}")
            failed += 1
        except Exception as e:
            print(f"  [ERROR] {t.__name__}: {type(e).__name__}: {e}")
            failed += 1
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
