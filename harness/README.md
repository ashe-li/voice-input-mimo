# Harness — voice-input-mimo ASR Engine Regression

Inspired by [Rapid-MLX](https://github.com/raullenchai/Rapid-MLX) 4-tier doctor harness, adapted for ASR pipeline.

## Layout

```
harness/
├── baselines/         # JSON snapshots, one per (engine variant × tier)
├── runs/              # per-run artefacts (gitignored)
├── thresholds.yaml    # per-metric regression / improvement gate
└── README.md          # this file
```

## Workflow

1. Start engine under test:
   ```bash
   cd ../server   # or ~/Documents/voice-input-mimo/server
   uvicorn server:app --host 127.0.0.1 --port 8765
   ```
2. From this worktree root, run bench scripts in `scripts/`. Output goes to `runs/`.
3. After accepting a run as new ground truth, copy/promote into `baselines/`.
4. Future runs diff against `baselines/`, exit non-zero on regression (planned tier=`check` script).

## Tiers (planned)

| Tier | Time | Purpose |
|---|---|---|
| `smoke` | ~30s | import + endpoint reachable |
| `check` | ~5min | single audio fixture × full bench suite |
| `full` | ~30min | golden set × full bench suite |
| `benchmark` | overnight | sweep across precision / runs / cold states |

Phase 0 implements `check` tier first (single-fixture baseline against `server.py`).

## Baseline file naming

```
baselines/
├── server-py-baseline.json          # current server.py (commit e1d3e63)
├── engine-baseline.json             # new ASR engine (after Phase 1)
└── pipeline-baseline.json           # ASR + Qwen end-to-end (after Phase 2)
```

Each JSON includes:
- `baseline_version.git_sha` — pin to specific commit
- `baseline_version.git_status_clean` — `false` here means baseline includes uncommitted hotfixes (anti-pattern, refuse to promote)
- `host` — platform / machine / python version
- `summary` — flattened key metrics
- raw samples for re-aggregation

See KB pattern [optimization-baseline-must-include-existing-mitigations.md](https://github.com/.../knowledge-base/wiki/patterns/) for why git sha pinning matters.

## Metric definitions

| Metric | Source | Notes |
|---|---|---|
| `peak_rss_mb` | `psutil` | max during cold + N requests + idle |
| `post_idle_rss_mb` | `psutil` | RSS after `--idle-secs` of no traffic |
| `mlx_metal_cache_mb` | TBD | needs server-side `/admin/memory` endpoint (Phase 1) |
| `cold_ms` | end-to-end POST `/v1/audio/transcriptions` | first request after fresh server start |
| `warm_ms` | same | second request |
| `steady_median_ms` | same | median of run 3..N |
| `wer`, `cer` | [jiwer](https://github.com/jitsi/jiwer) | per-file vs golden YAML |

## Phase 0 status

- [x] `scripts/bench_memory.py` — RSS profile (skeleton)
- [x] `scripts/bench_latency.py` — cold/warm/steady (skeleton)
- [x] `scripts/bench_wer.py` — vs golden YAML (skeleton)
- [x] `harness/thresholds.yaml`
- [ ] `fixtures/audio/` — 3-5 zh-TW + 中英夾雜 wav files
- [ ] `fixtures/golden/transcripts.yaml`
- [ ] First baseline run → `baselines/server-py-baseline.json`
