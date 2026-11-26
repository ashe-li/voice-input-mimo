"""Duration-scaled decode budget for MiMo ASR.

mimo_mlx's `MimoASR.transcribe()` calls `self.model.generate(...,
max_new_tokens=256, ...)` with the cap hard-coded. One generate step emits one
text token, so 256 steps cover roughly 60-90 s of speech; anything longer is cut
mid-sentence. The package is a wheel inside the venv (not editable, no source
repo), so the fix lives here: for the duration of one transcription we shadow
`asr.model.generate` with a wrapper that overrides `max_new_tokens` and records
how many steps actually ran.

Why not one big constant: greedy decoding that falls into a repetition loop runs
all the way to the cap while holding `infer_lock`, so the next utterance waits.
The cap therefore scales with audio length, with a floor (never below the old
256, so short windows such as LMC's 60 s chunks never regress) and a hard
ceiling.

Coefficient (from 2858 historical transcribe.jsonl rows, re-tokenized): speech
runs at p50 ~2.9 and p99 ~4.5 text tokens/s; the fastest observed clip is 5.7
tokens/s. Re-tokenized text slightly undercounts steps (stripped <|empty|> and
the stop token also consume steps), so 6.0 steps/s plus a fixed overhead gives
headroom above the fastest speaker seen.
"""

from __future__ import annotations

import math
import os
from dataclasses import dataclass
from typing import Any, Callable, Optional, Tuple

STEPS_PER_AUDIO_SECOND = float(os.environ.get("ENGINE_ASR_STEPS_PER_SECOND", "6.0"))
STEP_OVERHEAD = int(os.environ.get("ENGINE_ASR_STEP_OVERHEAD", "64"))
MIN_NEW_TOKENS = int(os.environ.get("ENGINE_ASR_MIN_NEW_TOKENS", "256"))
MAX_NEW_TOKENS_HARD_CAP = int(os.environ.get("ENGINE_ASR_MAX_NEW_TOKENS_CAP", "3072"))

_MISSING = object()


@dataclass(frozen=True)
class DecodeBudget:
    """Knobs for `compute_max_new_tokens`; frozen so callers can't drift it."""

    steps_per_second: float = STEPS_PER_AUDIO_SECOND
    overhead: int = STEP_OVERHEAD
    floor: int = MIN_NEW_TOKENS
    hard_cap: int = MAX_NEW_TOKENS_HARD_CAP


DEFAULT_BUDGET = DecodeBudget()


@dataclass(frozen=True)
class GenerationStats:
    """What one transcription's decode actually did.

    `steps` / `hit_cap` / `stopped` are None when the ASR object has no
    patchable `model.generate` (e.g. test fakes) — unknown, not "fine".
    `max_new_tokens` is the cap the decode actually ran with (after the context
    window clamp), `requested_max_new_tokens` the duration-derived value.
    """

    requested_max_new_tokens: int
    max_new_tokens: Optional[int] = None
    steps: Optional[int] = None
    stopped: Optional[bool] = None
    hit_cap: Optional[bool] = None
    prompt_positions: Optional[int] = None

    def as_log_fields(self) -> dict:
        return {
            "asr_steps": self.steps,
            "asr_max_new_tokens": self.max_new_tokens,
            "asr_requested_max_new_tokens": self.requested_max_new_tokens,
            "asr_hit_cap": self.hit_cap,
            "asr_stopped": self.stopped,
            "asr_prompt_positions": self.prompt_positions,
        }


def compute_max_new_tokens(
    duration_s: Optional[float], budget: DecodeBudget = DEFAULT_BUDGET
) -> int:
    """Decode-step cap for `duration_s` seconds of audio.

    Unknown / invalid duration falls back to the floor (the old fixed 256), so
    a failed `sf.info` never widens the runaway window.
    """
    if duration_s is None or not math.isfinite(duration_s) or duration_s <= 0:
        return budget.floor
    scaled = math.ceil(duration_s * budget.steps_per_second) + budget.overhead
    return max(budget.floor, min(budget.hard_cap, scaled))


def clamp_to_context(
    requested: int,
    prompt_positions: int,
    context_limit: Optional[int],
    floor: int = MIN_NEW_TOKENS,
) -> int:
    """Keep prompt + generation inside the model's position window.

    Never clamps below `floor`: the old fixed 256 already ran past the window on
    the same prompts, so shrinking below it would be a regression, not a guard.
    """
    if not context_limit or context_limit <= 0:
        return requested
    room = context_limit - prompt_positions
    return max(min(floor, requested), min(requested, room))


def _group_size(model: Any) -> int:
    size = getattr(model, "group_size", None)
    if size is None:
        size = getattr(getattr(model, "config", None), "group_size", 1)
    return int(size) or 1


def _context_limit(model: Any) -> Optional[int]:
    return getattr(getattr(model, "config", None), "max_position_embeddings", None)


def _last_text_token(output: Any) -> Optional[int]:
    try:
        return int(output[0, 0, -1].item())
    except Exception:  # noqa: BLE001 - shape/type surprises → unknown
        return None


def _make_wrapper(
    model: Any, original: Callable, requested: int, sink: dict
) -> Callable:
    """Build the generate() shadow that forces the cap and records stats."""
    group = _group_size(model)
    context_limit = _context_limit(model)

    def wrapped(input_ids, *args, **kwargs):
        prompt_positions = int(input_ids.shape[-1]) // group
        cap = clamp_to_context(requested, prompt_positions, context_limit)
        out = original(input_ids, *args, **{**kwargs, "max_new_tokens": cap})
        steps = (int(out.shape[-1]) - int(input_ids.shape[-1])) // group
        stop_tokens = kwargs.get("stop_tokens") or []
        stopped = _last_text_token(out) in stop_tokens
        sink.update(
            max_new_tokens=cap,
            steps=steps,
            stopped=stopped,
            hit_cap=steps >= cap and not stopped,
            prompt_positions=prompt_positions,
        )
        return out

    return wrapped


def _restore(model: Any, previous: Any) -> None:
    if previous is _MISSING:
        # Drop the instance attribute so the class method resolves again.
        object.__delattr__(model, "generate")
    else:
        object.__setattr__(model, "generate", previous)


def transcribe_with_budget(
    asr: Any, audio_path: str, language: str, max_new_tokens: int
) -> Tuple[str, GenerationStats]:
    """Run `asr.transcribe` with `max_new_tokens` forced onto model.generate.

    Must run on the single inference thread under `infer_lock`: the shadow is an
    instance attribute on the shared model, installed and removed around exactly
    one call. Restoration happens in `finally`, so an exception mid-decode never
    leaves the next request on a stale cap.
    """
    model = getattr(asr, "model", None)
    if model is None or not callable(getattr(model, "generate", None)):
        text = asr.transcribe(audio_path, language=language)
        return text, GenerationStats(requested_max_new_tokens=max_new_tokens)

    sink: dict = {}
    previous = vars(model).get("generate", _MISSING)
    wrapper = _make_wrapper(model, model.generate, max_new_tokens, sink)
    object.__setattr__(model, "generate", wrapper)
    try:
        text = asr.transcribe(audio_path, language=language)
    finally:
        _restore(model, previous)
    return text, GenerationStats(requested_max_new_tokens=max_new_tokens, **sink)
