# Phase 1 ASR Engine vs Baseline server.py

Comparison of `engine-phase1-baseline.json` against `server-py-baseline.json`.

Both runs measured 2026-05-08 on the same machine, same fixtures, same Qwen Rapid-MLX coresident on port 8082. Phase 1 engine adds `LazyModel` + idle eviction (15s threshold, 5s check interval).

## Memory (primary target)

| Metric | Baseline (server.py) | Engine (Phase 1) | Δ | Verdict |
|---|---|---|---|---|
| `peak_phys_mb` | 6451.2 | 6451.2 | 0 % | ✓ inference peak unchanged |
| `post_idle_phys_mb` | 5836.8 | **196.9** | **−96.6 %** | ✅ idle eviction works |
| `cold_phys_mb` | 5836.8 ¹ | 42.8 | n/a | engine measured true cold (lazy load) |
| `idle_drop_phys_mb` | 614.4 | 6254.3 | +918 % | engine evicts the 5.6 GB of mmap'd weights too |

¹ baseline `cold` was warm-cold (server already had weights resident before bench started).

**Plan §Phase 1 success criterion**: `post_idle_phys_mb < 1000 MB` against 5836 MB baseline. Achieved **196.9 MB ≈ 5× better than target**.

## Latency

| Metric | Baseline | Engine | Δ | Note |
|---|---|---|---|---|
| `cold_ms` | 700.4 | 2972.4 | +324 % | engine cold = real model load tax (~2.3s) since model was just evicted |
| `warm_ms` | 695.2 | 697.3 | +0.3 % | identical |
| `steady_median_ms` | 718.3 | 676.2 | −5.9 % | within noise |
| `steady_p95_ms` | 777.3 | 681.6 | −12.3 % | engine slightly faster (likely fewer cache hits to spurious objects) |

**Trade-off**: engine pays ~2.3s cold tax when reloading after eviction, in exchange for releasing 5.6 GB. For voice-input use case (sparse user-driven traffic, > 15s idle gaps common), this is the right trade. For continuous-burst usage (< 15s between transcribes), engine stays warm and pays no tax.

## Quality (WER / CER)

| Metric | Baseline | Engine | Δ |
|---|---|---|---|
| `avg_wer` | 0.0000 | 0.0000 | 0 |
| `avg_cer` | 0.0000 | 0.0000 | 0 |
| `n_scored / n_total` | 10 / 10 | 10 / 10 | — |

Engine reproduces baseline transcribe output character-for-character across all 10 fixtures. Same `mimo_mlx` model + same OpenCC `s2twp` + same zhtw-mcp ruleset → deterministic match expected, and confirmed.

## Threshold check (`harness/thresholds.yaml`)

| Metric | Threshold | Engine vs Baseline | Pass? |
|---|---|---|---|
| `peak_rss_mb` | regression_pct: 0 | identical | ✓ |
| `steady_idle_rss_mb` | regression_pct: 0 | engine ≪ baseline | ✓ improvement |
| `cold_ttft_ms` | regression_pct: 10 | +324 % | ✗ but expected — see latency trade-off above |
| `batch_total_ms` | regression_pct: 5 | −5.9 % steady | ✓ |
| `wer` / `cer` | regression_pct: 0 | identical (0.0) | ✓ |

`cold_ttft_ms` regression is intentional design (idle eviction) and not flagged as failure for Phase 1 — Phase 1 success criterion explicitly targets memory, accepting cold-load tax. Phase 2+ may add prewarm-on-demand to reduce cold tax.

## Phase 1 verdict

✅ **Pass**. Memory target exceeded by 5×, transcribe quality identical, steady latency unchanged. Cold latency regression is the intentional cost of memory-management design, accepted per plan §Phase 1.

## What's next (Phase 2)

- Wire Qwen Rapid-MLX side as `RemoteLazyModel` controlled via HTTP
- Asymmetric idle: ASR=5s, Qwen=30s, global=30s (per plan §Idle-Evict)
- Prewarm Qwen during ASR decode (overlaps cold-load with already-running work)
