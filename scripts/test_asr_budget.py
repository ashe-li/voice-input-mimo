"""Unit tests for engine/asr_budget.py — duration-scaled ASR decode cap.

Covers: cap math (floor / scaling / hard ceiling / bad durations), context
clamp, the generate() shadow on a real `mlx.nn.Module` (cap forced, stats
recorded, restored on success AND on exception), the fake-ASR fallback, and
the engine handler surfacing the stats in the HTTP response.

Run from repo root (pytest-collectable, or standalone):
    PYTHONPATH=. <main-checkout>/server/.venv/bin/python \\
        -m pytest scripts/test_asr_budget.py -q
    PYTHONPATH=. <main-checkout>/server/.venv/bin/python \\
        scripts/test_asr_budget.py
"""

from __future__ import annotations

import asyncio
import io
import math
import os
import sys
import tempfile
import wave
from types import SimpleNamespace

os.environ.setdefault("ENGINE_QWEN_ENABLE", "0")
os.environ.setdefault("ENGINE_PRELOAD", "0")
os.environ.setdefault("MIMO_PRELOAD", "0")
# Keep engine.log / transcribe.jsonl writes out of the live log directory.
os.environ.setdefault("ENGINE_LOG_DIR", tempfile.mkdtemp(prefix="asr-budget-test-"))

import mlx.core as mx
import mlx.nn as nn

from engine import asr_budget as ab

GROUP = 4
STOP = 7
BUDGET = ab.DecodeBudget(steps_per_second=6.0, overhead=64, floor=256, hard_cap=3072)


class FakeMimoModel(nn.Module):
    """Real mlx Module so the shadow/restore exercises Module.__setattr__ rules.

    generate() appends `emit` steps of GROUP columns, stopping early on STOP when
    `stop_at` is reached — mirrors mimo_mlx's loop/shape contract.
    """

    def __init__(self, emit: int, stop_at: int | None = None, boom: bool = False):
        super().__init__()
        self.group_size = GROUP
        self.config = SimpleNamespace(group_size=GROUP, max_position_embeddings=8192)
        self._emit = emit
        self._stop_at = stop_at
        self._boom = boom
        self.seen_caps: list[int] = []

    def generate(self, input_ids, max_new_tokens=256, stop_tokens=None, **_kw):
        self.seen_caps.append(max_new_tokens)
        if self._boom:
            raise RuntimeError("decode exploded")
        steps = min(self._emit, max_new_tokens)
        last = 1
        if self._stop_at is not None and self._stop_at <= steps:
            steps, last = self._stop_at, STOP
        body = mx.ones((1, 2, steps * GROUP), dtype=mx.int32)
        if steps:
            body[:, 0, -1] = last
        return mx.concatenate([input_ids, body], axis=-1)


class FakeAsr:
    def __init__(self, model):
        self.model = model

    def transcribe(self, path, language="auto"):
        prompt = mx.zeros((1, 2, 40 * GROUP), dtype=mx.int32)
        self.model.generate(prompt, max_new_tokens=256, stop_tokens=[STOP])
        return f"text:{path}:{language}"


# ---- compute_max_new_tokens -------------------------------------------------

def test_cap_never_below_old_256_for_short_audio() -> None:
    for secs in (0.5, 5.0, 20.0, 31.0):
        assert ab.compute_max_new_tokens(secs, BUDGET) == 256


def test_cap_scales_with_duration() -> None:
    assert ab.compute_max_new_tokens(60.0, BUDGET) == 360 + 64  # LMC window > 256
    assert ab.compute_max_new_tokens(193.0, BUDGET) == 1158 + 64
    assert ab.compute_max_new_tokens(100.4, BUDGET) == math.ceil(602.4) + 64


def test_cap_has_hard_ceiling() -> None:
    assert ab.compute_max_new_tokens(3600.0, BUDGET) == 3072


def test_cap_unknown_or_bad_duration_falls_back_to_floor() -> None:
    for bad in (None, 0.0, -3.0, float("nan"), float("inf")):
        assert ab.compute_max_new_tokens(bad, BUDGET) == 256


def test_default_budget_used_when_omitted() -> None:
    assert ab.compute_max_new_tokens(None) == ab.DEFAULT_BUDGET.floor


# ---- clamp_to_context -------------------------------------------------------

def test_clamp_keeps_within_context_window() -> None:
    assert ab.clamp_to_context(3000, 6000, 8192) == 2192
    assert ab.clamp_to_context(1000, 1200, 8192) == 1000


def test_clamp_never_below_floor_or_without_limit() -> None:
    assert ab.clamp_to_context(3000, 8100, 8192) == 256
    assert ab.clamp_to_context(200, 9000, 8192) == 200
    assert ab.clamp_to_context(3000, 9000, None) == 3000


# ---- transcribe_with_budget -------------------------------------------------

def test_shadow_forces_cap_and_records_stop() -> None:
    model = FakeMimoModel(emit=900, stop_at=500)
    text, stats = ab.transcribe_with_budget(FakeAsr(model), "a.wav", "zh", 1222)
    assert text == "text:a.wav:zh"
    assert model.seen_caps == [1222]
    assert stats.steps == 500 and stats.stopped is True and stats.hit_cap is False
    assert stats.max_new_tokens == 1222 and stats.requested_max_new_tokens == 1222
    assert stats.prompt_positions == 40


def test_shadow_reports_hit_cap_when_decode_runs_out() -> None:
    model = FakeMimoModel(emit=5000)
    _, stats = ab.transcribe_with_budget(FakeAsr(model), "a.wav", "auto", 300)
    assert stats.steps == 300 and stats.stopped is False and stats.hit_cap is True


def test_stop_exactly_on_last_step_is_not_hit_cap() -> None:
    model = FakeMimoModel(emit=5000, stop_at=300)
    _, stats = ab.transcribe_with_budget(FakeAsr(model), "a.wav", "auto", 300)
    assert stats.steps == 300 and stats.stopped is True and stats.hit_cap is False


def test_shadow_restored_after_success_and_exception() -> None:
    model = FakeMimoModel(emit=10, stop_at=10)
    ab.transcribe_with_budget(FakeAsr(model), "a.wav", "auto", 999)
    assert "generate" not in vars(model), "instance shadow leaked after success"
    assert model.generate.__func__ is FakeMimoModel.generate

    boom = FakeMimoModel(emit=10, boom=True)
    try:
        ab.transcribe_with_budget(FakeAsr(boom), "a.wav", "auto", 999)
        raise AssertionError("exception swallowed")
    except RuntimeError:
        pass
    assert "generate" not in vars(boom), "instance shadow leaked after exception"
    assert boom.generate.__func__ is FakeMimoModel.generate


def test_preexisting_instance_generate_is_restored() -> None:
    model = FakeMimoModel(emit=10, stop_at=10)
    custom = model.generate  # bound method stored as instance attribute
    object.__setattr__(model, "generate", custom)
    ab.transcribe_with_budget(FakeAsr(model), "a.wav", "auto", 999)
    assert vars(model)["generate"] is custom


def test_fallback_without_patchable_model() -> None:
    class Plain:
        def transcribe(self, path, language="auto"):
            return "plain"

    text, stats = ab.transcribe_with_budget(Plain(), "a.wav", "auto", 400)
    assert text == "plain"
    assert stats.steps is None and stats.hit_cap is None
    assert stats.requested_max_new_tokens == 400


def test_helpers_tolerate_odd_models() -> None:
    assert ab._group_size(SimpleNamespace(config=SimpleNamespace(group_size=4))) == 4
    assert ab._group_size(SimpleNamespace()) == 1
    assert ab._context_limit(SimpleNamespace()) is None
    assert ab._last_text_token("not-an-array") is None


def test_log_fields_shape() -> None:
    fields = ab.GenerationStats(requested_max_new_tokens=300, steps=12).as_log_fields()
    assert fields["asr_steps"] == 12 and fields["asr_requested_max_new_tokens"] == 300
    assert set(fields) >= {"asr_hit_cap", "asr_max_new_tokens", "asr_stopped"}


# ---- engine handler wiring ---------------------------------------------------

def _wav_bytes(seconds: float, sr: int = 16000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"\x00\x00" * int(sr * seconds))
    return buf.getvalue()


def test_engine_response_carries_decode_stats() -> None:
    import httpx
    import engine.server as srv

    async def _run() -> dict:
        srv.asr_model._lock = asyncio.Lock()
        model = FakeMimoModel(emit=900, stop_at=50)
        srv.asr_model._model = FakeAsr(model)
        emitted: list = []
        orig_emit = srv.emit_request_jsonl
        srv.emit_request_jsonl = emitted.append
        try:
            async with srv.lifespan(srv.app):
                transport = httpx.ASGITransport(app=srv.app)
                async with httpx.AsyncClient(transport=transport, base_url="http://t") as c:
                    files = {"file": ("a.wav", _wav_bytes(120.0), "audio/wav")}
                    r = await c.post("/v1/audio/transcriptions", files=files)
                srv.asr_model._model = None
        finally:
            srv.emit_request_jsonl = orig_emit
        return {"json": r.json(), "caps": model.seen_caps, "emitted": emitted}

    out = asyncio.run(_run())
    body = out["json"]
    assert out["caps"] == [720 + 64], out["caps"]
    assert body["asr_steps"] == 50 and body["asr_hit_cap"] is False
    assert body["asr_max_new_tokens"] == 784
    assert out["emitted"] and out["emitted"][0]["asr_steps"] == 50


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"[PASS] {t.__name__}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"[FAIL] {t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
