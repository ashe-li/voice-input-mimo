# voice-input-mimo

按住 **Fn 鍵**講話 → 自動轉錄 + LLM 後處理 → 貼到游標位置。

跟一般語音輸入差別：

- **ASR 用 [MiMo-V2.5-ASR](https://github.com/XiaomiMiMo/MiMo-V2.5)**（Xiaomi 開源）— 原生支援中英 code-switching，`LLM` / `API` / `React` / `component` 不會再被聽成「L M K」「A屁I」「瑞克特」「康波奶特」
- **同一段口述輸入，可切 4 種輸出模式：**
  - 中文 ASR 原文（最快，無 LLM 後處理）
  - 中文 LLM 修正（去口語雜質、不改意思）
  - 英文翻譯（口述中文 → 英文，給 Claude Code / Cursor 之類用）
  - 中文 複合情境（依關鍵字自動分流到會議紀錄 / 任務清單 / 需求草稿 / 信件 / 文章 5 種模板）
- **prompt 完全可客製化** — Settings → Prompts 自己編 Profile 和 Skill，不用改程式碼

---

## ⚠️ 你需要準備的東西

這個 app 只是**前端**（錄音 + 貼上），它打**單一統一入口**：[local-llm-backend](https://github.com/junkboy0315/local-llm-backend) gateway（OpenAI-compatible，本機 `:4000`）。gateway 後面再 fan-out 到實際的 ASR / LLM backend。

| Service | 預設 endpoint | 用途 |
|---|---|---|
| local-llm-backend gateway | `http://127.0.0.1:4000` | ASR (`/v1/audio/transcriptions`) + LLM (`/v1/chat/completions`) 統一入口 |
| MiMo ASR sidecar（這個 repo 內附） | `http://127.0.0.1:8766` | gateway 的 ASR upstream；`make server-start` 或 app 第一次啟動會自動 spawn |
| LLM backend（任意 OpenAI-compatible） | gateway 設定中指定 | 推薦 [Rapid-MLX](https://github.com/junkboy0315/rapid-mlx) on `:8082`；ollama / vLLM 也行 |

第一次跑 ASR sidecar 會下載 ~4.5 GB 的 INT4 MLX model 到 `~/.cache/mimo-asr/`（之後 cache 住）。LLM model 自己挑，建議 Qwen3-8B 或同等級以上。

> **舊版資訊**：v1 預設直連 ASR sidecar `:8766` 和 LLM backend `:8082/v1`，跳過 gateway。v2+ 改走 gateway。要回到直連，覆寫 `defaults write com.shiun.VoiceInputMimo asrBaseURL "http://127.0.0.1:8766"` + `llmAPIBaseURL "http://127.0.0.1:8082/v1"`。

---

# 使用者文件

## 安裝（macOS）

> ⚠️ DMG 是 **self-signed**（沒做 Apple Notarization），第一次要手動繞過 Gatekeeper。

從 [GitHub Releases](../../releases) 下載最新 `VoiceInputMimo-<版本>.dmg`，雙擊掛載：

1. 把 `VoiceInputMimo.app` 拖到 `Applications`
2. **第一次打開** — 右鍵 `VoiceInputMimo.app` → **打開** → 警告視窗按 **打開**
   （或：系統設定 → 隱私權與安全性 → 滑到底找到被擋的訊息 → **仍要打開**）
3. **授權** — app 會要兩個權限，都要給：
   - **麥克風**（Microphone）— 用來錄音
   - **輔助使用**（Accessibility）— 用來監聽 Fn 鍵
4. （可選）**自動啟動** — 系統設定 → 一般 → 登入項目，把 VoiceInputMimo 加進去

DMG 內附 `README-INSTALL.txt`（中英雙語）有同樣的步驟。

## 操作

### 錄音（基本流程）

按住 **Fn 鍵** → 講話 → 放開 → app 把處理結果自動貼到游標所在位置。

錄音中螢幕底部會出現一條 overlay 顯示狀態（Listening → Refining → 完成的中／英文預覽）。

### 切換輸出模式

四個模式擇一啟用，快慢／用途差很多：

| 模式 | 速度 | 用途 |
|---|---|---|
| **中文 ASR 原文** | 最快（不打 LLM） | 即時筆記、純中文輸入 |
| **中文 LLM 修正** | 快（小 LLM call） | 會議發言貼上、口齒不清的中文 cleanup |
| **英文翻譯** | 中（一次 LLM call） | 給 Claude Code / Cursor / 英文 PR description |
| **中文 複合情境** | 中～慢（template 較長） | 把口述展開成會議紀錄 / 任務清單 / 需求草稿 / 信件 / 文章 |

兩種切換方式：

- **快捷鍵**：`fn + →` / `fn + ←` 在 4 個模式間輪轉切換
- **狀態列選單**：點選單列上的 mic 圖示 → **輸出模式** 子選單直接挑

當前模式會顯示在 menu bar 圖示旁的標題（例：`輸出模式：英文翻譯`）。

### 複合情境的自動路由

選「中文 複合情境」後，[`StructureRouter`](Sources/VoiceInputMimo/Prompts/StructureRouter.swift) 會看 ASR 出來的中文內容裡有哪些關鍵字，自動選 template：

| 你說了什麼 | 它選哪個 template |
|---|---|
| 「會議結論…」「行動項…」「下次開會…」 | meeting（會議紀錄） |
| 「TODO…」「我要做…」「下週要…」 | task（任務清單） |
| 「使用者要…」「需求是…」「驗收條件…」 | requirement（需求草稿） |
| 「親愛的…」「Dear…」「敬上…」 | letter（信件） |
| 一般敘事、發想、想法 | article / fallback |

5 個模板都是 builtin profile，可以在 Settings → Prompts 改 prompt 或加自己的版本。沒匹配關鍵字會走 fallback 通用 polish。

### Prompt 客製化

`Settings → Prompts`：

- **Profiles** — 三類（Refine / ClaudeCode / Structure）各自獨立，每類都可以新增/編輯
- **Skills Library** — Profile 由 N 個 Skill compose 出來（例：`output-english-only` + `recover-en-cn-homophones` + `drop-fillers`）
- **匯入/匯出** — JSON bundle，可以分享給隊友或備份

12 個 builtin skills 不能改但可以複製，9 個 builtin profiles 同理。

### Glossary（專有名詞詞庫）

`Settings → Workspace → Glossary`：保留 LLM 容易誤翻 / 誤判的專有名詞（公司名、產品名、內部 repo、雲端 brand）。

- 每筆條目：`spoken`（ASR 可能輸出形）→ `canonical`（正確形）+ `context`（給 LLM 的提示）
- 開機時自動 inject 進 LLM system prompt 的「## Glossary」section
- **匯入/匯出** — JSON 格式，merge-by-id：同 id 取代、新 id 追加
- 範例：`focus → vocus`、`carpenter → Karpenter`、`cloud flare → Cloudflare`

### 其他快捷鍵

| 鍵 | 功能 |
|---|---|
| `fn`（按住） | 錄音 |
| `Ctrl + Option + →` / `Ctrl + Option + ←` | 切換輸出模式（cycle raw / refine / claudeCode / structure） |
| `Ctrl + Option + R`（按住） | Park mode — 錄音 + 存 trace + 存 Clipboard History，**不貼上**（給「先講起來放著」場景） |
| `⌘ + ,` | 開 Settings |
| `⌘ + ⌥ + H` | Clipboard History（看歷次轉錄結果） |
| `⌘ + ⌥ + M` | Model Memory monitor（看 ASR / LLM 模型 RSS） |

錄音熱鍵可在 `Settings → Shortcuts` 改（5 個 preset：Disabled / Fn / Control+Option+Space / Control+Option+V / Command+Shift+Space），primary + secondary 兩條獨立綁定。Ctrl+Option 系列的 cycle / park 各自有獨立 toggle，預設都開啟。

### Trace 紀錄

每次錄音會在 `~/Library/Application Support/VoiceInputMimo/workspaces/traces/traces.jsonl` 累積一筆 trace entry：ASR / LLM / final 三層文字 + 各 stage 時間 log + 對應的 Clipboard 時間戳。Clipboard History detail strip 會顯示對應的 `Trace: trace-xxxxxxxx` 連結。Park mode 的 trace 帶 `mode=park` 標記。

---

# 開發者文件

## 系統需求

- macOS 14+（Sonoma 以上）— 新版 SwiftUI Hybrid 用到 `@Observable` macro
- Xcode 16+ 的 toolchain（`swift build`）
- Python 3.12（給 ASR engine）
- Apple Silicon 強烈推薦（MLX 跑得順）

## 從原始碼 build

```bash
git clone https://github.com/ashe-li/voice-input-mimo.git
cd voice-input-mimo

make cert-setup     # 一次性，建立本地 self-signed code-signing cert
                    # （讓 macOS TCC 跨 rebuild 記得權限）
make build          # 編譯 + 簽名 → ./VoiceInputMimo.app
make install        # 上面 + 複製到 /Applications/

# ASR engine
cd engine
pip install -r requirements.txt   # 或 uv sync
cd ..
make server-start                 # 背景啟動 ASR engine on :8766
```

`cert-setup` 完後**第一次** `make build` 會跳一個 SecurityAgent 對話框問「codesign 想用 private key」— 點 **Always Allow** 一次，後面 build/install/dmg 都靜默。沒跑 `cert-setup` 的話 `make build` 會 fallback 到 ad-hoc 簽（每次 install TCC 會 reset，不推薦）。

## 打 release DMG

```bash
make dmg                         # 產 dist/VoiceInputMimo-<date>-<sha>.dmg
VERSION=1.2.3 make dmg           # 自訂版本號
```

DMG 自帶 Applications symlink（拖拉安裝）+ 雙語 README-INSTALL.txt。簽名沿用 `make build` 用的 cert，App + DMG 用同 identity 保持一致。

> ⚠️ **這個 DMG 不是 Apple Notarized**。下載者第一次打開要右鍵 → 開啟。要做正式 Notarization 需要 Apple Developer ID（$99/year）— 等有 traction 再做。

## Server API

ASR engine 是 OpenAI Whisper-compatible：

| Method | Path | 說明 |
|---|---|---|
| `GET` | `/v1/health` | 健康檢查 + loaded models + zhtw rules count |
| `GET` | `/v1/models` | 列已掛載 models |
| `POST` | `/v1/audio/transcriptions` | 上傳音檔 → 文字 |
| `GET` | `/admin/memory` | 模型 RSS / Metal active / cache snapshot |

`POST /v1/audio/transcriptions` multipart 欄位：

- `file`（必填）— wav / aiff / mp3 等
- `language`（可選）— `auto`（預設）/ `zh` / `en`
- `response_format`（可選）— `json`（預設）/ `text`
- `output_locale`（可選）— `zh-TW`（預設，做簡→繁 + IT 詞彙轉換）/ `none`

回應範例：

```json
{
  "text": "幫我重構這個軟體的閘道器設定",
  "raw_text": "帮我重构这个软件的网关设置",
  "language": "auto",
  "output_locale": "zh-TW",
  "duration_ms": 1768
}
```

`raw_text` 只在 post-process 改變內容時才出現（簡→繁 / IT 詞彙轉換）。post-process 用 OpenCC `s2twp` + [sysprog21/zhtw-mcp](https://github.com/sysprog21/zhtw-mcp) ruleset。

## 環境變數（ASR engine）

| Var | 預設 | 說明 |
|---|---|---|
| `MIMO_PRECISION` | `int4` | `bf16` 品質微高、顯存翻倍 |
| `MIMO_MODEL_ROOT` | `~/.cache/mimo-asr` | 模型存放位置 |
| `MIMO_PRELOAD` | `0` | `1` = 啟動就 load（首次啟動慢但首請求快） |
| `MIMO_DEFAULT_LANGUAGE` | `auto` | 缺省語言 hint |
| `PORT` | `8766` | HTTP port（舊版是 8765，UserDefaults 一次性 migrate） |

## 開發 / 預覽快速通道

跳過 install + 重簽 + TCC re-grant：

```bash
VOICE_INPUT_MIMO_PREVIEW=1 swift run
```

開 regular activation policy、自動開 Clipboard History + Model Memory window 並注入 sample archive、跳過 LocalASRServer 啟動。改 SwiftUI view 用這個迭代最快。

也可以用 `VOICE_INPUT_MIMO_ARCHIVE_PATH=<path>` 把 clipboard archive 指向沙盒檔，不污染正式資料。

## 架構

```
voice-input-mimo/
├── engine/                       ASR FastAPI（MiMo-V2.5 + adaptive idle ladder + Qwen cache poll）
├── server/                       baseline 版（fixed idle，保留作對照）
├── Sources/VoiceInputMimo/       Swift app（SwiftUI Hybrid：AppKit 殼 + SwiftUI 內容）
│   ├── Prompts/                  Profile / Skill 系統 — JSON store + builtin catalog + import/export
│   ├── Settings/                 NavigationSplitView + 7 panes（含 Prompts / History sub-views）
│   ├── History/                  ClipboardHistoryView（單 List + Picker + detail strip）
│   ├── UI/Components/            5 共用元件（HostingWindow / SectionHeading / CardModifier / ...）
│   ├── *Window.swift             thin NSWindow shells（Settings / ClipboardHistory / ModelMemory）
│   ├── AppDelegate.swift         status menu + 4-mode 切換 + fn-arrow cycle
│   ├── KeyMonitor.swift          CGEventTap：Fn 錄音 + fn+← / fn+→ cycle
│   ├── OverlayPanel.swift        + OverlayContentSwiftUI.swift — Phase enum 驅動的 overlay
│   ├── LLMRefiner.swift          3-mode dispatch（refine / claudeCode / structure）
│   └── Refining.swift, ASRClient.swift, AudioRecorder.swift, TextInjector.swift
├── Tests/VoiceInputMimoTests/    177 個 unit test（資料層 + ViewModel 層；SwiftUI body 不寫 unit）
├── scripts/e2e/                  acceptance gates
└── plans/                        設計與規劃 markdown
```

**關鍵設計**：

- **SwiftUI Hybrid** — Window/Panel/Status menu 留 AppKit（NSPanel `.popUpMenu` level、NSTrackingArea hover、CALayer 陰影），內容用 SwiftUI 寫（`@Observable` ViewModel + `NSHostingView` 橋接）。Settings / ClipboardHistory / Overlay 三個都是這個 pattern。
- **Prompt 三層 fallback** — Profile（user）→ UserDefaults override → hardcoded builtin。任何一層 missing 都不會 crash。Profile 由 N 個 Skill compose（append-mode），每個 Skill 是 reusable text fragment。
- **Structure router 純 Swift** — 不打 LLM 做 routing decision（節省一次 call）。每個 template 是獨立 profile，可單獨 tune。未來可換 LLM-based router 不破壞 profile 結構。
- **`active.json` Codable migration** — 加新 RefineMode case 時舊 JSON 自動補預設值（custom `init(from:)` + `decodeIfPresent`）。

## Tests

```bash
swift test                       # 全部 unit（177 個）

# E2E phase gates（依序跑，每個 pass 才能進下個）
make e2e-phase1                  # 資料層 + bench harness
make e2e-phase2                  # SwiftUI Hybrid 共用元件
make e2e-phase3                  # SettingsWindow（thin shell + 7 panes）
make e2e-phase4                  # Prompts pane（profiles + skills + import/export）
make e2e-phase5                  # ClipboardHistory cards
make e2e-phase6                  # 啟動 wiring + status menu profile switcher
```

`Tests/VoiceInputMimoTests/` 涵蓋：

- **資料層** — ShortcutBinding / ModelMemoryParser / ClipboardArchive / PromptProfile / PromptStore / PromptComposer / BuiltinPromptCatalog / PromptMigration / LLMRefinerPromptResolution / PromptIO / StructureRouter
- **ViewModel** — PromptStoreViewModel / SettingsViewModel / PromptsPaneViewModel / ClipboardArchiveViewModel

SwiftUI view body 本體不寫 unit test — 邏輯內聚於 `@Observable` ViewModel，view body 走 `#Preview` 開發迭代。SwiftPM menubar app 沒 Xcode 專案 → e2e gate 採 C+A 混合（side-effect 驗證 + osascript driver）。

## License

- App + server: MIT
- 模型權重 — MiMo-V2.5-ASR (MIT)、carloshuang1224/MiMo-V2.5-ASR-MLX-INT4（sub-license follows）
- 你選的 LLM backend 看你怎麼挑（建議 Qwen3 系列 / Llama 系列 / 任何 Apache-2.0 或 MIT 的開源 model）

bundle id `com.shiun.VoiceInputMimo` 與 [Apple Speech 版（voice-input-src）](../voice-input-src) 並存可同時 install，TCC 各自獨立。
