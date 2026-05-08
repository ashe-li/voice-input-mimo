# Fixtures — voice-input-mimo ASR Engine Benchmark

## Layout

```
fixtures/
├── audio/                    # 10 real utterances (gitignored)
├── golden/
│   └── transcripts.yaml      # self-seeded by scripts/seed_golden.py (committed)
└── README.md
```

## Approach: Self-seeded reference

This is a **regression test**, not an absolute ASR quality test. The golden YAML records whatever the baseline `server.py` produces; the new ASR engine must reproduce that same text (within `wer / cer regression_pct: 0` per `harness/thresholds.yaml`).

Pattern: [engine-regression-test-self-seeded-reference.md](https://github.com/.../knowledge-base/wiki/patterns/engine-regression-test-self-seeded-reference.md)

## Audio source

10 real utterances copied from:

```
~/Library/Application Support/VoiceInputMimo/recordings/
```

(Recorded 2026-05-08, 4.3s – 35.7s each, mix of pure-zh / code-switch / open-ended queries.)

`fixtures/audio/` is gitignored — wavs stay local. If you wipe the worktree, re-run:

```bash
mkdir -p fixtures/audio
cp ~/Library/Application\ Support/VoiceInputMimo/recordings/*.wav fixtures/audio/
```

If the recordings dir is gone too, you'll need to re-record 5–10 utterances of varying length.

## Seeding the golden

Once `fixtures/audio/` has wavs and `server.py` is running:

```bash
# In one shell — start the baseline server
cd ../voice-input-mimo
uvicorn server.server:app --host 127.0.0.1 --port 8765

# In another shell — from worktree root
python scripts/seed_golden.py
# Output:
#   <wav> (8.5s) → <transcribed text preview>
#   ...
#   wrote fixtures/golden/transcripts.yaml (10 entries)
```

`seed_golden.py` records the baseline's git sha into the YAML header so future engines know which baseline they're matching.

## Regenerating

When does the golden need refresh?

| Trigger | Action |
|---|---|
| Baseline `server.py` itself changes (better prompt / quant tuning) | Re-run `seed_golden.py`, commit new YAML |
| Audio fixtures change (add/remove wavs) | Re-run `seed_golden.py` |
| New ASR engine output diverges (regression flagged) | **Don't refresh** — diff against existing golden, fix the engine |

The whole point is that the third row blocks accidental "fix" by overwriting golden.

## Fixture stats

`scripts/seed_golden.py` auto-categorises by duration:

- `short`      — < 5s
- `medium`     — 5–10s
- `long`       — 10–20s
- `extra-long` — 20s+

Current set (10 wavs from 2026-05-08):

| Bucket | Count | Durations |
|---|---|---|
| short | 1 | 4.3s |
| medium | 3 | 7.1 / 7.4 / 8.5s |
| long | 3 | 10.8 / 11.5 / 13.9s |
| extra-long | 3 | 20.6 / 21.4 / 35.7s |

Full bench against this set ≈ ~140s of audio + ~30s overhead = under 3 min per engine run.

## Audio source archaeology (2026-05-08)

Earlier candidates that didn't work:

| Path | Verdict |
|---|---|
| `~/Desktop/voice-input-debug/` | 144 wavs but all 4096 bytes / 0 audio (`sox stats: no audio`) — streaming chunk debug stub, not utterances |
| `/tmp/silent.wav`, `/tmp/test*.wav` | 0.5–4.3s short tests, mostly silence or signal |
| `~/Library/Application Support/VoiceInputMimo/recordings/` ✅ | 10 real utterances, kept by the app |

`server.py` itself uses `tempfile.NamedTemporaryFile(delete=False)` and unlinks on exit, so the audio matching `/tmp/mimo-server.log` UUIDs is gone — only the app-side recording dir survives.
