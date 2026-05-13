---
title: ZeroType-Aligned Iterative Roadmap — VoiceInputMimo
slug: zerotype-aligned-roadmap
status: draft (rev3 — 2026-05-14 user confirmed: workspace foundation first, audio retention permanent, sprint order locked)
created: 2026-05-14
revised: 2026-05-14
source: Duotify ZeroType 直播課程大綱（2026-05-15 直播 / Will 保哥）
parent_repo: ~/Documents/voice-input-mimo
related_plans:
  - plans/active/asr-engine-memory-mgmt.md
  - plans/active/local-meeting-captions.md
  - plans/active/prompt-profile-skill-system.md
  - plans/active/structure-mode-template-router.md
---

# ZeroType 對照下的 VoiceInputMimo 迭代優化 Roadmap（rev2）

## Goal

以 ZeroType 課程定義的「語音 → AI → 可交付成果」工作流為座標系，盤點 VoiceInputMimo 目前能力對應到課程 10 大 topic 的覆蓋現況，識別**未在既有 plan 中**的能力缺口，產出可以按 sprint 推進的迭代需求清單。

不重新發明 — 既有 plan 已覆蓋的部分指出歸屬，不複製內容。

## ZeroType 10 Topics（精簡）

1. 重新理解語音輸入
2. 設計從語音到成果的完整流程
3. 口語轉書面文字
4. 會議後快速整理
5. 任務口述轉待辦清單
6. 需求口述轉初步規格
7. 文章/信件/筆記產出
8. 中英混雜與專有名詞
9. 上下文輔助與 AI 修正策略
10. 建立自己的語音工作流範本

## Topic ↔ 現況覆蓋對照

| # | Topic | 現有能力 / 既有 plan | 覆蓋度 | 新需求 |
|---|---|---|---|---|
| 1 | 重新理解語音輸入 | App 本身存在，定位明確 | ✅ | — |
| 2 | 完整流程設計 | raw / refine / claudeCode 已 ship；`structure-mode-template-router` 加第 4 mode | 🟡 plan 中 | REQ-NEW-D（多步 chain） |
| 3 | 口語轉書面 | `.refine` v1.1 prompt 6/6 命中 | ✅ | — |
| 4 | 會議整理 | 短：structure-mode meeting template；長：`local-meeting-captions` 獨立 app | 🟡 plan 中 | — |
| 5 | 任務待辦 | structure-mode task template | 🟡 plan 中 | — |
| 6 | 需求規格 | structure-mode requirement template | 🟡 plan 中 | — |
| 7 | 文章/信件/筆記 | structure-mode letter + article templates | 🟡 plan 中 | — |
| 8 | 中英混雜+專名 | claudeCodeSystemPrompt hardcoded glossary | 🟢 基礎已有 | REQ-NEW-B（user-extensible） |
| 9 | 上下文輔助 | ❌ 完全沒有 | ❌ | REQ-NEW-A（**新增第 4 獨立 mode**） |
| 10 | 工作流範本 | `prompt-profile-skill-system` 多 profile + skill | 🟡 plan 中 | — |

新增需求 4 個：A（mode 4 獨立）、B（glossary workspace）、C（trace + clipboard 整合 + 長期 foundation）、D（workflow chain workspace）。

---

## Workspace UI Pattern（B / C / D 共用）

REQ-NEW-B、C、D 三個 UI 共用同一套結構，定義一次，後續引用：

| 元素 | 說明 |
|---|---|
| **Sidebar** | 左側列出 items（glossary terms / clipboard traces / workflow chains） |
| **Content Panel** | 右側顯示選中 item 的細節 |
| **Inline Editing** | 在 content panel 內 add / edit / delete，不另開 modal |
| **Render Preview** | 若有可預覽輸出，放在 content panel 底部（例：workflow 試跑一段樣本 input 看 step-by-step 結果） |

Settings 內以新一層分類「**Workspaces**」涵蓋這三者，與 General / Shortcuts / Speech / ASR Server / LLM 平級。

---

## 新增需求清單

### REQ-NEW-A：Mode 4 — Context-Aware Auto Tone Prediction（topic 9）— P1

**核心原則：獨立 mode，不污染既有 mode 行為**。

**Why**：ZeroType topic 9 要 AI 讀懂工作情境。我們**不**把 context capture 變成藏在 refine / claudeCode 內部的修飾項（會讓既有 mode 行為不穩定）。改成新增一個獨立的第 4 mode：使用者明確選這個 mode 時，app 才觀察 context、自動預測語氣、dispatch 到對應行為輸出。

raw / refine / claudeCode 三個既有 mode 行為**一律不變**。新 mode 與規劃中的 `.structure` 並列為第 4 / 5 個獨立選項（依 ship 順序）。

**Functional 接受條件**：

1. 新增 `RefineMode.contextAware` enum case；overlay HUD 顯示對應 label（如「Auto」）
2. Cycle order 加入：raw → refine → claudeCode → structure → contextAware → back to raw
3. Context capture 三類來源（mode 啟用時才抓）：
   - active app bundle id（NSWorkspace.frontmostApplication）
   - window title（AX API）
   - clipboard tail（NSPasteboard，限 8KB；含「password / secret / token / key 」自動 redact）
   - selected text（AX `AXSelectedText`）
4. 內建 tone mapping（可在 Workspace 內看 + 改，採 Workspace Pattern）：
   - `com.apple.mail` → 正式書信
   - Cursor / iTerm / Terminal → claudeCode prompt 風格
   - Slack / LINE / Messages → casual cleanup
   - Notion / Bear / Obsidian → 筆記 polish
   - Default → refine fallback
5. 與 `prompt-profile-skill-system`（既有 plan）整合：每個 profile 可宣告「在哪些 app context 下優先採用」
6. 與 REQ-NEW-B glossary 整合：context-aware mode 自動注入 glossary
7. 隱私守則：clipboard / selected text redact policy 內建於 mode（不靠使用者記得開）

**反例 / Non-goals**：

- 不修改 `.refine` / `.claudeCode` / `.structure` 任一 mode 的行為（嚴格隔離）
- 不做截圖 OCR / window 內容掃描（只看 bundle id + window title 字串）
- 不做歷史 context rolling average（單次即用即丟）

---

### REQ-NEW-B：User-extensible Glossary（topic 8）— P1

**Why**：目前 glossary hardcoded 在 `claudeCodeSystemPrompt`，新增專名（vocus / Lexical / PDT-XXXX）要重 build。換成 user-editable，採 Workspace Pattern。

**Functional 接受條件**：

1. 資料：JSON 在 App Support `Workspaces/Glossary/default.json`，shape `[{ spoken: "正字", context?: "觸發場景" }]`
2. UI：Settings → Workspaces → Glossary，採 Workspace Pattern：
   - Sidebar：詞條 list
   - Content panel：選中詞條的 inline 編輯（spoken / 正字 / 觸發場景）
   - Render preview：底部顯示「最終注入 prompt 後長這樣」的預覽
3. 預設 seed：把現有 hardcoded glossary 全部匯入作為初始資料，使用者不會掉資料
4. Profile（prompt-profile-skill-system）可宣告依賴的 glossary 子集
5. 與 REQ-NEW-A context-aware mode 自動整合
6. Import / export JSON

**反例**：

- 不做雲端共享 glossary
- 不做拼音 / 同音字自動推薦（未來再加）

---

### REQ-NEW-C：Trace-based Recording + Clipboard History 整合 — P1（升級自原 P2）

**Why**：原本只想做「先講起來放著」的 inbox。User 進一步把這當成更大藍圖的起點 — 與既有 ClipboardArchive 整合，構築一套完整的 log + history 系統，作為**長期個人語音資料 foundation** 的地基（見文末 Long-term Vision 章節）。

#### 短期 scope（本 sprint 落地）

1. **每次錄音 = 一個 independent trace**
   - Trace ID（UUID）
   - 起訖時間、duration
   - Audio file metadata（路徑、檔案大小、sample rate、ASR 結果、ASR 耗時）
   - Log entries：state transitions（start / recording / asr-done / refine-done / inject-done / archived）
   - 對應的 ClipboardArchive 條目（若有被 paste 出去）

2. **Trace ↔ Clipboard 雙向 link**
   - 從 trace 查得到「這段語音最終 paste 出來的剪貼簿內容是什麼」
   - 從 clipboard history 查得到「這條剪貼簿是從哪次語音來的、原始 audio + ASR 文字是什麼」
   - ClipboardArchive 加 `traceId` 欄位（向後相容，舊資料 nil）

3. **Workspace pane：Clipboard History**（採 Workspace Pattern）
   - Sidebar：時序列出 traces + clipboard entries（可 filter unprocessed / 已 paste / 已歸檔）
   - Content panel：選中一個 trace 顯示完整三段對照
     - 原始 audio（可播）
     - ASR transcript
     - LLM refine 結果
     - User edit 後的最終版（若有）
   - Actions：refine 重跑 / structure 變待辦 / 套不同 profile / 匯出 markdown / 刪除

4. **「先講起來放著」inbox lane**
   - 新快捷鍵（暫定 Ctrl+Opt+R）= 錄音 → ASR → 存 trace + clipboard 但**不 paste 不彈窗**
   - 在 Workspace 內以 `unprocessed` 狀態顯示

5. **Retention 設定**（user 決策 2026-05-14：資料量不大，預設永久保留）
   - Audio file：**預設永久保留**，不主動 GC
   - Trace metadata：永久
   - Unprocessed inbox：不自動歸檔，使用者手動處理
   - Settings 仍提供 retention 設定欄位（讓未來資料量爆炸時可改），但預設值為「無限」
   - 顯示用：在 Settings 顯示目前 trace 總數 + 占用空間，讓使用者知情

6. **Export**
   - JSON Lines（一行一 trace），便於外部 pipeline 消費

#### Schema 對長期 vision 的相容性要求

短期 ship 時必須滿足以下 checklist（不滿足就違反長期可組合性）：

- [ ] Audio file 預設**永久保留**（無自動 GC，符合長期訓練資料累積需求）
- [ ] Trace 含「raw ASR / LLM refine / user edit」三層（pair data 訓練用）
- [ ] Export 格式為 JSON Lines（外部 pipeline 友善）
- [ ] Clipboard 雙向 link（trace ↔ clipboard entry）
- [ ] 全 local-first（不引入雲端依賴）

#### Functional 接受條件

1. Trace data model 落地（UUID / timestamps / audio metadata / log entries / clipboard link）
2. ClipboardArchive schema migration（加 `traceId`，向後相容）
3. Workspace pane「Clipboard History」UI ship（依 Workspace Pattern）
4. Inbox lane（Ctrl+Opt+R park mode）ship
5. Export JSONL CLI 命令可用
6. Retention 設定 UI + 自動 GC daemon
7. Schema 相容性 checklist 全綠

#### 反例

- 不在本 REQ 做 personalization training（長期願景，另開 app）
- 不做 TTS（同上）
- 不做雲端 sync

---

### REQ-NEW-D：Workflow Chaining（topic 2）— P2

**Why**：多步流程，UI 採 Workspace Pattern（與 B / C 一致）。

**Functional 接受條件**：

1. Workflow data model：`{ name, steps: [{ mode, profile? }], outputPolicy: "final" | "verbose" }`
2. 儲存：`Workspaces/Workflows/*.json`
3. UI：Settings → Workspaces → Workflows，採 Workspace Pattern：
   - Sidebar：workflow chains list
   - Content panel：inline 編輯 steps（可拖曳排序、選 mode、綁 profile）
   - Render preview：底部給一段測試文字，按「試跑」看 step-by-step 輸出
4. 快捷鍵可綁定 chain 執行
5. 失敗 fallback：任一 step LLM 失敗，回退到上一 step output 並標示
6. 與 REQ-NEW-A context-aware 整合：workflow 可作為 context tone 的 dispatch 目標

**反例**：

- v1 純線性 chain，不做條件分支
- 不做 step 之間共享變數（純文字進文字出）

---

## Sprint Roadmap

### Sprint 1（P0 — ship 既有 plan）

按既有 plan 順序推進，不新開 scope：

1. **`structure-mode-template-router`** — 覆蓋 topics 4/5/6/7
2. **`prompt-profile-skill-system`** — 覆蓋 topic 10，為 A / B 提供 profile 注入點
3. **`asr-engine-memory-mgmt`** — 基礎建設，sprint 3 長錄音前置

完成標準：3 plan 各自接受條件全綠 + KB report 結案

### Sprint 2（P1 — 補 ZeroType 主要 gap + 建構 Workspace foundation）

順序鎖定（user 決策 2026-05-14）：**Step 0 → B → C → A**

#### Step 0：抽出 Workspace Pattern 共用 SwiftUI component（前置）

避免 B / C / D 三次重寫同樣 UI。產出：

- `WorkspacePane<Item>` 泛型 SwiftUI view：Sidebar + Content Panel + 可選 Render Preview
- 與既有 Settings panes 視覺一致（NavigationSplitView / Form / SectionHeading 元件對齊）
- 內建 search / filter / 排序基本元件
- B / C / D 各自只負責「Item 是什麼 + Content Panel 內怎麼編輯」

Step 0 完成標準：寫一個 Mock workspace pane（顯示 dummy items 可 add/edit/delete）通過 SwiftUI Preview + 單元測試，確認 component API 穩定後才進入 Step 1。

#### Step 1：REQ-NEW-B — User-extensible Glossary

第一個套 Workspace Pattern 的 REQ，驗證 component 設計是否好用。若 Step 0 component 在這裡用起來卡，回頭調整 component 而不是繞過。

#### Step 2：REQ-NEW-C — Trace + Clipboard 整合

套 Workspace Pattern + schema migration（ClipboardArchive 加 `traceId`）+ Inbox lane 快捷鍵。

#### Step 3：REQ-NEW-A — Mode 4 Context-Aware

用 B 提供的 glossary 注入點 + C 提供的 trace schema 作為 dispatch 接點。最後做，相依最完整。

#### Sprint 2 完成標準

- Workspace Pattern component 落地（B/C/D 都使用同一個 base）
- 三 REQ 全部通過 functional 接受條件
- Schema 相容性 checklist 全綠
- 既有 mode（raw / refine / claudeCode / structure）行為無 regression

### Sprint 3（P2 — Polish + 跨 app 擴張）

1. **`local-meeting-captions`** 獨立 app — 處理長會議
2. **REQ-NEW-D** — Workflow chaining（採已建立的 Workspace Pattern）

完成標準：local-meeting-captions 達到 MVP；REQ-NEW-D 通過接受條件

---

## Long-term Vision — 個人語音資料 Foundation

REQ-NEW-C 短期 ship 的 trace + clipboard 系統，是長期願景的地基。本願景並非本 plan 的實作範圍，記錄於此確保短期設計**不違反長期可組合性**。

### 願景

以 VoiceInputMimo 為 trigger，另開一個 app（暫名待定）做：

1. **語音資料連續捕捉**：每次中文輸入都留下 audio + ASR + refine + final 四層資料
2. **個人化 personalization**：訓練適配 user 口音 / 用詞 / 講話節奏的 model（local-first）
3. **English learning lane**：用累積的 ZH↔EN pair 自動找出 user 常卡的表達，做針對性練習
4. **TTS 反向**：學會用 user 的習慣語氣產出 text-to-speech
5. **High-level plan writing assistant**：以此基礎，做 AI 助手幫 user 寫 plan

### 短期設計檢查項（重申）

REQ-NEW-C 短期 ship 必須滿足：

- Audio file 不主動刪（retention 設定可配）
- Trace schema 含 raw ASR / LLM refine / user edit 三層
- Export 格式為 JSON Lines
- Clipboard 雙向 link
- 全 local-first

長期 app 開展時，本 plan 已備妥 pair data 與 audio archive 作為訓練資料源，無需 retrofit。

---

## 「免費仔」對照

| 環節 | 現況 | 成本 |
|---|---|---|
| ASR | local MLX server（mimo-asr int4）on :8766 | 0 |
| LLM refine | local qwen3-8b-mlx on :8082 | 0 |
| Text injection | macOS native NSPasteboard + AX API | 0 |
| Storage | local JSON / SQLite | 0 |
| Trace + Audio archive（REQ-NEW-C） | local file system | 0（只佔硬碟） |

VoiceInputMimo 已是「全本機免費」實作。本 roadmap 不引入任何雲端付費依賴。

---

## 不做的事（Out of Scope）

- 不做雲端同步
- 不做截圖/OCR context
- 不做語音指令 NLU（dictation ≠ voice assistant）
- 不做 iPhone app（限 macOS）
- 不做訓練自己的 ASR / LLM model（用既有 mimo-asr / qwen3-8b-mlx）
- Long-term Vision 願景內容不在本 plan 範圍（短期只確保資料 schema 相容）

---

## 已確認決策（2026-05-14）

- ✅ **Workspace Pattern 共用 SwiftUI component**：先抽（Sprint 2 Step 0），B/C/D 共用 base
- ✅ **Audio retention**：預設**永久保留**，不主動 GC（資料量不大 + 對齊長期 vision 訓練資料需求）
- ✅ **Sprint 2 順序**：Step 0（Workspace foundation）→ B（glossary）→ C（trace + clipboard）→ A（context-aware mode）
- ✅ **Sprint 1 順序**：Sequential — structure-mode-template-router → prompt-profile-skill-system → asr-engine-memory-mgmt
- ✅ **REQ-NEW-A AX 權限策略**：漸進式 onboarding（首次切到 Mode 4 才提示 AX 授權；未授權 fallback 到 refine 並標示原因）

## 待確認決策

（無 — 所有設計層級決策已敲定，剩下細節在實作時於各 plan 內處理）

---

## Next Action

請就以下任一項回覆：

- **「Sprint 1 開始」** → 我等你選定哪個 plan 先實作
- **「先做 Workspace Pattern foundation」** → 我抽出共用 SwiftUI component 作為 Sprint 2 前置（建議路徑）
- **「先做 REQ-NEW-A 跳過既有 plan」** → 直接做 context-aware mode（與既有 plan 平行）
- **「再 refine roadmap」** → 指出要拆細 / 合併 / 移除的項目
- **「sprint 排序調整」** → 提新順序，我重排
