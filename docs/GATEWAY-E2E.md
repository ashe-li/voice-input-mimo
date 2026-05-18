# VIM × local-llm-backend Gateway E2E

VIM 端跟 `local-llm-backend` gateway 串接的 E2E 整合說明。包含 fixture export 流程、`asrBaseURL` 切換、cross-repo smoke test 執行方式。

## Architecture

```
┌─ VIM (this repo) ──────────┐         ┌─ local-llm-backend ──────────┐
│ AudioRecorder              │         │                              │
│   ↓                        │         │   Gateway (Hono :4000)       │
│ RecordingTracer            │  HTTP   │     ↓                        │
│   ↓                        │ ────────▶  ASR + LLM provider routing  │
│ ASRClient / LLMRefiner     │         │     ↓                        │
│   ↓                        │         │   Backends (MiMo / vLLM-MLX / │
│ FixtureExporter            │         │             Rapid-MLX)        │
│   ↓ (export menu action)   │         └──────────────────────────────┘
│ ~/Documents/local-llm-     │                       ↑
│   backend/harness/fixtures │  (harness/e2e/run.ts consumes fixtures
│                            │   to measure end-to-end pipeline)
└────────────────────────────┘
```

## Prerequisites

| Item | Check |
|------|-------|
| VIM build | `cd ~/Documents/voice-input-mimo && swift build` |
| Gateway running | `curl -s http://127.0.0.1:4000/health` returns 200 |
| MiMo sidecar | `curl -s http://127.0.0.1:8766/v1/health` returns 200 |
| `asrBaseURL` configured | see § Endpoint Configuration |

## Endpoint Configuration

VIM 預設 `asrBaseURL` 指向 MiMo sidecar `:8766`。要切到 gateway `:4000` 時：

```bash
# 切到 gateway（驗 E2E 用）
defaults write com.shiun.VoiceInputMimo asrBaseURL "http://127.0.0.1:4000"

# 切回 sidecar 直接連（VIM 原本配置）
defaults write com.shiun.VoiceInputMimo asrBaseURL "http://127.0.0.1:8766"
```

> ⚠️ **Domain mismatch trap**：`defaults` CLI 用 plist filename 當 domain，但 binary 讀的是 `CFBundleIdentifier` (`com.shiun.VoiceInputMimo`)。**永遠寫 bundle id**，不要寫 `VoiceInputMimo`，否則 binary 讀不到改動。見 `wiki/patterns/macos-userdefaults-domain-bundle-id-mismatch.md`。

## Fixture Export Workflow

### 開菜單 export 既有 trace

1. 啟動 VIM（從 `/Applications/VoiceInputMimo.app` 或 swift run）
2. status bar → **«Export Fixtures...»**
3. 選擇輸出目錄：`~/Documents/local-llm-backend/harness/fixtures/`
4. VIM 把所有 `TraceStore` 中的 entry（有 `audioPath` 的）export 成：
   - `audio/trace-<id>.wav`（mono 16 kHz/16-bit PCM）
   - `transcripts/trace-<id>.txt`（raw ASR 結果，UTF-8）

### 升級成 canonical seed fixture

raw trace 要升級為 canonical seed（short/medium/long）：

```bash
cd ~/Documents/local-llm-backend/harness/fixtures

# 1. 校正 transcript 當 ground truth（修錯字、補標點）
$EDITOR transcripts/trace-XXXX.txt

# 2. rename 為 canonical 名稱
mv audio/trace-XXXX.wav     audio/<short|medium|long>.wav
mv transcripts/trace-XXXX.txt transcripts/<short|medium|long>.txt
```

詳細 fixture spec + git policy 見 `~/Documents/local-llm-backend/harness/fixtures/README.md`。

## Running E2E Tests

### Cross-repo smoke (VIM-side)

從 VIM 端打 gateway 驗 client-side request shape（multipart boundary、SSE framing）：

```bash
cd ~/Documents/voice-input-mimo
GATEWAY_E2E_URL=http://127.0.0.1:4000 \
  swift test --filter GatewayE2ESmokeTests
```

每個 test 在環境缺失時 XCTSkip（gateway down / fixture missing），不會 fail-loud — 適合在無 backend 環境跑 `swift test` 也不會爆紅。

4 個 test 涵蓋：
- ASR multipart endpoint return text
- Chat completions mode=quick streaming
- Chat completions mode=default streaming
- Chat completions mode=batch streaming

### Full E2E harness (gateway-side)

```bash
cd ~/Documents/local-llm-backend
make e2e                    # gateway lifecycle wrapped, exit 0/1/2
make update-e2e-baseline    # seed/refresh baseline
```

Artifacts → `harness/runs/<ISO-ts>/{e2e.json,e2e-scorecard.md}`。

詳細 exit code 與 metric 解釋見 `~/Documents/local-llm-backend/harness/e2e/README.md`。

## Common gotchas

| 問題 | 解法 |
|------|------|
| `defaults write` 沒生效 | 寫到 `VoiceInputMimo` 而非 `com.shiun.VoiceInputMimo`（孤兒 plist） |
| Gateway 502 on long.wav | MiMo cold start + 18s wall > gateway timeout — warm up sidecar 後 retry |
| Gateway 401 on mode=default | mode→provider 路由把 default 送到 `asr-vllm`（:8767）未正確 auth — 改 mode=quick 走 MiMo |
| swift test XCTSkip 所有 test | gateway down 或 `GATEWAY_E2E_URL` 環境變數沒設 |

## Related

- Plan: `~/Documents/knowledge-base/plans/active/vim-gateway-e2e-integration.md`
- Gateway docs: `~/Documents/local-llm-backend/docs/INTEGRATION.md`
- Harness README: `~/Documents/local-llm-backend/harness/e2e/README.md`
- Fixture spec: `~/Documents/local-llm-backend/harness/fixtures/README.md`
