"""Assertion tests: MLX inference is offloaded off the asyncio event loop.

Covers S3.1 — the ASR engine must run blocking `asr.transcribe` in a dedicated
single-thread executor so `/v1/health` stays responsive while a transcription
is in flight, and concurrent transcriptions must be serialized.

A real uvicorn server is spun up on a random port in a background thread. That
is deliberate: an in-process ASGITransport client shares the same event loop as
the test driver, so if the handler blocks the loop the test's own awaits block
too — making the "health during in-flight inference" case impossible to observe.
A separate server thread + a blocking client from the main thread reproduces the
live gateway probe faithfully.

Run from repo root:
    PYTHONPATH=. /Users/shiun/Documents/voice-input-mimo/server/.venv/bin/python \\
        scripts/test_engine_transcribe_offload.py
"""

from __future__ import annotations

import contextlib
import io
import os
import socket
import sys
import threading
import time
import wave

# Neutralize import-time side effects before loading the server module: no Qwen
# poll loop (would hit 127.0.0.1:8082) and no eager warmup (would load the real
# model). Tests inject a fake model directly.
os.environ.setdefault("ENGINE_QWEN_ENABLE", "0")
os.environ.setdefault("ENGINE_PRELOAD", "0")
os.environ.setdefault("MIMO_PRELOAD", "0")

import httpx
import uvicorn

import engine.server as srv

HEALTH_BUDGET_S = 2.0


def _wav_bytes(seconds: float = 1.0, sr: int = 16000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"\x00\x00" * int(sr * seconds))
    return buf.getvalue()


WAV = _wav_bytes()
FILES = {"file": ("audio.wav", WAV, "audio/wav")}


class FakeASR:
    """Stub model: blocking transcribe that records thread + timing per call."""

    def __init__(self, delay: float = 0.0, raise_exc: bool = False) -> None:
        self._delay = delay
        self._raise_exc = raise_exc
        self.calls: list[dict] = []
        self._lock = threading.Lock()

    def transcribe(self, path: str, language: str = "auto") -> str:
        enter = time.perf_counter()
        thread = threading.current_thread()
        if self._delay:
            time.sleep(self._delay)
        record = {
            "enter": enter,
            "exit": time.perf_counter(),
            "thread_name": thread.name,
            "thread_id": thread.ident,
        }
        with self._lock:
            self.calls.append(record)
        if self._raise_exc:
            raise RuntimeError("boom from fake transcribe")
        return "fake transcript"


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


@contextlib.contextmanager
def running_server(port: int):
    config = uvicorn.Config(
        srv.app, host="127.0.0.1", port=port, log_level="warning", lifespan="on"
    )
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{port}"
    deadline = time.time() + 15
    while time.time() < deadline and not server.started:
        time.sleep(0.05)
    if not server.started:
        raise RuntimeError("uvicorn did not start within 15s")
    try:
        yield base
    finally:
        server.should_exit = True
        thread.join(timeout=10)


def test_health_stays_responsive_during_inference(base: str) -> None:
    fake = FakeASR(delay=3.0)
    srv.asr_model._model = fake
    result: dict = {}

    def do_transcribe() -> None:
        r = httpx.post(f"{base}/v1/audio/transcriptions", files=FILES, timeout=15)
        result["status"] = r.status_code

    worker = threading.Thread(target=do_transcribe)
    worker.start()
    time.sleep(0.5)  # let inference get in flight
    t0 = time.perf_counter()
    try:
        health = httpx.get(f"{base}/v1/health", timeout=HEALTH_BUDGET_S + 0.5)
    except httpx.TimeoutException:
        elapsed = time.perf_counter() - t0
        raise AssertionError(
            f"/v1/health blocked >{elapsed:.2f}s while inference in flight"
        )
    elapsed = time.perf_counter() - t0
    assert health.status_code == 200, f"health status {health.status_code}"
    assert elapsed < HEALTH_BUDGET_S, (
        f"/v1/health took {elapsed:.2f}s during inference — event loop blocked"
    )
    worker.join(timeout=15)
    assert result.get("status") == 200, f"transcribe status {result.get('status')}"


def test_concurrent_transcribes_are_serialized(base: str) -> None:
    fake = FakeASR(delay=1.0)
    srv.asr_model._model = fake

    def do_transcribe() -> None:
        httpx.post(f"{base}/v1/audio/transcriptions", files=FILES, timeout=15)

    workers = [threading.Thread(target=do_transcribe) for _ in range(2)]
    for w in workers:
        w.start()
    for w in workers:
        w.join(timeout=15)

    assert len(fake.calls) == 2, f"expected 2 inference calls, got {len(fake.calls)}"
    first, second = sorted(fake.calls, key=lambda c: c["enter"])
    assert first["exit"] <= second["enter"] + 0.02, (
        "inference sections overlapped — transcribes not serialized "
        f"(first exits {first['exit']:.3f}, second enters {second['enter']:.3f})"
    )


def test_inference_runs_on_dedicated_single_thread(base: str) -> None:
    fake = FakeASR(delay=0.2)
    srv.asr_model._model = fake

    for _ in range(3):
        r = httpx.post(f"{base}/v1/audio/transcriptions", files=FILES, timeout=15)
        assert r.status_code == 200, f"transcribe status {r.status_code}"

    assert len(fake.calls) == 3
    names = {c["thread_name"] for c in fake.calls}
    ids = {c["thread_id"] for c in fake.calls}
    assert all(n.startswith("mlx-infer") for n in names), (
        f"inference ran off the dedicated executor: thread names={names}"
    )
    assert len(ids) == 1, f"inference used >1 thread: {ids}"


def test_executor_exception_propagates_as_500(base: str) -> None:
    srv.asr_model._model = FakeASR(raise_exc=True)
    r = httpx.post(f"{base}/v1/audio/transcriptions", files=FILES, timeout=15)
    assert r.status_code == 500, (
        f"executor exception not propagated as 500 (got {r.status_code}) — "
        "worker-thread errors must not be silently swallowed"
    )


def test_evict_serialized_with_inference(base: str) -> None:
    """CRITICAL regression: /admin/evict must wait for an in-flight inference and
    run its Metal trim on the dedicated inference thread (never racing it)."""
    fake = FakeASR(delay=2.0)
    srv.asr_model._model = fake
    trim_threads: list[str] = []
    orig_trim = srv.tracker.trim_metal_cache

    def spy_trim() -> None:
        trim_threads.append(threading.current_thread().name)
        orig_trim()

    srv.tracker.trim_metal_cache = spy_trim
    try:
        worker = threading.Thread(
            target=lambda: httpx.post(
                f"{base}/v1/audio/transcriptions", files=FILES, timeout=15
            )
        )
        worker.start()
        time.sleep(0.4)  # let the inference take the lock first
        t0 = time.perf_counter()
        r = httpx.post(f"{base}/admin/evict", timeout=15)
        evict_elapsed = time.perf_counter() - t0
        assert r.status_code == 200, f"/admin/evict status {r.status_code}"
        assert evict_elapsed > 1.0, (
            f"/admin/evict returned in {evict_elapsed:.2f}s — not serialized "
            "behind the ~2s in-flight inference"
        )
        worker.join(timeout=15)
        assert trim_threads, "Metal trim never ran during eviction"
        assert all(n.startswith("mlx-infer") for n in trim_threads), (
            f"Metal trim ran off the inference thread: {trim_threads}"
        )
    finally:
        del srv.tracker.trim_metal_cache


def test_post_work_runs_on_dedicated_thread(base: str) -> None:
    """post-response trim + snapshot must run on the dedicated inference thread."""
    srv.asr_model._model = FakeASR(delay=0.05)
    threads: list[str] = []
    orig = srv._collect_post_metrics

    def spy() -> dict:
        threads.append(threading.current_thread().name)
        return orig()

    srv._collect_post_metrics = spy
    try:
        r = httpx.post(f"{base}/v1/audio/transcriptions", files=FILES, timeout=15)
        assert r.status_code == 200, f"transcribe status {r.status_code}"
        deadline = time.time() + 5
        while not threads and time.time() < deadline:
            time.sleep(0.05)
        assert threads, "post-response housekeeping never ran"
        assert all(n.startswith("mlx-infer") for n in threads), (
            f"post-response trim/snapshot ran off the inference thread: {threads}"
        )
    finally:
        srv._collect_post_metrics = orig


def main() -> int:
    tests = [
        test_health_stays_responsive_during_inference,
        test_concurrent_transcribes_are_serialized,
        test_inference_runs_on_dedicated_single_thread,
        test_executor_exception_propagates_as_500,
        test_evict_serialized_with_inference,
        test_post_work_runs_on_dedicated_thread,
    ]
    failed: list[tuple] = []
    with running_server(_free_port()) as base:
        for t in tests:
            try:
                t(base)
                print(f"[PASS] {t.__name__}")
            except AssertionError as e:
                failed.append((t.__name__, str(e) or "AssertionError"))
                print(f"[FAIL] {t.__name__}: {e}")
            except Exception as e:  # noqa: BLE001
                failed.append((t.__name__, f"{type(e).__name__}: {e}"))
                print(f"[ERROR] {t.__name__}: {type(e).__name__}: {e}")
            finally:
                srv.asr_model._model = None
    print(f"\n{len(tests) - len(failed)}/{len(tests)} passed")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
