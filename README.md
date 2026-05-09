# voice-input-mimo

獨立分支 — 改用 **MiMo-V2.5-ASR**（Xiaomi 開源、原生支援中英 code-switching）取代 Apple Speech 做語音辨識，搭配本地 LLM（**Rapid-MLX** 為主、LM Studio / ollama 等 OpenAI 相容後端皆可）做後處理。預設 LLM endpoint：`http://127.0.0.1:8082/v1`（Rapid-MLX）。

> **狀態**：Phase A（ASR server）+ Phase B（Swift app）+ Phase 2（adaptive idle ladder + Qwen cache manager + structured logging）皆已落地。
> - 舊 `server/server.py` 仍在 repo（fixed idle）作為 baseline reference
> - 新 engine 在本 repo 的 `engine/`，由 Swift app 預設啟動於 port 8766
> - 不污染 `~/Documents/voice-input-src/`（Apple Speech 版繼續存在）

## 為什麼需要這個分支

`voice-input-src` 用 Apple Speech zh-TW 做 STT，對中英混場景不行：

- Apple Speech 把英文縮寫聽成 ASCII 散字（`LLM` → `L M K`、`API` → `A屁I`）
- 把英文詞音譯成中文（`Python` → `派森`、`React` → `瑞克特`、`component` → `康波奶特`）
- LLM 後處理可救一些，但只用 4B 模型救不回大部分

MiMo-V2.5-ASR 原生支援中英 code-switching（Xiaomi 訓練資料含大量混合語言），對開發者場景顯著好。

代價：失去 streaming partial result（要錄完才轉），多一個 Python service 要管。

## 架構

```
~/Documents/voice-input-mimo/
├── server/                      ← Phase A baseline（fixed idle，保留作對照）
│   ├── server.py                FastAPI + Whisper-compat endpoint
│   ├── pyproject.toml           uv-managed dependencies
│   ├── run.sh                   啟動腳本
│   ├── test_smoke.sh            curl 測試
│   └── .venv/                   Python 3.12 venv
├── engine/                      ← Phase 2 engine（預設啟動於 port 8766）
│   ├── server.py                thin FastAPI shell
│   ├── adaptive_idle.py         3/7/15 min idle ladder
│   ├── lifecycle.py             LazyModel + cold/warm 管理
│   ├── memory.py                MemoryTracker（vmmap snapshot TTL cache）
│   ├── qwen_remote.py           Qwen cache poll manager
│   └── logsetup.py              structured JSON log + X-Request-Id
├── harness/                     ← bench harness + scenario fixtures
├── fixtures/                    ← 測試音檔
├── Sources/, Package.swift, Makefile  ← Phase B Swift app
├── Tests/VoiceInputMimoTests/   ← Swift unit tests
└── plans/                       ← 設計與規劃 markdown
```

Phase 2 engine（adaptive idle ladder 3/7/15 min + Qwen cache poll manager + 三層結構化 log + X-Request-Id end-to-end correlation）住在本 repo 的 `engine/`，Swift app `LocalASRServer.swift` 預設指向 `engine.server:app` + port 8766。

## Server API

OpenAI Whisper 相容：

| Method | Path | 說明 |
|---|---|---|
| GET | `/v1/health` | 健康檢查 + 已 load model + OpenCC 設定 + zhtw rules 數 |
| GET | `/v1/models` | 列出已掛載模型 |
| POST | `/v1/audio/transcriptions` | 上傳音檔 → 文字 |

POST 表單欄位（multipart）：
- `file`（必填）：wav / aiff / mp3 etc.
- `language`（選填）：`auto` / `zh` / `en`，預設 `auto`
- `model`（選填）：相容性接受但忽略
- `response_format`（選填）：`json`（預設）/ `text`
- `output_locale`（選填）：`zh-TW`（預設）/ `none`

## 簡體 → 繁體（兩段 post-process）

MiMo-V2.5-ASR 訓練資料以簡體為主，輸出預設是簡體。本 server 預設套用兩段 post-process：

1. **OpenCC s2twp** — 廣域字元 + 一般詞彙轉換（软件→軟體、默认→預設、视频→影片、内存→記憶體）
2. **zhtw-mcp ruleset**（[sysprog21/zhtw-mcp](https://github.com/sysprog21/zhtw-mcp)）— IT 領域專業術語替換（主線程→主執行緒、網關→閘道器、内核映象→核心映像檔）

啟動時自動載入；無 OpenCC / 無 ruleset 時 silently fallback 為純 ASR 輸出。

### 觀察輸出時 raw vs converted

```bash
curl -s -X POST http://127.0.0.1:8765/v1/audio/transcriptions \
    -F file=@audio.wav -F language=auto | jq .
```

回應：
```json
{
  "text": "幫我重構這個軟體的閘道器設定",
  "raw_text": "帮我重构这个软件的网关设置",
  "language": "auto",
  "output_locale": "zh-TW",
  "duration_ms": 1768
}
```

`raw_text` 只在 post-process 改變內容時才出現（節省 payload）。

## 啟動

```bash
cd ~/Documents/voice-input-mimo/server

# 第一次跑會下載 4.5 GB model（int4 MLX）到 ~/.cache/mimo-asr/
MIMO_PRELOAD=1 ./run.sh
```

環境變數：
| Var | 預設 | 說明 |
|---|---|---|
| `MIMO_PRECISION` | `int4` | 也可 `bf16`（品質微高、顯存翻倍） |
| `MIMO_MODEL_ROOT` | `~/.cache/mimo-asr` | 模型存放位置 |
| `MIMO_PRELOAD` | `0` | `1` = 啟動時就 load（首次啟動較慢但首請求快） |
| `PORT` | `8765` | HTTP port |
| `MIMO_DEFAULT_LANGUAGE` | `auto` | 缺省語言 hint |

## Smoke test

```bash
./test_smoke.sh
```

會用 macOS `say` 生成三段音檔（純中、中英混、技術術語），打 server 比對轉錄品質。

## Phase B Swift app（已完成）

`Sources/VoiceInputMimo/` 完整 macOS LSUIElement app：

**Pipeline 主鏈**
- `AudioRecorder.swift`：AVAudioEngine 錄 16 kHz mono PCM wav
- `ASRClient.swift`：multipart POST → `/v1/audio/transcriptions`，X-Request-Id 自動 forward；`/admin/memory` 走 8s timeout（cold path 可超過 default 2s）
- `LLMRefiner.swift`：英譯 / 繁中 cleanup / claudeCode mode（含 zh-TW suffix 注入）；system prompt 走 PromptStore → UserDefaults → hardcoded 三層 fallback
- `Prompts/`：Prompt Profile + Skill 客製化系統（branch `feat/prompt-profile-skill-system`，Phase 1 logic foundation 完成、UI 進行中）
  - `PromptProfile.swift`：Profile / Skill / SkillCategory / ActiveSelection 資料模型
  - `PromptStore.swift`：JSON CRUD（`~/Library/Application Support/VoiceInputMimo/prompts/`）+ atomic write
  - `PromptComposer.swift`：append-mode rendering（v1.5 加 slot 模板）+ token estimate
  - `BuiltinPromptCatalog.swift`：8 builtin skills + 2 default profiles
  - `PromptMigration.swift`：first-launch bootstrap + 既有 UserDefaults override import
- `LocalASRServer.swift`：supervise local engine（adopt 既有 / 自己 spawn），預設 module path = `engine.server:app`
- `TextInjector.swift` / `RecordingArchive.swift`：貼上 + 錄音歸檔

**Input / UI surface**
- `KeyMonitor.swift`：CGEventTap，依 `ShortcutBinding` 同時監 Fn flagsChanged 與 modifier+keyDown 兩條路徑
- `ShortcutBinding.swift`：5 個 preset（Disabled / Fn / Control + Option + Space / Control + Option + V / Command + Shift + Space），primary + secondary 各自綁，存於 UserDefaults
- `OverlayPanel.swift`：`Phase` enum 驅動的單一 `transition(to:)` API，狀態含 recording/transcribing/zhReady/refining/bothReady/error
- `AppDelegate.swift`：狀態列選單 — 三段式輸出模式（英文 Prompt / 中文 ASR 原文 / 中文 LLM 修正）+ Clipboard History（⌘⌥H）+ Model Memory（⌘⌥M）+ Preferences（⌘,）
- `SettingsWindow.swift`：Shortcuts / Speech Recognition / ASR Server / Text Refinement 四段；自動 5s poll engine 狀態 / Probe 走 smoke transcribe

**輔助 window**
- `ClipboardHistoryWindow.swift` + `ClipboardArchive.swift`：每次完成 dictation 即透過 `saveSession(zh:english:)` 保留 ASR 原文 + 輸出，標記為 `EntryKind.session`；舊 clipboard snapshot 仍以 `EntryKind.clipboard` 存
- `ModelMemoryWindow.swift` + `ModelMemoryMonitor.swift`：每 5s 輪詢 engine `/admin/memory` 與 LLM 後端（Rapid-MLX）`/v1/status`，顯示 Speech / LLM 模型 RSS / metal active / cache

**開發 / 預覽**
- `VOICE_INPUT_MIMO_PREVIEW=1`：regular activation policy、自動開 Clipboard History + Model Memory 並注入 sample archive、跳過 LocalASRServer 啟動與終止 — bypass install + 重簽 + TCC re-grant tax
- `VOICE_INPUT_MIMO_ARCHIVE_PATH=<path>`：把 clipboard archive 指向沙盒檔（preview / dev 用）

bundle id `com.shiun.VoiceInputMimo` 跟 Apple Speech 版（`voice-input-src`）並存。`make install` 建置 + 安裝到 `/Applications/`。Phase 2 engine wire-up 切到 8766 / `engine.server:app` 走 UserDefaults 一次性 migration。

## Tests

```bash
swift test            # 全部 unit test（91 個）
make e2e-phase1       # Phase 1 E2E acceptance gate（需 Rapid-MLX 8082 在跑）
```

`Tests/VoiceInputMimoTests/` 涵蓋 ShortcutBinding / ModelMemoryParser / ClipboardArchive + Prompt subsystem 6 組（PromptProfile / PromptStore / PromptComposer / BuiltinPromptCatalog / PromptMigration / LLMRefinerPromptResolution）。

**E2E gate per phase**（branch `feat/prompt-profile-skill-system`）：每個 phase 收尾跑 `scripts/e2e/phaseN_gate.sh` pass 才能進下個 phase。SwiftPM menubar app 沒 Xcode 專案 → 採 C+A 混合（side-effect 驗證 + osascript driver），D（截圖 diff）留 Phase 6 hero flow。Phase 1 gate = `swift test` + `bench_refine_prompt_ab.py --gate`（v1-store hit ≥ v1 baseline）。詳見 `plans/active/prompt-profile-skill-system.md`「E2E Gate per Phase」段。

## License

服務端程式：MIT。
模型權重：MiMo-V2.5-ASR (MIT)、carloshuang1224/MiMo-V2.5-ASR-MLX-INT4 (sub-license follows)。
