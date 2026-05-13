---
title: Prompt Profile + Skill 客製化系統 — Implementation Plan
slug: prompt-profile-skill-system
status: ✅ SHIPPED (verified 2026-05-14 — entire Prompts/ directory exists with 9 source files + 8 test files in main; no retro KB report written)
created: 2026-05-10
revised: 2026-05-14
worktree: completed (already merged to main; worktree cleaned)
branch: feat/prompt-profile-skill-system (merged)
parent_repo: ~/Documents/voice-input-mimo
shipped_files:
  - Sources/VoiceInputMimo/Prompts/PromptProfile.swift
  - Sources/VoiceInputMimo/Prompts/PromptStore.swift
  - Sources/VoiceInputMimo/Prompts/PromptStoreProviding.swift
  - Sources/VoiceInputMimo/Prompts/PromptStoreViewModel.swift
  - Sources/VoiceInputMimo/Prompts/PromptComposer.swift
  - Sources/VoiceInputMimo/Prompts/PromptIO.swift
  - Sources/VoiceInputMimo/Prompts/PromptMigration.swift
  - Sources/VoiceInputMimo/Prompts/BuiltinPromptCatalog.swift
  - Sources/VoiceInputMimo/Prompts/StructureRouter.swift
  - Sources/VoiceInputMimo/Settings/Prompts/ProfileSidebar.swift
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
| `Sources/VoiceInputMimo/Prompts/PromptStoreProviding.swift` | Phase 2 — protocol + `PromptStore: PromptStoreProviding` extension（DI 注入用）|
| `Sources/VoiceInputMimo/Refining.swift` | Phase 2 — `Refining` protocol + `LLMRefiner: Refining` extension |
| `Sources/VoiceInputMimo/Prompts/PromptStoreViewModel.swift` | Phase 2 — `@MainActor @Observable` adapter，包 store 給 SwiftUI |

**UI 共用元件**（SwiftUI；殼仍 AppKit）

| 檔案 | 類型 | 內容 |
|---|---|---|
| `Sources/VoiceInputMimo/UI/HostingWindow.swift` | `NSWindow` 子類 | 通用 hosting 殼：NSVisualEffectView 背景 + `NSHostingController` root + size restoration |
| `Sources/VoiceInputMimo/UI/SectionHeading.swift` | `View` | `Text("...").font(.system(size: 22, weight: .bold))` 加 padding |
| `Sources/VoiceInputMimo/UI/CardModifier.swift` | `ViewModifier` + `extension View { func cardStyle() -> some View }` | 12/16 px 圓角 + `.regularMaterial` 背景 + padding |
| `Sources/VoiceInputMimo/UI/SidebarSection.swift` | `View` | `List` + `.listStyle(.sidebar)` wrapper，分區 header 統一 |
| `Sources/VoiceInputMimo/UI/IconButton.swift` | `View` | `Button { } label: { Image(systemName:) }` + 統一 hover style |

**Settings 分頁與面板**（SwiftUI `NavigationSplitView` + `NSHostingController` bridge）

| 檔案 | 類型 | 內容 |
|---|---|---|
| `Sources/VoiceInputMimo/Settings/SettingsRootView.swift` | `View` | `NavigationSplitView` sidebar + detail；7 個 pane 切換 |
| `Sources/VoiceInputMimo/Settings/SettingsViewModel.swift` | `@MainActor @Observable` | 保存 selected pane、注入子 view |
| `Sources/VoiceInputMimo/Settings/Panes/GeneralPane.swift` | `View` | General 分頁 |
| `Sources/VoiceInputMimo/Settings/Panes/ShortcutsPane.swift` | `View` | 從舊 SettingsWindow 抽出 form |
| `Sources/VoiceInputMimo/Settings/Panes/SpeechPane.swift` | `View` | 從舊 SettingsWindow 抽出 form |
| `Sources/VoiceInputMimo/Settings/Panes/ASRServerPane.swift` | `View` | 從舊 SettingsWindow 抽出 form |
| `Sources/VoiceInputMimo/Settings/Panes/PromptsPane.swift` | `View` | A 區：`NavigationSplitView` 三欄 + Skills Library tab |
| `Sources/VoiceInputMimo/Settings/Panes/HistoryPane.swift` | `View` | B 區內嵌 `ClipboardHistoryView` |
| `Sources/VoiceInputMimo/Settings/Panes/AboutPane.swift` | `View` | About / 版本資訊 |
| `Sources/VoiceInputMimo/Settings/Components/ProfileSidebar.swift` | `View` | A 區左欄 — `List` + Active 指示 |
| `Sources/VoiceInputMimo/Settings/Components/ProfileEditor.swift` | `View` | A 區中欄 — `Form` + skill drag-reorder |
| `Sources/VoiceInputMimo/Settings/Components/PromptTestPanel.swift` | `View` | A 區右欄 — input + Run（`.task`）+ history scroll |
| `Sources/VoiceInputMimo/Settings/Components/SkillsLibraryView.swift` | `View` | Skills Library 子分頁 — `List` + edit form |
| `Sources/VoiceInputMimo/Settings/Components/ClipboardHistoryView.swift` | `View` | B 區共用 — `LazyVGrid` cards + sidebar filter |

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
| `Sources/VoiceInputMimo/SettingsWindow.swift` | **整個重寫**為 thin `NSWindow` 殼 + `NSHostingController(rootView: SettingsRootView().environment(...))`；保留入口 API（`openSettings()`）；form 全拆到 SwiftUI Panes |
| `Sources/VoiceInputMimo/ClipboardHistoryWindow.swift` | thin `NSWindow` 殼 + `NSHostingController(rootView: ClipboardHistoryView())`，保留入口 API（`openClipboardHistory()`）；list 從 NSCollectionView 改 SwiftUI `LazyVGrid` |
| `Sources/VoiceInputMimo/AppDelegate.swift` | 「輸出模式」子選單加 profile 切換；Overlay phase 用 profile.displayLabel + name |
| `Sources/VoiceInputMimo/OverlayPanel.swift` | `.refining(translating:)` → `.refining(label: String)`（含 profile 名）|

## Concurrency / DI / MainActor 規約（Phase 2+）

來源：ECC `swift-concurrency-6-2` / `swift-protocol-di-testing` / `swift-actor-persistence` skills 對齊。

### Sendable conformance（Phase 2 起補；不破壞 Phase 1）

`PromptProfile` / `PromptSkill` / `SkillCategory` / `ActiveSelection` 須 conform `Sendable`：

```swift
struct PromptProfile: Codable, Identifiable, Equatable, Sendable { ... }
struct PromptSkill:   Codable, Identifiable, Equatable, Sendable { ... }
enum   SkillCategory: String, Codable, CaseIterable, Sendable { ... }
struct ActiveSelection: Codable, Equatable, Sendable { ... }
```

目前皆 value type（`String` / `Date` / `Bool` / `Double?` / 純 enum / `[String]`）—— 補 `Sendable` 不破壞 ABI、不影響 Phase 1 行為。Phase 2 開工首個 commit 加。

### @Observable adapter（連接 actor store 與 SwiftUI views，Phase 2 起建）

Hybrid 架構需要一個 ViewModel 把 `PromptStoreProviding` 包成 SwiftUI `@Observable` 形態 — view 不直接吃 protocol、吃 ViewModel：

```swift
import Observation

@MainActor
@Observable
final class PromptStoreViewModel {
    static let shared = PromptStoreViewModel()

    private(set) var profilesByMode: [RefineMode: [PromptProfile]] = [:]
    private(set) var skills: [PromptSkill] = []
    private(set) var activeSelection: ActiveSelection?
    private(set) var isLoading = false
    private(set) var lastError: Error?

    private let store: any PromptStoreProviding
    private let migration: PromptMigration?

    init(store: any PromptStoreProviding = PromptStore.shared) {
        self.store = store
        self.migration = nil
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            profilesByMode[.refine] = try store.listProfiles(for: .refine)
            profilesByMode[.claudeCode] = try store.listProfiles(for: .claudeCode)
            skills = try store.listSkills()
            activeSelection = try store.loadActiveSelection()
        } catch {
            lastError = error
        }
    }

    func setActiveProfile(_ profileID: String, for mode: RefineMode) async {
        // 改 active.json 後 reload；profile 切換不影響進行中 LLM call
    }
}
```

### MainActor isolation 規則（SwiftUI views 預設）

- Swift 6.2 SwiftUI `View.body` 預設 `@MainActor`，不需要手動標
- `@Observable` ViewModel 加 `@MainActor` 確保 mutation 安全
- 跨 store 呼叫一律 `.task { await viewModel.reload() }`，**禁** body / init 起 Task 或做 I/O
- 走出 MainActor（call PromptStore actor v1.5）後回 await 點自動回 MainActor

### Protocol-based DI（Phase 2 起，Phase 4 強制）

ViewModel 吃 protocol、view 吃 ViewModel；測試替換 ViewModel 的 store：

```swift
protocol PromptStoreProviding: Sendable {
    func loadActiveSelection() throws -> ActiveSelection?
    func listProfiles(for mode: RefineMode) throws -> [PromptProfile]
    func activeProfile(for mode: RefineMode) throws -> PromptProfile?
    func saveProfile(_ profile: PromptProfile) throws
    func deleteProfile(id: String, mode: RefineMode) throws
    func saveSkill(_ skill: PromptSkill) throws
    func deleteSkill(id: String) throws
    func listSkills() throws -> [PromptSkill]
    func saveActiveSelection(_ selection: ActiveSelection) throws
}

protocol Refining: Sendable {
    func refine(_ text: String, mode: RefineMode) async throws -> String
}

// 既有 LLMRefiner.shared 加 Refining conformance；既有 PromptStore.shared 加 PromptStoreProviding conformance
```

SwiftUI view 透過 `.environment(viewModel)` 取得 store-backed ViewModel，**禁** view 內 `PromptStore.shared` 直抓：

```swift
struct PromptsRootView: View {
    @Environment(PromptStoreViewModel.self) private var store

    var body: some View {
        NavigationSplitView {
            ProfileSidebar()
        } content: {
            ProfileEditor()
        } detail: {
            PromptTestPanel()
        }
        .task { await store.reload() }
    }
}
```

### 新增檔案

- `Sources/VoiceInputMimo/Prompts/PromptStoreProviding.swift`（protocol + `PromptStore: PromptStoreProviding` extension）
- `Sources/VoiceInputMimo/Refining.swift`（`Refining` protocol + `LLMRefiner: Refining` extension）
- `Sources/VoiceInputMimo/Prompts/PromptStoreViewModel.swift`（`@Observable` adapter）
- `Tests/VoiceInputMimoTests/Mocks/{MockPromptStore,MockRefiner}.swift`

### v1.5 升級目標（不在當前 PR、留 ticket）

- `PromptStore` 從 `final class + DispatchQueue` 升級到 `actor`，public method 全 async；可移除手動 lock
- `PromptMigration.bootstrapIfNeeded()` 標 `nonisolated`，AppDelegate 啟動可在任一 thread 呼叫
- 升級需配合所有 caller 改 await，影響面大、留 UI 收尾後另開 PR

## Test 策略（TDD）

依 user CLAUDE.md「寫測試先於實作；80% 最低覆蓋率」：

1. **PromptStore**：write/read round-trip、不存在的 ID、corrupted JSON 還原、concurrent write atomic 性
2. **PromptComposer**：空 skills、單 skill、多 skill 順序、slot 不存在、slot 重複、basePrompt 含 examples 段
3. **PromptMigration**：fresh install、有 UserDefaults override、prompts/ 部分存在、prompts/ 損毀
4. **整合**：LLMRefiner.refine() with 自訂 profile vs builtin → 對既有 6-case backtest 結果不退步
5. **`PromptStoreViewModel`**：`reload()` 後 `profilesByMode` / `skills` / `activeSelection` 反映 mock store 狀態；`setActiveProfile` 寫入後 reload 一致；異常時 `lastError` 設置
6. **UI smoke**：Settings 開／關／新增 profile／切換 active／export / import round-trip — 走 `make e2e-phase{3,4,5}` osascript 驅動

### SwiftUI 測試手段

- **#Preview macro**：每個共用元件 + 主要 pane 配 `#Preview` block 帶 mock ViewModel；preview 是開發迭代主力，不是測試
- **ViewModel unit test**：把所有 view-side state mutation 邏輯放在 `@Observable` ViewModel，用 mock `PromptStoreProviding` 直接測 — view body 不寫邏輯所以不必測
- **不引入 ViewInspector / 第三方 SwiftUI testing lib**：v1 範圍內保持 zero external test dep；UI 行為走 e2e osascript
- **快照（snapshot）測試延後**：vibrancy / 動畫 false-positive 多，v1.5 再考慮

延伸 backtest harness：`scripts/bench_refine_prompt_ab.py` 改成讀 PromptStore 兩個 profile 比較，而非 hardcoded 兩段 prompt。

## E2E Gate per Phase

**規則：每個 phase 收尾必須跑對應 `make e2e-phaseN` 通過、才能進下一個 phase。**

E2E 不是替代 unit test，是補在 unit 之上的「整合 + 真環境 + 真 side effect」驗證。SwiftPM menubar app 沒有 Xcode 專案，採 **C+A 混合**（pure SPM 不加 Xcode shim）：

- **C — side-effect 驗證**：launch `swift run` 或 `make build` 產出的 `.app`，腳本讀 `~/Library/Application Support/VoiceInputMimo/`、clipboard、log、stdout，驗 wire-up 正確。
- **A — osascript driver**：Phase 4 開始用 `osascript` + System Events 點 status menu / window，驗 UI 互動產生預期 side effect。
- **D — 截圖 diff**：Phase 6 整合時加 hero flow 的截圖 baseline（`screencapture` + hash）。

每個 phase gate 內容：

| Phase | Gate scope | 驗證方式 |
|---|---|---|
| 1（資料層）| `swift test` 全綠 + bench 3-way 通過 v1-store ≥ v1 | `scripts/e2e/phase1_gate.sh`（已建）|
| 2（UI 共用元件）| `swift build` warning-free + Sendable conformance + `@Observable` ViewModel 單測 + `#Preview` 各元件可渲染 | `phase2_gate.sh` — build + unit + Preview render-not-crash 檢查 |
| 3（SettingsWindow refresh）| App launch、開 Settings、7 個分頁逐一切換無 crash、舊 setting 讀寫不變 | `phase3_gate.sh` — osascript 點分頁 + 讀 UserDefaults |
| 4（Prompts pane）| 新增 / 編輯 / 切換 active profile → `active.json` 反映；Test panel 真 call Rapid-MLX | `phase4_gate.sh` — osascript 操作 + 讀 prompts/ + bench-style 驗 |
| 5（ClipboardHistory cards）| 卡片渲染、kind / 時段 filter 正確、舊 archive 資料完整 | `phase5_gate.sh` — osascript + 讀 `clipboard-archive.txt` |
| 6（整合）| AppDelegate 啟動跑 `PromptMigration.bootstrapIfNeeded()`；status menu Profile 切換生效；overlay 顯示 profile 名 | `phase6_gate.sh` — clean App Support → launch → 全量驗收（C+A+D）|

E2E 跑哪台：**本機 macOS**。CI 暫不接（accessibility 權限 + ARM runner 成本另議）。

E2E infra layout：
```
scripts/e2e/
  common.sh          # 共用：c_red/c_green、ensure_rapid_mlx_up、run_swift_tests
  phase1_gate.sh     # ✅ 已建
  phase2_gate.sh     # 待 phase 2 收尾
  ...
```

## Risks

| Risk | 緩解 |
|---|---|
| 使用者堆太多 skill → 爆 token / 變慢 | Preview 顯示 token 估算 + warning > 1000 tokens |
| JSON 檔損毀／半寫 | atomic write（temp + rename）+ corruption fallback 到 builtin |
| 多 profile 切換時舊 in-flight LLM call confusion | `LLMRefiner` `currentTask` cancellation 已有；profile 切換不影響進行中 call |
| builtin profile 被覆蓋 | `isBuiltin: true` 唯讀，UI Delete 按鈕 disable |
| Settings 整體 refresh 影響既有功能 | 各分頁拆獨立 SwiftUI View，`openSettings()` API 不變；保留舊 panes 的所有設定 key 與 read/write path 不動；form binding 經 `@Observable SettingsViewModel` 寫回 UserDefaults |
| ClipboardHistoryWindow 改 SwiftUI LazyVGrid 引入 layout regression | 先做 `#Preview` 比對排版、再 osascript e2e 跑既有 `openClipboardHistory()` 入口；資料層 `ClipboardArchive` 完全不動 |
| 三組大改同 sprint 引發 conflict | Implementation Order 嚴格分 phase，phase 1 完成（純 logic）才開始 phase 3 UI；UI 共用元件先做（phase 2）讓 A/B/C 共享同一套 building blocks |
| `/no_think` directive 失效 | Profile 編輯時若首句不是 `/no_think` 顯示提示（可選 warning，不強制）|
| Sendable 漏標（Phase 2+ 跨 actor 傳 Profile / Skill 失敗）| 全部 data model（PromptProfile / PromptSkill / SkillCategory / ActiveSelection）conform Sendable；Phase 2 開工首 commit 加，無 ABI 破壞 |
| MainActor 邊界違反（Swift 6.2 compile error）| SwiftUI `View.body` / `@Observable` ViewModel 預設 `@MainActor`；跨 actor 呼叫一律 `.task { await ... }`，不能靠 `DispatchQueue.main.async` 補救 |
| 直接綁 `.shared` 單例導致 UI 無法測試 | View 吃 `@Environment(PromptStoreViewModel.self)`，ViewModel 吃 `PromptStoreProviding` / `Refining` protocol，預設 init 帶 singleton、測試注 mock |
| SwiftUI / AppKit 邊界混亂（pane 內混兩套狀態管理）| 邊界鎖在「window 殼」層級：`NSWindow` 殼 + `NSHostingController` 是唯一橋；橋之內全 SwiftUI、之外（status menu / OverlayPanel）全 AppKit。**禁** SwiftUI view 內塞 `NSViewRepresentable` 包 NSView，除非有非常具體的理由（例：`NSTextView` 多行編輯器需要 ranged formatting）|
| `NSHostingController` retain ViewModel 過久導致記憶體洩漏 | `Settings` / `ClipboardHistory` window close 時 `windowWillClose` 釋放 hosting controller；`PromptStoreViewModel` 是 singleton，跨 window 共享，不重建 |
| SwiftUI list 大量資料卡頓 | 用 `LazyVStack` / `LazyVGrid`；`ForEach` id 用 stable identifier（`profile.id`、`skill.id`、`session.timestamp`），不用 array index；history > 10 條時加 `ScrollView` + lazy |
| 用了 deprecated `NavigationView` / `ObservableObject` | review 必查；用 `NavigationSplitView` + `NavigationStack` + `@Observable`，違反不過 review |

## Acceptance Criteria

v1 完成判定：

**邏輯層**
- [ ] 8 個 builtin skill + 2 個 builtin profile 出廠存在
- [ ] Fresh install 啟動後 `prompts/` 自動 bootstrap
- [x] 既有 UserDefaults 自訂 prompt 自動 import 為 profile（PromptMigration.bootstrapIfNeeded）
- [x] `bench_refine_prompt_ab.py` 改用 PromptStore，6/6 case 仍命中（v1.1 baseline 不退步）— v1-store 5/6 = v1 5/6，latency 1652ms < v1 1674ms（`harness/refine-prompt-store-acceptance-revalidate-*.md`）

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

v1.5：slot 模板支援、UI slot editor、精確 tokenizer 估算、ModelMemoryWindow refresh、PromptStore final class → actor 升級
v2：per-app override、iCloud sync、skill marketplace（gist import）、`@main App` + `MenuBarExtra` 全 SwiftUI 重構（需先驗證 menubar 動態子選單可行）、OverlayPanel 改 SwiftUI Window

## 預估規模（A + B + C）

- 新增 ~25 個檔案（5 prompts + 3 protocol/adapter + 5 SwiftUI 共用元件 + 9 SwiftUI panes/components + 5 settings forms 改 SwiftUI Pane + 4-6 tests）
- 修改 5 個檔案（LLMRefiner / SettingsWindow / ClipboardHistoryWindow / AppDelegate / OverlayPanel）— SettingsWindow / ClipboardHistoryWindow 縮成 thin shell（行數大降）
- 估 **2500–3500 行 Swift（SwiftUI 比 NSViewController 緊湊）+ 800–1000 行 test**（view 邏輯內聚 ViewModel，view 本體無邏輯故不測）
- 強烈建議 worktree（已建：`~/Documents/voice-input-mimo-prompts/`，branch `feat/prompt-profile-skill-system`）

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

> **Phase 2 開工前必做**（SwiftUI Hybrid scope）：plan「## UI Stack Decision」與「## Concurrency / DI / MainActor 規約」兩段已把 4 個 ECC Swift skill（`swiftui-patterns` / `swift-concurrency-6-2` / `swift-protocol-di-testing` / `swift-actor-persistence`）內容對齊。Phase 2 開工流程：
> 1. **首 commit 補 Sendable**：4 個 data model（PromptProfile / PromptSkill / SkillCategory / ActiveSelection）加 `Sendable` conformance，`swift test` 不破壞
> 2. **次 commit 建 protocol + adapter**：`PromptStoreProviding` / `Refining` / `PromptStoreViewModel`（`@MainActor @Observable`）
> 3. 寫 SwiftUI View / `@Observable` ViewModel 前 `ToolSearch query="swiftui patterns"` 拉 deferred skill 驗細節
> 4. Code review 走 generic `code-reviewer` agent，但 prompt 須點名 SwiftUI idioms 檢查項：禁 `ObservableObject` / `@StateObject` / `AnyView`、view body 不得做 I/O、list 必須有 stable id、用 `.task {}` 而非 init 起 Task
> 5. ECC 沒有 `swift-build-resolver` agent — `swift build` 失敗時人工讀 stderr，不要套 generic build-error-resolver（取向 npm/TS）

  7. UI/ 五個共用元件 — **SwiftUI View / ViewModifier**：`HostingWindow`（NSWindow 殼）/ `SectionHeading` / `CardModifier` / `SidebarSection` / `IconButton`，每個附 `#Preview`
  → 為後續 SwiftUI pane 提供 building blocks

**Phase 3：Settings refresh（C）— SwiftUI 殼 + AppKit window 入口**
  8. `SettingsViewModel`（`@MainActor @Observable`，保 selected pane）
  9. `SettingsRootView`（`NavigationSplitView` sidebar + detail）
  10. 將舊 `SettingsWindow` 內 form 拆成 SwiftUI Panes：`GeneralPane` / `ShortcutsPane` / `SpeechPane` / `ASRServerPane` / `AboutPane`（5 個）
  11. `SettingsWindow.swift` 重寫為 thin `NSWindow` 殼 + `NSHostingController(rootView: SettingsRootView().environment(viewModel))`
  → Prompts / History pane 此階段為 placeholder；Settings 視覺已對齊 Apple Music 風

**Phase 4：Prompt 分頁（A）— 全 SwiftUI**
  12. `ProfileSidebar`（左欄 `List`）
  13. `ProfileEditor`（中欄 `Form` + skill drag-reorder）
  14. `PromptTestPanel`（右欄 input + Run（`.task`）+ history scroll）
  15. `SkillsLibraryView`（Skills 管理頁）
  16. `PromptsPane` 組合三欄 `NavigationSplitView` + Skills Library tab
  17. Import / Export 本地檔（NSOpenPanel / NSSavePanel 透過 `@MainActor` adapter）
  → 此階段 v1 主要功能完備

**Phase 5：ClipboardHistory 升級（B）— SwiftUI cards**
  18. `ClipboardHistoryView`（`LazyVGrid` cards + `List` sidebar filter，kind / 時間段）
  19. `ClipboardHistoryWindow.swift` 重寫為 thin `NSWindow` 殼 + `NSHostingController(rootView: ClipboardHistoryView())`（保留入口 API）
  20. `HistoryPane` 直接 embed `ClipboardHistoryView` 進 Settings（同一 SwiftUI view，免複製）

**Phase 6：整合與收尾**
  21. `AppDelegate` 啟動跑 `PromptMigration.bootstrapIfNeeded()` 並 init `PromptStoreViewModel.shared.reload()`
  22. status menu profile 切換（不加熱鍵）— 透過 `PromptStoreViewModel.setActiveProfile(...)` 寫 `active.json`
  23. `OverlayPanel.transition(to: .refining(label:))` 帶 profile 名
  24. Acceptance backtest（v1-store ≥ v1 baseline）
  25. swift build / swift test 全綠 + `make e2e-phase{2..6}` 全 pass

## Resolved Questions

| # | 問題 | 決議 |
|---|---|---|
| 1 | Profile 切換熱鍵 | **不加全域熱鍵**，只走 status menu「輸出模式 ▸ Active Profile ▸」子選單 |
| 2 | Skills 來源 | **只能本地檔** import / export；不從 GitHub gist。但 Skills Library 需要**簡易互動管理頁**（list / 編輯 / 啟用切換 / 排序）|
| 3 | Overlay 顯示格式 | **加 profile 名**：`Refining (Formal Letter) 1.2s` / `Translating (Default ClaudeCode) 1.2s` — 比照 Apple Music 底部 player capsule 顯示歌名+藝人 subtitle 的資訊密度 |
| 4 | Test panel history | **保留 history**：前 5–10 次 input/output pair，可比較不同 profile 對同段文字的差異 |

## UI Stack Decision（v1：Hybrid — AppKit shell + SwiftUI inside）

來源：ECC `swiftui-patterns` / `swift-concurrency-6-2` skills 對齊；macOS 14+ 已 pin（Package.swift），`@Observable` / `NavigationSplitView` / `MenuBarExtra` 全可用。

### 分層

| 層 | 採用 | 為何 |
|---|---|---|
| App entry / lifecycle | **AppKit**：保留 `AppDelegate` + `@main NSApplicationMain` | 既有 LSUIElement / accessibility / `CGEventTap` 行為相依 AppDelegate |
| 狀態列 / status menu | **AppKit**：保留 `NSStatusItem` + `NSMenu` | 7+ menu item 含三段輸出模式 + Recent History 動態子選單；用 SwiftUI `MenuBarExtra` 重寫成本高且失去動態建構彈性 |
| Overlay capsule | **AppKit**：保留 `OverlayPanel: NSPanel` | 非激活 NSPanel + 手動 `transition(to:)` state machine 行為 SwiftUI Window 模擬不出來 |
| Window 殼（Settings / ClipboardHistory / ModelMemory） | **AppKit**：`NSWindow` + `NSHostingController(rootView:)` 包 SwiftUI root | 保留既有 `openSettings()` / `openClipboardHistory()` 入口 API、size restoration、window delegate 行為 |
| Window 內容（pane / cards / forms） | **SwiftUI**：`View` + `@Observable` ViewModel + `.environment(...)` 注入 | Phase 2 五個共用元件、Phase 3-5 全部 pane 都是 SwiftUI |

### Hosting bridge

```swift
// SettingsWindow.swift（Phase 3 改造）
final class SettingsWindow: NSWindow {
    init(viewModel: SettingsViewModel) {
        let root = SettingsRootView()
            .environment(viewModel)
            .environment(PromptStoreViewModel.shared)
        let host = NSHostingController(rootView: root)
        super.init(
            contentRect: .init(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        self.contentViewController = host
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        // NSVisualEffectView via background view
    }
}
```

### SwiftUI 紀律（必須守，違反走不過 review）

- **state**：用 `@Observable`（macOS 14+），**禁** `ObservableObject` / `@StateObject` / `@EnvironmentObject` / `@Published`
- **DI**：`@Environment(PromptStoreViewModel.self) private var store`，view init 走 `.environment(store)` modifier；**禁** view 內抓 `.shared` singleton
- **async**：`.task { ... }` modifier，**禁** 在 `body` / `init` 起 Task 或做 I/O
- **list**：`List(items)` + `Identifiable`；長 list 改 `LazyVStack` / `LazyVGrid`；**禁** array index 當 id
- **type erasure**：用 `@ViewBuilder` / `Group`，**禁** `AnyView`
- **navigation**：3 欄走 `NavigationSplitView`、stack 走 `NavigationStack` + `NavigationPath`，禁直接 `NavigationView` (deprecated)
- **preview**：每個共用 component + 主要 pane 配 `#Preview` macro + mock store

### 不在 v1 範圍

- `@main App` + `MenuBarExtra` + `Settings` scene + `WindowGroup` 全 SwiftUI 重構（v1.5+，需先驗證 menubar 動態子選單在 MenuBarExtra 行得通）
- OverlayPanel 改 SwiftUI Window（v2，需先解非激活 window 不奪 focus 的問題）

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
- 卡片列表用 SwiftUI `LazyVGrid`（取代 NSTableView / NSCollectionView），透過 `NSHostingController` 嵌進既有 `ClipboardHistoryWindow` 殼
- `ClipboardArchive` data layer 不動，加 `@Observable ClipboardArchiveViewModel` adapter

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
- SwiftUI `NavigationSplitView`（macOS 14+），sidebar style 對齊 macOS Sonoma

實作策略：
- SwiftUI `NavigationSplitView` 取代既有 NSTabView 平鋪 form
- 各分頁拆成獨立 `View` struct（Single Responsibility，便於 v1.5 單獨改）
- `SettingsWindow` 縮成 thin `NSWindow` 殼 + `NSHostingController(rootView: SettingsRootView())`
- 「History」分頁直接 embed `ClipboardHistoryView`（同一 SwiftUI view），原獨立 window 仍保留入口（status menu ⌘⌥H）

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
