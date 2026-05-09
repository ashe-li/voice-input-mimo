---
title: Prompt Profile + Skill 客製化系統 — Implementation Plan
slug: prompt-profile-skill-system
status: draft
created: 2026-05-10
worktree: TBD（會在實作前再詢問）
branch: feat/prompt-profile-skill-system
parent_repo: ~/Documents/voice-input-mimo
related_kb:
  - knowledge-base/reports/2026-05-10-voice-input-mimo-refine-prompt-v1-and-overlay-mode-bug.md
  - knowledge-base/wiki/patterns/llm-refine-prompt-conservative-clause-blocks-filler-cleanup.md
  - knowledge-base/wiki/patterns/llm-translation-prompt-speech-act-preservation.md
  - knowledge-base/wiki/patterns/small-model-prompt-tuning-priority-examples-over-rules.md
---

# Prompt Profile + Skill 客製化系統 — Implementation Plan

## Goal

讓使用者能客製化「中文 LLM 修正」與「英文 Prompt（claudeCode）」兩個模式的 system prompt：
1. 多個命名 Profile，可即時切換
2. 把 prompt 拆成可重用 Skill snippet，自由堆疊組合
3. JSON 檔存於 App Support，可 import/export 分享、可 dotfile 同步
4. Settings UI 編輯 + 預覽 + 測試
5. Status menu 一鍵切 active profile

## Why

**現況限制**：
- `LLMRefiner.swift:71-104` / `:106-131` 兩個 system prompt 寫死在 source。要改就得重 build。
- 雖然 UserDefaults `refineSystemPrompt` / `claudeCodeSystemPrompt` 提供 hot-swap，但只能放整段 prompt，無法重組
- 沒有命名／分享／版控機制

**已落地的 v1.1 修正 prompt** 證明 prompt 改動可以大幅改變表現（v0 命中 2/6 → v1.1 命中 6/6，詳見 related_kb 報告）。把這套迭代能力交還給使用者是合理的下一步。

**使用情境**：
- 「正式信件中文修正」（更嚴格保留語氣）vs「程式描述中文修正」（容許 stutter cleanup 加碼）vs 預設
- 「英文 Prompt for Claude Code」vs「英文 Prompt for ChatGPT」（不同 reply 語言要求 / 不同 verbosity）
- 分享別人寫好的 profile：直接 import JSON

## 已確認決策（HITL）

| # | 抉擇 | 選項 |
|---|---|---|
| 1 | Storage | JSON 檔在 App Support，UserDefaults 作 fallback |
| 2 | Composition | 兩種都支援：簡單 append + slot 模板（v1 先 append，slot 在 v1.5 開放）|
| 3 | Bundled defaults | 出廠拆成多個 skill + 預設 profile，使用者可重組 |

## 資料模型

### Profile

```swift
struct PromptProfile: Codable, Identifiable, Equatable {
    let id: String              // UUID 或 slug
    var name: String            // "Default Refine"、"Formal Letter"
    var mode: RefineMode        // .refine | .claudeCode
    var basePrompt: String      // 主 prompt（slot 模板用 {{slotName}} 標記）
    var skillIDs: [String]      // 已啟用的 skills，依序組合
    var suffix: String?         // 取代 claudeCodeSuffix；nil 代表 no suffix
    var modelOverride: String?  // 不為 nil 則覆寫全域 model
    var temperature: Double?    // 不為 nil 則覆寫
    var displayLabel: String?   // overlay 顯示「修中文」「翻英文」「正式信件」
    var slotOverrides: [String: String]?  // slot 模式：使用者直接填的 slot 內容（v1.5）
    var createdAt: Date
    var updatedAt: Date
    var isBuiltin: Bool         // 出廠 profile 不可刪、可 duplicate
}
```

### Skill

```swift
struct PromptSkill: Codable, Identifiable, Equatable {
    let id: String
    var name: String            // "Drop verbal fillers"、"Stutter collapse"
    var category: SkillCategory // .recovery | .style | .format | .domain | .speechAct
    var content: String         // 該 snippet 文字
    var slot: String?           // slot 模式專用（如 "recovery_rules"）
    var description: String?    // UI hint，便於選擇
    var isBuiltin: Bool
}

enum SkillCategory: String, Codable, CaseIterable {
    case recovery     // ASR 錯字修正
    case style        // 語氣/語體
    case format       // 輸出格式
    case domain       // 領域詞彙
    case speechAct    // 語意意圖偵測
}
```

### ActiveSelection

```swift
struct ActiveSelection: Codable {
    var refineProfileID: String
    var claudeCodeProfileID: String
}
```

## Storage 配置

```
~/Library/Application Support/VoiceInputMimo/prompts/
├── profiles/
│   ├── refine/
│   │   ├── default.json
│   │   └── <user-uuid>.json
│   └── claudeCode/
│       ├── default.json
│       └── <user-uuid>.json
├── skills/
│   ├── builtin-drop-fillers.json
│   ├── builtin-collapse-stutter.json
│   ├── builtin-recover-en-cn-homophones.json
│   ├── builtin-speech-act-detection.json
│   ├── builtin-style-preserve-identifiers.json
│   ├── builtin-output-english-only.json
│   └── <user-uuid>.json
└── active.json
```

**Fallback 順序**（read）：
1. JSON 檔
2. UserDefaults（migration / legacy）
3. Hardcoded `defaultRefinePrompt` / `defaultClaudeCodePrompt`

寫入永遠走 JSON。

## Bundled defaults（拆 skill）

把目前 `LLMRefiner.swift:71-131` 兩個 hardcoded prompt 拆成這些 builtin skills：

| Skill ID | Category | 來源 | 適用 mode |
|---|---|---|---|
| `builtin-drop-fillers` | style | v1 prompt `Drop verbal fillers` 段 | refine, claudeCode |
| `builtin-collapse-stutter` | recovery | v1 prompt `Collapse immediate stutter` 段 | refine, claudeCode |
| `builtin-recover-en-cn-homophones` | recovery | `配森→Python` 等 | refine, claudeCode |
| `builtin-speech-act-detection` | speechAct | claudeCode prompt `Speech act detection` 段 | claudeCode |
| `builtin-style-preserve-identifiers` | style | claudeCode prompt `Style` 段 | claudeCode |
| `builtin-output-english-only` | format | claudeCode prompt `Output ONLY the translation...` | claudeCode |
| `builtin-output-same-language` | format | refine prompt `Output the SAME LANGUAGE` | refine |
| `builtin-no-rephrase` | style | refine prompt `Never rephrase / synonyms` 段 | refine |

並提供兩個 builtin profile：

- **Default Refine** = `[output-same-language, drop-fillers, collapse-stutter, recover-en-cn-homophones, no-rephrase]` + few-shot examples（保留在 basePrompt）
- **Default ClaudeCode** = `[speech-act-detection, recover-en-cn-homophones, drop-fillers, collapse-stutter, style-preserve-identifiers, output-english-only]`

## Composition（v1：append；v1.5：slot）

### v1 — append 模式

```
finalSystemPrompt =
  basePrompt
  + "\n\n" + skill_1.content
  + "\n\n" + skill_2.content
  + ...
  + (basePrompt 內若有 examples 段保留在最後)
```

skillIDs 順序即組合順序（UI 拖拉排序）。

### v1.5 — slot 模板

```
basePrompt 內可寫：
  /no_think You clean up Chinese ASR.
  
  Always fix:
  {{recovery_rules}}
  {{style_rules}}
  
  Never:
  {{never_rules}}

每個 skill 可選地 declare 自己屬於哪個 slot：
  Skill { name: "Drop fillers", slot: "style_rules", content: "- Drop ..." }

渲染時：
  - 有 slot 的 skill 填入對應 slot
  - 無 slot 的 skill 在 basePrompt 末尾 append（與 v1 行為一致）
  - slot 在 basePrompt 內未被填入則保留為空（不顯示 placeholder）
```

向下相容：純 append 的 profile 在 v1.5 仍可運作（沒 slot 標記就走 append path）。

## UI 表面

### Settings 視窗新分頁「Prompt Profiles」

```
┌─────────────────────────────────────────────────────────────┐
│ Refine Profiles  ClaudeCode Profiles  Skills Library        │
├─────────────────────────────────────────────────────────────┤
│ ▾ Default Refine ★            │ Name  [Default Refine    ]  │
│   My Formal Profile            │ Mode  [Refine ▼]            │
│   [+ New] [Duplicate] [Del]   │                              │
│                                │ Base Prompt:                 │
│                                │ ┌──────────────────────────┐│
│                                │ │ /no_think You clean...    ││
│                                │ └──────────────────────────┘│
│                                │                              │
│                                │ Skills (drag to reorder):    │
│                                │ ☑ Drop verbal fillers       │
│                                │ ☑ Collapse stutter          │
│                                │ ☐ Recover EN-CN homophones │
│                                │ [+ Add Skill]                │
│                                │                              │
│                                │ Suffix: [_____________]      │
│                                │ Model:  [_____________]      │
│                                │                              │
│                                │ [Preview] [Test ▶]          │
└─────────────────────────────────────────────────────────────┘
```

- ★ 標記目前 active profile
- 「Test」面板：貼一段 ASR 文字 → 用此 profile 跑一次 LLM → 顯示結果與 token 估算
- 「Preview」展開渲染後完整 prompt（讓使用者看 skill append 後實際樣子）
- builtin profile 不可 Delete，但可 Duplicate 為使用者 profile

### Skills Library 子分頁

```
┌──────────────────────────────────────┐
│ [All ▼]  [+ New Skill]               │
├──────────────────────────────────────┤
│ Drop verbal fillers       (style)    │
│ Collapse stutter          (recovery) │
│ Recover EN-CN homophones  (recovery) │
│ ...                                   │
└──────────────────────────────────────┘
```

點擊進入編輯器：name / category / slot / content / description。builtin skill 唯讀（可 Duplicate）。

### Status menu

在「輸出模式」子選單下，每個 mode 後面加箭頭，hover 出現 profile 列表：

```
輸出模式：英文 Prompt ▸    Active Profile ▸  ✓ Default ClaudeCode
                                              My Custom Profile
                                              ───
                                              Edit Profiles…
```

### Import / Export

- Settings 右下角 `[Export ▼]`：選 single profile / all profiles / skills only / everything → 寫成單一 `.json` bundle
- `[Import…]`：讀 JSON，遇到 ID 衝突 prompt「Replace / Rename / Skip」

## Migration

第一次啟動偵測到 `prompts/` 目錄不存在：

```swift
func bootstrap() {
    let dir = appSupportPromptsDir()
    guard !FileManager.default.fileExists(atPath: dir.path) else { return }
    
    // 1. Write builtin skills (8 個)
    for skill in BuiltinPromptSkill.all { write(skill) }
    
    // 2. Build Default Refine + Default ClaudeCode profiles
    write(BuiltinPromptProfile.defaultRefine)
    write(BuiltinPromptProfile.defaultClaudeCode)
    
    // 3. 如果 UserDefaults 有 refineSystemPrompt / claudeCodeSystemPrompt
    //    覆蓋（使用者改過）→ 多建一個 "Imported from defaults" profile
    if let custom = UserDefaults.standard.string(forKey: "refineSystemPrompt"),
       custom != defaultRefinePrompt {
        write(makeImportedProfile(mode: .refine, content: custom))
    }
    // ditto for claudeCode
    
    // 4. active.json 指向 Default Refine / Default ClaudeCode
    write(ActiveSelection(...))
}
```

UserDefaults 的 `refineSystemPrompt` / `claudeCodeSystemPrompt` 在 migration 後不再被 LLMRefiner 直接讀取，但保留 key 不刪、設置為 read-only fallback（萬一 prompts/ 損毀）。

## v1 / v1.5 / v2 切割

| 功能 | v1 | v1.5 | v2 |
|---|---|---|---|
| Profile / Skill JSON CRUD | ✅ | | |
| Append composition | ✅ | | |
| Slot 模板 | | ✅ | |
| Settings UI（profiles tab）| ✅（基礎）| ✅（slot editor）| |
| Skills Library tab | ✅ | | |
| Status menu profile 切換 | ✅ | | |
| Test panel（跑一次 LLM 看結果）| ✅ | | |
| Preview rendered prompt | ✅ | | |
| Token 估算 | ✅（簡單字元/4）| ✅（精確 tokenizer）| |
| Import / Export JSON | ✅ | | |
| Profile 熱鍵切換（⌘⌥1/2/3） | ✅ | | |
| Per-app override | | | ✅ |
| iCloud sync | | | ✅ |
| Skill marketplace | | | ✅ |

## File-level changes（v1）

### 新增

**Prompts 邏輯層**

| 檔案 | 內容 |
|---|---|
| `Sources/VoiceInputMimo/Prompts/PromptProfile.swift` | Profile / Skill / ActiveSelection 結構 + Codable |
| `Sources/VoiceInputMimo/Prompts/PromptStore.swift` | JSON CRUD + atomic write + fallback chain |
| `Sources/VoiceInputMimo/Prompts/PromptComposer.swift` | append 渲染（v1.5 加 slot）+ token 估算 |
| `Sources/VoiceInputMimo/Prompts/BuiltinPromptCatalog.swift` | 8 個 builtin skill + 2 個 builtin profile |
| `Sources/VoiceInputMimo/Prompts/PromptMigration.swift` | bootstrap + UserDefaults import |

**UI 共用元件**

| 檔案 | 內容 |
|---|---|
| `Sources/VoiceInputMimo/UI/VibrantWindow.swift` | NSVisualEffectView 統一 helper |
| `Sources/VoiceInputMimo/UI/SectionHeading.swift` | 22pt bold 區段標題 |
| `Sources/VoiceInputMimo/UI/RoundedCard.swift` | 12/16 px 圓角 + padding 容器 |
| `Sources/VoiceInputMimo/UI/SidebarList.swift` | macOS sidebar 風 NSOutlineView wrapper |
| `Sources/VoiceInputMimo/UI/IconButton.swift` | SF Symbol toolbar 按鈕 |

**Settings 分頁與面板**（NSSplitViewController-based）

| 檔案 | 內容 |
|---|---|
| `Sources/VoiceInputMimo/Settings/SettingsRootController.swift` | NSSplitViewController + sidebar nav |
| `Sources/VoiceInputMimo/Settings/Panes/GeneralPane.swift` | General 分頁 |
| `Sources/VoiceInputMimo/Settings/Panes/ShortcutsPane.swift` | 從 SettingsWindow 抽出 |
| `Sources/VoiceInputMimo/Settings/Panes/SpeechPane.swift` | 從 SettingsWindow 抽出 |
| `Sources/VoiceInputMimo/Settings/Panes/ASRServerPane.swift` | 從 SettingsWindow 抽出 |
| `Sources/VoiceInputMimo/Settings/Panes/PromptsPane.swift` | A 區：profile 編輯三欄 |
| `Sources/VoiceInputMimo/Settings/Panes/HistoryPane.swift` | B 區內嵌（共用 ClipboardHistoryView）|
| `Sources/VoiceInputMimo/Settings/Panes/AboutPane.swift` | About / 版本資訊 |
| `Sources/VoiceInputMimo/Settings/Components/ProfileSidebar.swift` | A 區左欄 |
| `Sources/VoiceInputMimo/Settings/Components/ProfileEditor.swift` | A 區中欄 |
| `Sources/VoiceInputMimo/Settings/Components/PromptTestPanel.swift` | A 區右欄（input + run + history）|
| `Sources/VoiceInputMimo/Settings/Components/SkillsLibraryView.swift` | Skills Library 子分頁 |
| `Sources/VoiceInputMimo/Settings/Components/ClipboardHistoryView.swift` | B 區共用 view（embed 在 HistoryPane + 獨立 window）|

**Tests**

| 檔案 | 內容 |
|---|---|
| `Tests/VoiceInputMimoTests/PromptStoreTests.swift` | CRUD + 並行寫入 + corruption recovery |
| `Tests/VoiceInputMimoTests/PromptComposerTests.swift` | append 渲染、邊界 case |
| `Tests/VoiceInputMimoTests/PromptMigrationTests.swift` | UserDefaults → JSON migration |
| `Tests/VoiceInputMimoTests/PromptTestHistoryTests.swift` | history 容量上限、序列化 |

### 修改

| 檔案 | 改動 |
|---|---|
| `Sources/VoiceInputMimo/LLMRefiner.swift` | `refine()` 改成 `let profile = PromptStore.shared.activeProfile(for: mode)` → 渲染 → 用 profile 的 model/temp/suffix 覆寫 |
| `Sources/VoiceInputMimo/SettingsWindow.swift` | **整個重寫**為 SettingsRootController bootstrap（保留入口 API：`openSettings()`），平鋪 form 拆到各 Pane |
| `Sources/VoiceInputMimo/ClipboardHistoryWindow.swift` | 改用 `ClipboardHistoryView`（NSCollectionView card list + sidebar），保留 NSPanel 入口 API |
| `Sources/VoiceInputMimo/AppDelegate.swift` | 「輸出模式」子選單加 profile 切換；Overlay phase 用 profile.displayLabel + name |
| `Sources/VoiceInputMimo/OverlayPanel.swift` | `.refining(translating:)` → `.refining(label: String)`（含 profile 名）|

## Test 策略（TDD）

依 user CLAUDE.md「寫測試先於實作；80% 最低覆蓋率」：

1. **PromptStore**：write/read round-trip、不存在的 ID、corrupted JSON 還原、concurrent write atomic 性
2. **PromptComposer**：空 skills、單 skill、多 skill 順序、slot 不存在、slot 重複、basePrompt 含 examples 段
3. **PromptMigration**：fresh install、有 UserDefaults override、prompts/ 部分存在、prompts/ 損毀
4. **整合**：LLMRefiner.refine() with 自訂 profile vs builtin → 對既有 6-case backtest 結果不退步
5. **UI smoke**：Settings 開／關／新增 profile／切換 active／export / import round-trip

延伸 backtest harness：`scripts/bench_refine_prompt_ab.py` 改成讀 PromptStore 兩個 profile 比較，而非 hardcoded 兩段 prompt。

## Risks

| Risk | 緩解 |
|---|---|
| 使用者堆太多 skill → 爆 token / 變慢 | Preview 顯示 token 估算 + warning > 1000 tokens |
| JSON 檔損毀／半寫 | atomic write（temp + rename）+ corruption fallback 到 builtin |
| 多 profile 切換時舊 in-flight LLM call confusion | `LLMRefiner` `currentTask` cancellation 已有；profile 切換不影響進行中 call |
| builtin profile 被覆蓋 | `isBuiltin: true` 唯讀，UI Delete 按鈕 disable |
| Settings 整體 refresh 影響既有功能 | 各分頁拆獨立 NSViewController，`openSettings()` API 不變；保留舊 panes 的所有設定 key 與 read/write path 不動 |
| ClipboardHistoryWindow 改 NSCollectionView 引入 layout regression | 用 `flowLayout` 不用 custom；保留 NSPanel 入口；資料層 `ClipboardArchive` 完全不動 |
| 三組大改同 sprint 引發 conflict | Implementation Order 嚴格分 phase，phase 1 完成（純 logic）才開始 phase 3 UI；UI 共用元件先做（phase 2）讓 A/B/C 共享同一套 building blocks |
| `/no_think` directive 失效 | Profile 編輯時若首句不是 `/no_think` 顯示提示（可選 warning，不強制）|

## Acceptance Criteria

v1 完成判定：

**邏輯層**
- [ ] 8 個 builtin skill + 2 個 builtin profile 出廠存在
- [ ] Fresh install 啟動後 `prompts/` 自動 bootstrap
- [ ] 既有 UserDefaults 自訂 prompt 自動 import 為 profile
- [ ] `bench_refine_prompt_ab.py` 改用 PromptStore，6/6 case 仍命中（v1.1 baseline 不退步）

**Prompt 分頁（A）**
- [ ] Settings → Prompts 三欄佈局（sidebar / editor / test panel）渲染正常
- [ ] Profile 新增 / 編輯 / 複製 / 刪除（builtin 不可刪）
- [ ] Skills 拖拉排序、勾選啟用
- [ ] Skills Library 子分頁可新增 / 編輯 user skill
- [ ] Test panel 可貼文字、Run、顯示結果，**保留前 10 次 history**
- [ ] Import / Export single profile JSON round-trip
- [ ] Status menu 可切 active profile，切換立即生效（**不加全域熱鍵**）

**ClipboardHistory 升級（B）**
- [ ] 卡片列表渲染正確（kind badge + timestamp + preview）
- [ ] Sidebar filter（kind + 時間段）切換正常
- [ ] Toolbar SF Symbol 按鈕（refresh / reveal / clear）功能等同舊版
- [ ] 既有 NSPanel 入口 API（`openClipboardHistory()`）不變

**Settings refresh（C）**
- [ ] Sidebar 7 個分頁切換正常
- [ ] 舊 SettingsWindow 所有設定項在新 Panes 內均可存取（無功能退步）
- [ ] `openSettings()` API 不變，`⌘,` 仍可開啟

**Overlay**
- [ ] `.refining` 顯示「Refining (Default Refine) 1.2s」格式
- [ ] 「中文 LLM 修正」與「英文 Prompt」兩模式 label 隨 profile 變動

**品質 gate**
- [ ] `swift build` 0 warning
- [ ] `swift test` 全綠、覆蓋率 ≥ 80%
- [ ] Manual smoke：preview mode 開啟（`VOICE_INPUT_MIMO_PREVIEW=1`）下所有視窗無 layout 破圖

v1.5：slot 模板支援、UI slot editor、精確 tokenizer 估算、ModelMemoryWindow refresh
v2：per-app override、iCloud sync、skill marketplace（gist import）

## 預估規模（A + B + C）

- 新增 ~22 個檔案（5 prompts + 5 UI components + 8 settings panes + 4 tests）
- 修改 5 個檔案（LLMRefiner / SettingsWindow / ClipboardHistoryWindow / AppDelegate / OverlayPanel）
- 估 **3000–4000 行 Swift（含 UI）+ 1000–1200 行 test**
- 強烈建議 worktree（涉及 SettingsWindow / ClipboardHistoryWindow 兩個既有視窗大改）

### Implementation Order（v1）

**Phase 1：Logic foundation（無 UI、純 TDD）**
  1. Data model：`PromptProfile`、`PromptSkill`、`ActiveSelection`
  2. `PromptStore`（JSON CRUD + atomic write + fallback chain）
  3. `PromptComposer`（append 渲染）
  4. `BuiltinPromptCatalog`（8 skills + 2 profiles）
  5. `PromptMigration`（bootstrap + UserDefaults import）
  6. `LLMRefiner` 接管：refine() 走 PromptStore
  → 測試：所有 unit tests 綠 + bench harness 改寫後 6/6 不退步

**Phase 2：UI 共用元件**
  7. UI/ 五個共用 component（VibrantWindow / SectionHeading / RoundedCard / SidebarList / IconButton）
  → 為後續 Pane 提供 building blocks

**Phase 3：Settings refresh（C）**
  8. `SettingsRootController`（NSSplitViewController scaffold）
  9. 將舊 SettingsWindow 內容拆成 GeneralPane / ShortcutsPane / SpeechPane / ASRServerPane / AboutPane（5 個）
  → 此階段 Settings 視覺已對齊 Apple Music 風，但 Prompt 分頁尚是 placeholder

**Phase 4：Prompt 分頁（A）**
  10. `ProfileSidebar`（左欄）
  11. `ProfileEditor`（中欄）
  12. `PromptTestPanel`（右欄，含 history）
  13. `SkillsLibraryView`（Skills 管理頁）
  14. `PromptsPane` 組合三欄 + Skills Library tab
  15. Import / Export 本地檔
  → 此階段 v1 主要功能完備

**Phase 5：ClipboardHistory 升級（B）**
  16. `ClipboardHistoryView`（NSCollectionView card list + sidebar filter）
  17. `ClipboardHistoryWindow` 改用新 view（保留入口 API）
  18. `HistoryPane` embed 同一 view 進 Settings

**Phase 6：整合與收尾**
  19. AppDelegate status menu profile 切換（不加熱鍵）
  20. OverlayPanel `.refining(label:)` 帶 profile 名
  21. Acceptance backtest（6/6 不退步）
  22. swift build / swift test 全綠

## Resolved Questions

| # | 問題 | 決議 |
|---|---|---|
| 1 | Profile 切換熱鍵 | **不加全域熱鍵**，只走 status menu「輸出模式 ▸ Active Profile ▸」子選單 |
| 2 | Skills 來源 | **只能本地檔** import / export；不從 GitHub gist。但 Skills Library 需要**簡易互動管理頁**（list / 編輯 / 啟用切換 / 排序）|
| 3 | Overlay 顯示格式 | **加 profile 名**：`Refining (Formal Letter) 1.2s` / `Translating (Default ClaudeCode) 1.2s` — 比照 Apple Music 底部 player capsule 顯示歌名+藝人 subtitle 的資訊密度 |
| 4 | Test panel history | **保留 history**：前 5–10 次 input/output pair，可比較不同 profile 對同段文字的差異 |

## UI Design Direction（參考 Apple Music macOS）

整體風格對齊 Apple Music macOS 介面：translucent vibrancy + 圓角卡片 + 大留白 + 大字 section heading + sidebar 分區。

### Design Tokens

| Token | 值 | 用途 |
|---|---|---|
| Window background | `NSVisualEffectView` `.windowBackground` `.behindWindow` | 主視窗 |
| Side panel background | `.sidebar` material | sidebar / 右側 test panel |
| Card corner radius | 12 px（小卡）／ 16 px（hero）| Profile card / Skill card / Album-style |
| Section heading | `.systemFont(ofSize: 22, weight: .bold)` | 「Refine Profiles」「Skills Library」 |
| Subsection heading | `17pt semibold` + `>` chevron | 「為你精選」風 |
| Body text | 13pt regular | 一般 list cell 內文 |
| Helper text | 11pt regular `.secondaryLabelColor` | 描述、tooltip |
| Card spacing | 16 px gap、24 px padding | 卡片與卡片間／卡片內 |
| Sidebar row height | 32 px、icon 16 px + 12 px text | 與 macOS Sonoma sidebar 一致 |
| Active accent | `.controlAccentColor` | ★ active profile 標記、按鈕 |

### v1 範圍（A + B + C）

**A. 新 Settings 分頁「Prompt Profiles」**（必做，set 整體 design system 基調）

```
┌─────────────────────────────────────────────────────────────────┐
│ ◉ ◯ ◯  Settings — Prompt Profiles                               │
├──────────────┬──────────────────────────────────┬──────────────┤
│ Profiles     │ Default Refine        ★ Active   │  Test ▶      │
│ ─────────    │ ───────────────────              │  ──────────  │
│ Refine (3)   │ Refine mode                       │  Input:      │
│ ★ Default    │                                   │  ┌─────────┐ │
│   Formal     │ Base Prompt:                      │  │         │ │
│   Code       │ ┌──────────────────────────────┐ │  └─────────┘ │
│              │ │ /no_think You clean up...    │ │  [Run ▶]    │
│ ClaudeCode   │ └──────────────────────────────┘ │              │
│ ★ Default    │                                   │  History:    │
│   Slack      │ Skills (drag to reorder):         │  ┌─────────┐ │
│              │ ┌──────────────────────────────┐ │  │ Run #5   │ │
│              │ │ ⠿ ☑ Drop verbal fillers     │ │  │ Run #4   │ │
│              │ │ ⠿ ☑ Collapse stutter        │ │  │ Run #3   │ │
│              │ └──────────────────────────────┘ │  └─────────┘ │
│              │ [+ Add Skill]                     │              │
│              │                                   │              │
│              │ Suffix · Model · Temperature      │              │
│ [+ New]      │                                   │              │
│ [Import]     │ [Save]  [Discard]                 │              │
│ [Export]     │                                   │              │
└──────────────┴──────────────────────────────────┴──────────────┘
```

- 三欄：左 sidebar / 中編輯 / 右 test panel
- 左 sidebar 分區（refine / claudeCode），每段 count badge
- 中欄：profile name + mode badge + active ★、basePrompt 編輯器、Skills drag-drop list、suffix / model / temp
- 右 test panel：input textbox + Run + 結果 + **history 列表（保留前 10 次）**
- 底部 Skills Library tab、Import / Export 按鈕
- builtin profile 唯讀、可 Duplicate

**B. ClipboardHistoryWindow 升級**

```
┌─────────────────────────────────────────────────────────────────┐
│ ◉ ◯ ◯  Clipboard History                          🔄  📁  🗑    │
├──────────────┬──────────────────────────────────────────────────┤
│ All           │ Voice Sessions & Clipboard Snapshots            │
│ Voice (12)    │                                                  │
│ Clipboard (8) │ ┌──────────────────────────────────────────────┐│
│               │ │ Voice Session  ·  2026-05-10 04:48          ││
│ ──────────    │ │ Chinese (ASR): 然後同時幫我確認...           ││
│ Today         │ │ English / Output: Now, help me confirm...    ││
│ Yesterday     │ └──────────────────────────────────────────────┘│
│ Older         │                                                  │
│               │ ┌──────────────────────────────────────────────┐│
│               │ │ Clipboard  ·  2026-05-10 04:48              ││
│               │ │ a ha moment                                   ││
│               │ └──────────────────────────────────────────────┘│
│               │                                                  │
│               │ [Card 詳情可右側展開或就地展開]                  │
└──────────────┴──────────────────────────────────────────────────┘
```

- 左 sidebar：分區（kind filter + 時間段過濾）
- 中欄：圓角卡片列表取代 NSTableView，每張卡片顯示 kind badge + timestamp + preview
- Toolbar：SF Symbol-only 按鈕：`arrow.clockwise` / `folder` / `trash`
- Card 點選 → 右側 detail panel 展開 full content（保留現有 NSTextView）
- 標題列 22pt bold「Clipboard History」+ subtitle

實作策略：
- 卡片列表用 `NSCollectionView` + flow layout（取代 NSTableView，但保留資料來源 protocol 相容）
- `ClipboardArchive` data layer 不動（只動 view）

**C. SettingsWindow 整體 refresh**

```
┌─────────────────────────────────────────────────────────────────┐
│ ◉ ◯ ◯  Preferences                                              │
├──────────────┬──────────────────────────────────────────────────┤
│ ⚙ General    │ Prompt Profiles                                 │
│ ⌘ Shortcuts  │                                                  │
│ 🎤 Speech     │ [profile 編輯三欄區，見 A]                       │
│ 🖥 ASR Server │                                                  │
│ ✨ Prompts ★  │                                                  │
│ 📋 History    │                                                  │
│ ℹ︎ About      │                                                  │
└──────────────┴──────────────────────────────────────────────────┘
```

- 從現有「平鋪 form 區段」改為「左 sidebar + 右內容」分頁式
- 7 個分頁：General / Shortcuts / Speech / ASR Server / **Prompts**（A 那塊）/ History（取代 ClipboardHistoryWindow 入口）/ About
- 每個分頁用 22pt bold 大標題 + 內容區
- 沿用 macOS Sonoma `NSSplitViewController` 風格

實作策略：
- 改用 `NSSplitViewController` 取代現有 `NSTabView`-style layout
- 各分頁拆成獨立 `NSViewController` 子類（Single Responsibility，便於 v1.5 單獨改）
- 「History」分頁直接 embed ClipboardHistoryWindow 內容，原獨立 window 仍保留入口（status menu ⌘⌥H）

### v1.5 / v2 範圍

| 項目 | 階段 |
|---|---|
| Slot 模板支援（資料模型 + UI editor）| v1.5 |
| ModelMemoryWindow refresh | v1.5 |
| 精確 tokenizer 估算 | v1.5 |
| Per-app override（VS Code 用 A、Slack 用 B）| v2 |
| iCloud sync | v2 |
| Skill marketplace（公開包 / gist import）| v2 |

OverlayPanel 顯示 profile 名屬於 v1 小改、已並入 acceptance criteria。

### 新元件抽象（共用 design system）

| 元件 | 檔案 | 用途 |
|---|---|---|
| `VibrantWindow` | `Sources/VoiceInputMimo/UI/VibrantWindow.swift` | 統一 NSVisualEffectView 設定 |
| `SectionHeading` | `Sources/VoiceInputMimo/UI/SectionHeading.swift` | 22pt bold 區段標題 |
| `RoundedCard` | `Sources/VoiceInputMimo/UI/RoundedCard.swift` | 12/16 px 圓角 + padding 容器 |
| `SidebarList` | `Sources/VoiceInputMimo/UI/SidebarList.swift` | macOS sidebar 風 NSOutlineView wrapper |
| `IconButton` | `Sources/VoiceInputMimo/UI/IconButton.swift` | SF Symbol toolbar 按鈕 |

→ Profile 分頁 + ClipboardHistoryWindow toolbar 都用同一套 components。SettingsWindow 整體 refresh 留 v1.5 時也共用。

## Open Questions（後續細節，不阻塞 v1 開工）

- [ ] Profile JSON schema 版本欄位 `schemaVersion` 起始值（建議 1）
- [ ] Test panel Run 是否要顯示 token usage（從 LLM response 抽 `usage` 欄位）
- [ ] Skills Library 是否要 category filter（v1 簡易版可省）
