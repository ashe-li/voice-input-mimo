# Phase 2 vs Phase 1 — Adaptive Idle Ladder + Qwen Remote Cache Manager

Generated: 2026-05-09T00:45:17+08:00

## Summary verdict

| Scenario | Verdict | Detail |
|---|---|---|
| high_freq | PASS | all expected verdicts met |
| sparse | FAIL | asr_evictions_done=0 expected>=3; phys_mb_idle_avg=None expected<500 |
| hard_ceiling | PASS | all expected verdicts met |
| qwen_cache | FAIL | cache_clear_observed=False expected=True; cache_final_mb=1388.25 expected<100 |

**Result: 2 / 4 scenarios passed.**

## Phase 1 baseline (reference)

| Metric | Value |
|---|---|
| cold_phys_mb | 43 MB |
| peak_phys_mb | 6451 MB |
| post_idle_phys_mb (after fixed 15s idle) | 197 MB |
| idle_drop_phys_mb | 6254 MB |
| cold_ms | 2972 ms |
| warm_ms | 697 ms |
| steady_median_ms | 676 ms |
| WER | 0.0 |

Note: Phase 1 used **fixed `idle=15s`** — every burst paid `cold_ms` ~3000 ms after each gap > 15s.

## Phase 2 results (per scenario)

### Scenario 1 — High-frequency (8 calls / 30 min, 210s interval)

- Snapshot: `phase2-high_freq-20260508-234002.json`
- Git: `b75cc0a7` @ 2026-05-08T15:40:02.091578+00:00
- Verdict: **PASS**

| Field | Value |
|---|---|
| 設定 | calls=8, interval=210.0s |
| Duration | 1478s |
| asr_evictions_done | **0** (expected=0) |
| cold_tax_total_ms | **0 ms** (expected<1000) |
| asr_max_level_reached | **3** (expected=3) |
| phys_mb p50 / p95 | 5837 MB / 5837 MB |

### Scenario 2 — Sparse (4 calls / 30 min, 450s interval)

- Snapshot: `phase2-sparse-20260509-000240.json`
- Git: `b75cc0a7` @ 2026-05-08T16:02:40.049819+00:00
- Verdict: **FAIL** — asr_evictions_done=0 expected>=3; phys_mb_idle_avg=None expected<500

| Field | Value |
|---|---|
| 設定 | calls=4, interval=450.0s |
| Duration | 1356s |
| asr_evictions_done | **0** (expected>=3) |
| cold_tax_total_ms | 0 ms |
| phys_mb_idle_avg | **n/a** (expected<500) |
| phys_mb p50 | 5837 MB |

### Scenario 3 — Hard ceiling (warmup → 1900s idle)

- Snapshot: `phase2-hard_ceiling-20260509-003727.json`
- Git: `b75cc0a7` @ 2026-05-08T16:37:27.835385+00:00
- Verdict: **PASS**

| Field | Value |
|---|---|
| 設定 | warmup=3 calls × 60.0s, idle=1900.0s |
| evict_observed_at_idle_s | **916.2589621543884s** (expected within 1800s) |
| asr_loaded_final | False |
| phys_mb_final | 315 MB |

### Scenario 4 — Qwen cache idle (5 chats → 360s idle)

- Snapshot: `phase2-qwen_cache-20260509-004432.json`
- Git: `b75cc0a7` @ 2026-05-08T16:44:32.129289+00:00
- Verdict: **FAIL** — cache_clear_observed=False expected=True; cache_final_mb=1388.25 expected<100

| Field | Value |
|---|---|
| 設定 | chats=5 × 10.0s, idle=360.0s |
| Cache MB initial → after chats → final | 1433 MB → 1388 MB → **1388 MB** |
| cache_clear_observed | **False** (expected=True) |
| cache_clear_at_idle_s | Nones |

## Headline numbers (Phase 1 → Phase 2 high_freq)

| Metric | Phase 1 (fixed 15s) | Phase 2 (adaptive 3/7/15 min) |
|---|---|---|
| Burst cold_tax | every gap >15s pays cold_ms ≈ 2972 ms | **0 ms** total over 8 calls |
| Idle phys_mb | drops to 197 MB after each idle | stays warm at 5837 MB (level 3) |
| Evictions during use | N (one per gap >15s) | **0** during burst |

