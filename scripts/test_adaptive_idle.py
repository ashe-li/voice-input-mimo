"""Assertion-based unit tests for AdaptiveIdleWindow.

Run from repo root:
    PYTHONPATH=. /Users/shiun/Documents/voice-input-mimo/server/.venv/bin/python \
        scripts/test_adaptive_idle.py
"""

from __future__ import annotations

import sys

from engine.adaptive_idle import AdaptiveIdleWindow


def test_initial_state() -> None:
    w = AdaptiveIdleWindow()
    assert w.level == 1
    assert w.current_window_seconds == 180.0
    assert w.last_use_t is None
    assert not w.should_evict()
    assert w.time_since_use() == float("inf")


def test_first_use_stays_at_l1() -> None:
    w = AdaptiveIdleWindow()
    w.on_use(now_t=100.0)
    assert w.level == 1
    assert w.last_use_t == 100.0


def test_use_within_window_escalates() -> None:
    w = AdaptiveIdleWindow()
    w.on_use(now_t=100.0)
    w.on_use(now_t=200.0)
    assert w.level == 2
    w.on_use(now_t=400.0)
    assert w.level == 3
    w.on_use(now_t=1000.0)
    assert w.level == 3


def test_use_after_window_resets_to_l1() -> None:
    w = AdaptiveIdleWindow()
    w.on_use(now_t=100.0)
    w.on_use(now_t=200.0)
    assert w.level == 2
    w.on_use(now_t=700.0)
    assert w.level == 1


def test_should_evict_when_window_expires() -> None:
    w = AdaptiveIdleWindow()
    w.on_use(now_t=100.0)
    assert not w.should_evict(now_t=200.0)
    assert not w.should_evict(now_t=280.0)
    assert w.should_evict(now_t=281.0)


def test_hard_ceiling_overrides_lower_level() -> None:
    w = AdaptiveIdleWindow(ladder_seconds=(10.0, 30.0, 60.0), hard_ceiling_seconds=100.0)
    w.on_use(now_t=0.0)
    assert w.level == 1
    assert w.current_window_seconds == 10.0
    assert w.should_evict(now_t=11.0)
    w.reset()
    w.on_use(now_t=0.0)
    w.on_use(now_t=5.0)
    w.on_use(now_t=20.0)
    assert w.level == 3
    assert not w.should_evict(now_t=70.0)
    assert w.should_evict(now_t=81.0)


def test_reset_returns_to_l1() -> None:
    w = AdaptiveIdleWindow()
    w.on_use(now_t=0.0)
    w.on_use(now_t=100.0)
    assert w.level == 2
    w.reset()
    assert w.level == 1
    assert w.last_use_t is None
    assert not w.should_evict()


def test_status_shape() -> None:
    w = AdaptiveIdleWindow(ladder_seconds=(180.0, 420.0, 900.0), hard_ceiling_seconds=1800.0)
    s = w.status()
    assert s["level"] == 1
    assert s["current_window_seconds"] == 180.0
    assert s["hard_ceiling_seconds"] == 1800.0
    assert s["ladder_seconds"] == [180.0, 420.0, 900.0]
    assert s["time_since_use_s"] is None
    w.on_use(now_t=0.0)
    w.on_use(now_t=100.0)
    s2 = w.status()
    assert s2["level"] == 2
    assert s2["current_window_seconds"] == 420.0


def test_validation_empty_ladder() -> None:
    try:
        AdaptiveIdleWindow(ladder_seconds=())
    except ValueError:
        return
    raise AssertionError("expected ValueError for empty ladder")


def test_validation_non_positive_ladder() -> None:
    try:
        AdaptiveIdleWindow(ladder_seconds=(0.0, 100.0))
    except ValueError:
        return
    raise AssertionError("expected ValueError for non-positive ladder rung")


def test_validation_unsorted_ladder() -> None:
    try:
        AdaptiveIdleWindow(ladder_seconds=(100.0, 50.0, 200.0))
    except ValueError:
        return
    raise AssertionError("expected ValueError for unsorted ladder")


def test_validation_ceiling_below_top() -> None:
    try:
        AdaptiveIdleWindow(ladder_seconds=(100.0, 200.0, 300.0), hard_ceiling_seconds=200.0)
    except ValueError:
        return
    raise AssertionError("expected ValueError for hard_ceiling below top ladder")


def test_realistic_high_frequency_pattern() -> None:
    """Simulate user doing voice-input every 2 min for 20 min — should reach L3 and stay there."""
    w = AdaptiveIdleWindow()
    t = 0.0
    w.on_use(now_t=t)
    for _ in range(10):
        t += 120.0
        w.on_use(now_t=t)
    assert w.level == 3
    t += 800.0
    assert not w.should_evict(now_t=t)
    t += 200.0
    assert w.should_evict(now_t=t)


def test_realistic_sparse_pattern() -> None:
    """Simulate user with 5 min gap — never escalates above L1, evicts on each gap."""
    w = AdaptiveIdleWindow()
    w.on_use(now_t=0.0)
    assert w.level == 1
    w.on_use(now_t=300.0)
    assert w.level == 1


def main() -> int:
    tests = [t for name, t in sorted(globals().items()) if name.startswith("test_")]
    failed = []
    for t in tests:
        try:
            t()
            print(f"[PASS] {t.__name__}")
        except AssertionError as e:
            failed.append((t.__name__, str(e) or "AssertionError"))
            print(f"[FAIL] {t.__name__}: {e}")
        except Exception as e:
            failed.append((t.__name__, f"{type(e).__name__}: {e}"))
            print(f"[ERROR] {t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(tests) - len(failed)}/{len(tests)} passed")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
