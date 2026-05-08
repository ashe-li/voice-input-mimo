---
title: ASR Engine + Cross-Process Memory Coordination — Implementation Plan
slug: asr-engine-memory-mgmt
status: draft
created: 2026-05-08
worktree: ~/Documents/voice-input-mimo-asr-engine
branch: feat/asr-engine-memory-mgmt
parent_repo: ~/Documents/voice-input-mimo
related_kb:
  - knowledge-base/wiki/patterns/asr-engine-vs-raw-python-speedup-benchmarks.md
  - knowledge-base/wiki/patterns/inference-engine-regression-harness-4-tier-design.md
  - knowledge-base/wiki/patterns/stack-archaeology-confirm-actual-layer-before-optimize.md
  - knowledge-base/reports/2026-05-08-voice-input-mimo-stack-archaeology-and-rapid-mlx-harness-analysis.md
---

# ASR Engine + Cross-Process Memory Coordination — Implementation Plan

## Goal

把 voice-input-mimo 的 ASR + Qwen 雙模型 pipeline 包成一個有**主動記憶體管控**的 engine，並用 Rapid-MLX-style 4-tier benchmark harness 跟現有 `server.py` 做數字對照。

**核心需求**（與一開始的「速度優化」假設不同）：

1. ASR + Qwen Rapid-MLX 是**順序 pipeline**：audio → ASR → Qwen → output
2. Qwen 結束後**才開始算記憶體釋放時間**（30 秒 idle → evict）
3. 兩個模型不要常駐同一台 16GB 機器，要協調
4. 提供 vs 現行 `server.py` 的 reproducible benchmark

## Why

- Apple Silicon unified memory：MiMo-ASR INT4 ≈ 4.5GB + Qwen 4B Q4 ≈ 2.5GB → 雙 warm = 7-8GB 常駐 + MLX Metal cache 還會繼續長
- 目前 `server.py:29-30` 自己有 per-request flush guards，但**只管 ASR side**，不知道 Qwen Rapid-MLX 在做什麼
- 沒有 idle-evict 機制 → 用完不會釋放
- 沒有 metric → 不知道現狀有多糟，更不知道改完有多好

## Current State Baseline（要量的 server.py）

**注意**：`~/Documents/voice-input-mimo/server/server.py` 目前有 +10 行未 commit 的修改。Benchmark 之前要決定：
- 選 A：先 commit 那 10 行，再起 baseline benchmark
- 選 B：把當前修改版 server.py 拷進 worktree 當 baseline，明確標記版本

主 repo 狀態（2026-05-08）：
```
HEAD: f727099 feat: initial release — voice-input-mimo
modified: server/server.py (+10 lines, uncommitted)
new file: Sources/VoiceInputMimo/LocalASRServer.swift (uncommitted)
```

**Baseline 量測項目**：
- cold_ttft_ms — 第一次 transcribe 從 0 到第一個字
- batch_total_ms — 完整 transcribe 完成
- peak_rss_mb — 整個過程 max RSS
- steady_idle_rss_mb — transcribe 完 30s 後 RSS（預期不會降）
- mlx_metal_cache_mb — `mx.metal.get_active_memory()`
- wer / cer — 對 golden audio set 的錯誤率

## Pipeline Flow（with timing）

```
t=0     [audio arrives at ASR engine]
        │
        ├─ load ASR model if not warm        (1500ms cold)
        │
        ├─ async: trigger Qwen pre-warm via   (~3000ms cold, parallel)
        │   Rapid-MLX HTTP /v1/chat...        (1-token dummy if /admin not exposed)
        │
t=Δ1    [ASR decode complete]
        │
        ├─ stream text to Qwen Rapid-MLX
        ├─ schedule ASR evict in 5s          ← (ASR 後續用不到了)
        │
t=Δ2    [Qwen response complete]
        │
        ├─ return to user
        ├─ schedule Qwen evict in 30s        ← (使用者剛拿到結果，可能還會再講)
        ├─ start global idle timer (30s)
        │
t=Δ3    [no new request for 30s]
        │
        └─ evict everything                   peak RSS → idle RSS
```

**關鍵設計原則**：
- ASR 比 Qwen 早完成，可以**先 evict ASR** 同時 Qwen 還在跑（降 peak RSS）
- 但 voice-input 場景使用者可能連續觸發，**不要過度激進** evict ASR（5s 緩衝）
- Qwen evict 等更久（30s），因為 LLM 重 load 比 ASR 貴

## Memory Coordination 設計

### 三選項對比

| 選項 | 機制 | 複雜度 | 推薦 |
|---|---|---|---|
| A. 各自管自己 | 兩 process 互不通信，靠 idle timer | 低 | ❌ — 解不了 peak 重疊 |
| B. 檔案 lock 協調 | 共用 `~/.voice-input-mimo/coordinator.json` | 中 | 🟡 — race condition 多 |
| **C. ASR engine 當 orchestrator** | ASR engine 控制自己 + 透過 HTTP 控 Rapid-MLX | 中 | ✅ |

### 選 C 的理由

- ASR 是 pipeline 入口（audio 先到這），自然知道何時觸發 Qwen
- 同一個 process 知道 Qwen 何時 done → 能精準起 evict timer
- Rapid-MLX 暴露 OpenAI-compat endpoint，已經有 HTTP 介面
- 不需要第三個 daemon

### 開放問題：Rapid-MLX 的 evict 介面

需要實作期確認 Rapid-MLX 是否支援以下任一：

1. **HTTP `/admin/unload` or `/admin/evict`**（最佳）
2. **`--idle-evict-seconds` 啟動參數**（次佳）
3. **SIGUSR1 signal handler**（可接受）
4. **以上皆無 → 需要 fallback**：
   - Fallback 1：傳 `keep_alive=0` 之類 hint（看 Rapid-MLX 是否認）
   - Fallback 2：透過 `pkill -SIGTERM rapid-mlx` 強制重啟（重 load 慢）
   - Fallback 3：跑 dummy short request 觸發 cache 清理
   - Fallback 4：放棄 Qwen evict，只管 ASR

如果 Rapid-MLX 真的什麼都沒有，至少 ASR side 還能省 4.5GB。

## Components

### 1. `engine/memory.py` — Memory Tracker + MLX Cache Mgmt

```python
# Pseudocode
class MemoryTracker:
    def rss_mb(self) -> float: ...          # 目前 process RSS
    def metal_active_mb(self) -> float: ...  # mx.metal.get_active_memory() / 1MB
    def metal_cache_mb(self) -> float: ...
    def trim_metal_cache(self) -> int: ...   # mx.metal.clear_cache(), 回傳釋放量
    def set_metal_cache_limit_mb(self, mb: int): ...  # mx.metal.set_cache_limit
    def snapshot(self) -> dict: ...          # 給 metrics export 用
```

server.py 目前只在 request 結束 flush 一次。新版要：
- 啟動就 `set_cache_limit` 設 hard cap（預設 512MB）
- 每 request 結束 trim
- Idle eviction 時**先 trim cache 再 unload model**

### 2. `engine/lifecycle.py` — LazyModel + Idle Evict

```python
class LazyModel:
    def __init__(self, loader_fn, idle_seconds=30, name="model"):
        self._loader = loader_fn
        self._model = None
        self._last_used = None
        self._idle_seconds = idle_seconds
        self._lock = asyncio.Lock()

    async def get(self) -> Any:
        # load if not warm, reset idle timer
        ...

    async def warmup_token(self):
        # 載入 + 跑最小 dummy 把 weights 真的 page in
        ...

    async def evict(self):
        # del model + gc.collect() + memory.trim_metal_cache()
        ...

    async def idle_check_loop(self):
        # background task: 若 last_used > idle_seconds 前，呼叫 evict
        ...
```

ASR 的 `LazyModel` 跟 Qwen 的（remote control via HTTP）共用這個介面。

### 3. `engine/qwen_remote.py` — Rapid-MLX Remote Control

```python
class QwenRemoteModel:
    """LazyModel-shaped wrapper that controls Rapid-MLX over HTTP."""
    def __init__(self, base_url, idle_seconds=30):
        ...

    async def prewarm(self):
        # POST /v1/chat with 1-token dummy to page weights in
        ...

    async def evict(self):
        # 試這幾種，第一個成功的就用：
        # 1. POST /admin/unload
        # 2. POST /admin/evict
        # 3. PUT /v1/models/<id> with keep_alive=0
        # 4. signal/restart fallback
        ...

    async def chat(self, messages) -> str:
        # 一般 inference call
        ...
```

### 4. `engine/streaming.py` — Chunk-then-Stitch（可選）

MiMo-ASR 是 batch decode，沒有原生 streaming。模擬 streaming 的方式：
- 把 audio 切成 ~5s overlapping chunks
- 每 chunk 跑完 decode 就 yield partial transcript
- 用 overlap 段做 dedup（簡單版：取後半 N 字判斷重複）

副作用：peak RSS 比 single-pass 低（一次只處理 5s 而非整段）

**Phase 1 不做 streaming**，先把 memory mgmt 做對。

### 5. `engine/server.py` — Thin FastAPI Shell

把 lifecycle + memory + qwen_remote 串起來：

```python
asr_model = LazyModel(loader_fn=load_mimo_asr, idle_seconds=15)
qwen_model = QwenRemoteModel(base_url=RAPID_MLX_URL, idle_seconds=30)

@app.post("/v1/audio/transcriptions")
async def transcribe(audio: UploadFile, ...):
    # 1. trigger Qwen prewarm in background
    qwen_task = asyncio.create_task(qwen_model.prewarm())

    # 2. ASR decode
    asr = await asr_model.get()
    text_raw = asr.transcribe(audio_path)

    # 3. ASR done — schedule self-evict (5s)
    asr_model.schedule_evict_in(5)

    # 4. wait for Qwen warm + run refine
    await qwen_task
    text_refined = await qwen_model.chat([{"role":"user","content":f"潤稿：{text_raw}"}])

    # 5. Qwen done — schedule its evict (30s)
    qwen_model.schedule_evict_in(30)

    return {"text": text_refined}
```

### 6. `harness/` — 對照 Benchmark

仿 Rapid-MLX `harness/` 結構：

```
harness/
├── thresholds.yaml
├── baselines/
│   ├── server-py-baseline.json          # 量出來的 server.py 數字
│   ├── engine-baseline.json             # 量出來的 new engine 數字
│   └── pipeline-baseline.json           # 端到端 ASR + Qwen pipeline
├── runs/                                 # per-run artefacts (gitignored)
└── README.md
```

### 7. `scripts/` — Bench Scripts

```
bench_memory.py        # RSS / Metal cache profile, 含 idle/active cycle
bench_latency.py       # cold_ttft + first_partial + batch_total
bench_wer.py           # golden set → WER/CER
bench_pipeline_e2e.py  # ASR + Qwen 端到端
compare_server_vs_engine.py   # 雙 port 對照（仿 bench_vs_ollama.py）
```

## thresholds.yaml

```yaml
# Memory — 0% 容忍 RSS 漲（這是這版的核心 KPI）
peak_rss_mb:           { regression_pct: 0,  improvement_pct: 5 }
steady_idle_rss_mb:    { regression_pct: 0,  improvement_pct: 10 }
mlx_metal_cache_mb:    { regression_pct: 5,  improvement_pct: 10 }
evict_reload_ms:       { regression_pct: 15, improvement_pct: 20 }

# Latency
cold_ttft_ms:          { regression_pct: 10, improvement_pct: 15 }
batch_total_ms:        { regression_pct: 5,  improvement_pct: 10 }
pipeline_e2e_ms:       { regression_pct: 5,  improvement_pct: 10 }

# Quality — 0% 容忍
wer:                   { regression_pct: 0,  improvement_pct: 5 }
cer:                   { regression_pct: 0,  improvement_pct: 5 }
```

## Phases

### Phase 0：Baseline（Day 1）

- [ ] 處理 server.py 未 commit 變更（commit 或 copy 進 worktree）
- [ ] 準備 fixtures：3-5 個 zh-TW + 中英夾雜 audio + golden transcript
- [ ] 跑 `bench_memory.py` + `bench_latency.py` + `bench_wer.py` 對 baseline server.py
- [ ] 寫入 `harness/baselines/server-py-baseline.json`
- [ ] **Gate**：確認量出的數字符合直覺（RSS ~5GB、idle 不降）— 不對的話先 debug 量測，不要急著寫 engine

### Phase 1：Memory Tracker + LazyModel + ASR Side（Day 2-3）

- [ ] `engine/memory.py` 完成 + 自測 trim/cap 真的有效
- [ ] `engine/lifecycle.py` LazyModel 完成 + idle evict loop 自測
- [ ] `engine/server.py` 接入 ASR side（先不接 Qwen）
- [ ] `bench_memory.py` 量新 engine ASR-only：should see steady_idle drop
- [ ] **Gate**：ASR-only steady_idle_rss_mb 應 < 1GB（vs baseline ~5GB）

### Phase 2：Qwen Remote Control（Day 4-5）

- [ ] 探查 Rapid-MLX 真實支援的 admin 介面
- [ ] `engine/qwen_remote.py` 用第一個可行方案實作
- [ ] `engine/server.py` 接入完整 pipeline
- [ ] `bench_pipeline_e2e.py` 量端到端
- [ ] **Gate**：pipeline_e2e_ms 不能比 baseline 慢 5% 以上 + steady_idle 真的會降

### Phase 3：Harness + Comparison Report（Day 6-7）

- [ ] `harness/thresholds.yaml` finalize
- [ ] `compare_server_vs_engine.py` 雙 port 自動跑 + 輸出 markdown report
- [ ] 寫 final report 到 `~/Documents/knowledge-base/reports/`
- [ ] 確認所有 gate 通過 + WER/CER 持平

## Out of Scope（Phase 1 不做）

- Streaming partial transcript（之後 Phase 4 再加）
- Multi-model serving（MiMo + Whisper + Parakeet 並列）
- Continuous batching（單 user 用不上）
- Cross-process coordinator daemon（用 ASR engine 內嵌的 orchestrator）
- Hot-swap precision INT4 ↔ BF16（記憶體緊就降，但 Phase 1 不做）

## Risks / Open Questions

1. **Rapid-MLX 沒有 evict 介面** — 需要 Phase 2 探查，最壞 fallback 是只管 ASR side
2. **MLX cache trim 會不會影響準確度** — 不應該，但要 WER 量出來確認
3. **Idle evict 時機不對會導致頻繁 reload** — 預設 ASR=15s / Qwen=30s，跑起來再調
4. **Baseline server.py 未 commit 變更** — 量錯版本會誤導，Phase 0 必處理
5. **Mac 機型差異** — M1/M2/M3 unified memory size + Metal 行為不同。Benchmark 要記錄機型

## Success Criteria

- [ ] steady_idle_rss_mb 比 baseline 降 50% 以上（5GB → 2GB 級別）
- [ ] pipeline_e2e_ms 不退步（5% 容忍）
- [ ] WER / CER 持平（0% 容忍）
- [ ] Benchmark harness 可重現執行 + diff vs baseline
- [ ] 文件齊全足以讓另一個 engineer 接手或 PR 給社群（mimo-mlx / mlx-audio）

## Validation Plan

完成後跑這些 sanity 測試：

1. 開啟 ASR + Qwen，閒置 1 分鐘，觀察 RSS 應降
2. 連續觸發 5 次 transcribe，間隔 < idle 時間，觀察沒有重複 reload
3. 連續 5 次後等 1 分鐘，觀察兩個 model 都被 evict
4. 重新觸發，確認 reload 順利（cold_ttft 應接近預期值）
5. 跑全套 benchmark，diff vs baseline
