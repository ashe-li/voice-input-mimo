# Plan: Structure Mode (複合情境) with Template Router

**Status:** ✅ SHIPPED (verified 2026-05-14 — `RefineMode.structure` case + `Prompts/StructureRouter.swift` + 5 templates in `BuiltinPromptCatalog` + `StructureRouterTests.swift` all in main; no retro KB report written)
**Created:** 2026-05-11
**Revised:** 2026-05-14 (reality-check found plan was stale after Sprint 1.1 shipped out-of-order)
**Owner:** ashe-li

## Goal

Add a third output mode `.structure` alongside the existing `.refine` (ZH cleanup) and `.claudeCode` (ZH→EN). The new mode classifies the speaker's content via a Swift-side keyword router, then routes to one of 5 template-based profiles to produce structured output (meeting notes, task list, requirement draft, letter, article).

## Non-goals

- Do **not** modify the behavior of `.refine` or `.claudeCode` profiles, prompts, or skills.
- Do **not** change existing fn-hold recording hotkey or push-to-talk UX.
- Do **not** introduce LLM-based routing in v1 (deferred — keyword router only).
- Do **not** build configurable user-editable keyword tables in v1 (hardcoded; later phase).

## Three modes — final shape

| # | Mode | Role | RefineMode case | Status |
|---|---|---|---|---|
| 1 | ZH→EN | for Prompts/Claude Code | `.claudeCode` (existing) | unchanged |
| 2 | ZH 微調 | filler removal, faithful to original | `.refine` (existing) | unchanged |
| 3 | ZH 複合情境 | auto-classify → template | `.structure` (NEW) | to build |

## Architecture overview

```
ASR ZH text
    │
    ▼
┌───────────────┐
│ active mode?  │
└───────┬───────┘
        │
   ┌────┼────┬────────────┐
   ▼    ▼    ▼            ▼
.refine .claudeCode    .structure
   │    │                  │
   ▼    ▼                  ▼
[unchanged]     ┌──────────────────────┐
                │ StructureRouter      │
                │ (Swift, keyword tbl) │
                └──────────┬───────────┘
                           ▼
                ┌──────────────────────┐
                │ pick template profile│
                ├──────────────────────┤
                │ meeting / task /     │
                │ requirement / letter │
                │ / article / fallback │
                └──────────┬───────────┘
                           ▼
                  LLM call (1 round)
                           ▼
                    structured output
```

Key principle: `.structure` mode adds **one Swift-side classifier** + **N independent profiles**. Each profile is composed via existing `PromptComposer.render(profile, skills)`. No second LLM call.

## File-level changes

### New types

**`Sources/VoiceInputMimo/Prompts/PromptProfile.swift`**

- Add `.structure` to `RefineMode`:
  ```swift
  enum RefineMode: String, Codable, Sendable {
      case refine, claudeCode, structure
  }
  ```
- Extend `ActiveSelection` with `structureProfileID`. Default to `"builtin-structure-fallback"`. Codable migration: missing field → default.
- Add `SkillCategory.planning` (used by structure-mode skills, kept separate from existing categories so UI can group them).

**`Sources/VoiceInputMimo/Prompts/StructureRouter.swift` (new file)**

```swift
struct StructureRouter {
    struct Rule { let keywords: [String]; let profileID: String }

    static let defaultRules: [Rule] = [
        .init(keywords: ["會議", "開會", "討論到", "決議", "議程"],
              profileID: "builtin-structure-meeting"),
        .init(keywords: ["待辦", "任務", "TODO", "下一步", "等等做", "要做"],
              profileID: "builtin-structure-task"),
        .init(keywords: ["需求", "需要", "客戶說", "希望能", "規格", "spec"],
              profileID: "builtin-structure-requirement"),
        .init(keywords: ["寫信", "email", "回信", "跟他說", "麻煩"],
              profileID: "builtin-structure-letter"),
        .init(keywords: ["寫一篇", "整理成文章", "工作說明", "敘述"],
              profileID: "builtin-structure-article"),
    ]

    static func route(input: String,
                      rules: [Rule] = defaultRules,
                      fallbackID: String = "builtin-structure-fallback") -> String {
        let lower = input.lowercased()
        // Score each rule by keyword hit count; pick highest. Tie → first match.
        var best: (rule: Rule, score: Int)? = nil
        for rule in rules {
            let score = rule.keywords.filter { lower.contains($0.lowercased()) }.count
            if score > 0, score > (best?.score ?? 0) {
                best = (rule, score)
            }
        }
        return best?.rule.profileID ?? fallbackID
    }
}
```

Keep router pure (no IO, no UserDefaults) so it's trivially testable with Swift Testing.

### Builtin profiles & skills

**`Sources/VoiceInputMimo/Prompts/BuiltinPromptCatalog.swift`**

Add 6 profiles to the `profiles` array (keep existing 3 untouched):
- `builtin-structure-meeting` — outputs 摘要 / 決議 / 待辦
- `builtin-structure-task` — bullet tasks + 下一步
- `builtin-structure-requirement` — 需求初稿 + 待確認事項
- `builtin-structure-letter` — 信件主旨 + 內文段落
- `builtin-structure-article` — 文章/工作說明（書面段落）
- `builtin-structure-fallback` — generic polish (router miss)

All 6 use `mode: .structure`. Share a small set of new skills:
- `builtin-structure-output-zh` — output language same as input, no EN translation
- `builtin-structure-no-fabrication` — never invent facts not in input
- `builtin-structure-preserve-identifiers` — already exists, reuse

Each profile's `basePrompt` carries the template with concrete few-shot examples (drawn from real ASR captures in `clipboard-archive.txt` if available, otherwise crafted).

### LLM call site

**`Sources/VoiceInputMimo/LLMRefiner.swift`**

In `refine(_:requestId:mode:force:)`:
- After resolving `resolvedMode`, when mode is `.structure`, call `StructureRouter.route(input: text)` → get profile ID.
- Override active profile lookup: instead of `store.activeProfile(for: .structure)`, use `store.loadProfile(id: routedID)`.
- Rest of the flow (compose prompt, fire HTTP request) unchanged.

Add helper:
```swift
private func resolveProfileForRequest(mode: RefineMode, input: String, store: PromptStore) -> PromptProfile? {
    if mode == .structure {
        let id = StructureRouter.route(input: input)
        return try? store.loadProfile(id: id)
    }
    return try? store.activeProfile(for: mode)
}
```

### State & toggles

**`Sources/VoiceInputMimo/LLMRefiner.swift`** — add:
```swift
var structureModeEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: "structureModeEnabled") }
    set { UserDefaults.standard.set(newValue, forKey: "structureModeEnabled") }
}
```

Compound state resolves to active mode:
- `!isEnabled` → ASR raw (no LLM)
- `isEnabled && structureModeEnabled` → `.structure`
- `isEnabled && claudeCodeModeEnabled` → `.claudeCode`
- `isEnabled && !claudeCodeModeEnabled && !structureModeEnabled` → `.refine`

(`structureModeEnabled` and `claudeCodeModeEnabled` are mutually exclusive — turning one on turns the other off.)

### Hotkey: fn + ← / fn + → cycle

**`Sources/VoiceInputMimo/KeyMonitor.swift`**

`fn + ←` and `fn + →` map to **Home (kc 115)** and **End (kc 119)** with `.maskSecondaryFn` flag set on macOS. Add detection in `handle(type:event:)`:

```swift
if type == .keyDown {
    let kc = event.getIntegerValueField(.keyboardEventKeycode)
    let fnDown = event.flags.contains(.maskSecondaryFn)
    if fnDown && !fnPressed { // standalone fn+arrow, not during recording
        if kc == 115 { onCyclePrev?(); return nil }
        if kc == 119 { onCycleNext?(); return nil }
    }
}
```

Add callbacks:
```swift
var onCycleNext: (() -> Void)?
var onCyclePrev: (() -> Void)?
```

**`Sources/VoiceInputMimo/AppDelegate.swift`** — wire callbacks to mode-cycle handler:

```swift
keyMonitor.onCycleNext = { [weak self] in self?.cycleOutputMode(direction: .next) }
keyMonitor.onCyclePrev = { [weak self] in self?.cycleOutputMode(direction: .prev) }

private func cycleOutputMode(direction: CycleDirection) {
    let order: [OutputModeChoice] = [.raw, .refine, .claudeCode, .structure]
    let current = currentOutputMode()
    let idx = order.firstIndex(of: current) ?? 0
    let nextIdx = (idx + direction.delta + order.count) % order.count
    apply(order[nextIdx])
    refreshOutputModeMenu()
    // Toast: brief overlay flash showing the new mode name
}
```

### Menu bar: add 4th item

**`Sources/VoiceInputMimo/AppDelegate.swift:441-484`** — extend output submenu:

```
輸出模式
├── 中文 ASR 原文（最快）
├── 中文 LLM 修正（不翻譯）
├── 英文翻譯（附回覆語言要求）
└── 中文 複合情境（會議/任務/需求…）   ← NEW
```

Add `selectStructureOutputMode()` action mirroring the existing 3 selectors. Update `refreshOutputModeMenu()` to mark the active one with a checkmark.

### Settings

**`Sources/VoiceInputMimo/Settings/Prompts/ProfileSidebar.swift`**

- Picker gains a 3rd tag: `Text("Structure (zh)").tag(RefineMode.structure)`
- Listing & switching profiles within `.structure` mode reuses existing PromptStoreViewModel paths.

**`Sources/VoiceInputMimo/Prompts/PromptStoreViewModel.swift`**

- `profilesByMode[.structure]` — populate in `refresh()`.
- Active selection setter for `.structure` updates `structureProfileID`.

## Migration

**`Sources/VoiceInputMimo/Prompts/PromptMigration.swift`**

- `bootstrapIfNeeded()` first-launch path: write the 6 new structure profiles + new skills, set `structureProfileID = "builtin-structure-fallback"` in ActiveSelection.
- `refreshBuiltins()` (idempotent re-write on every launch) automatically picks up new builtin profiles. Existing installs upgrade without wiping App Support.
- For existing `active.json` without `structureProfileID`: `ActiveSelection` decoder uses default value (Codable). Verify with a unit test.

## Testing

**`Tests/VoiceInputMimoTests/StructureRouterTests.swift` (new)**

Parameterized tests covering each rule + miss cases:
```swift
@Test("Routes to expected profile", arguments: [
    ("我們開會討論到下一季的計畫", "builtin-structure-meeting"),
    ("等等要做 A B C 三件事", "builtin-structure-task"),
    ("客戶說他們需要一個新功能", "builtin-structure-requirement"),
    ("幫我寫信跟他說明", "builtin-structure-letter"),
    ("整理成文章發出去", "builtin-structure-article"),
    ("打字真的蠻慢的", "builtin-structure-fallback"), // miss
])
func routes(_ input: String, _ expected: String) {
    #expect(StructureRouter.route(input: input) == expected)
}
```

**`Tests/VoiceInputMimoTests/BuiltinPromptCatalogTests.swift`**

Add cases:
- 6 new profile IDs are present
- All 6 use `mode: .structure`
- `PromptComposer.render` produces non-empty output for each

**`Tests/VoiceInputMimoTests/PromptMigrationTests.swift`**

Add cases:
- Fresh bootstrap creates structure profiles + sets default `structureProfileID`
- Legacy `active.json` (without `structureProfileID`) decodes with fallback default

**KeyMonitor**

Manual test only (CGEvent tap can't be unit-tested cleanly): verify fn+← / fn+→ cycle through 4 modes during a real run.

## Eval (separate from this plan, but planned)

After this plan ships, build `scripts/bench_structure_router.py` to evaluate:
1. **Router accuracy** — feed labeled inputs (input → expected template) and measure hit rate
2. **Pipeline A/B** — for `.claudeCode`, compare 2-step (current) vs 3-step (refine → claudeCode) on a small golden set; this is orthogonal to structure mode but answers question 3 from the design discussion.

## Rollout phases

**Phase 1 — Foundation** (touches Prompts module only)
1. Add `.structure` to `RefineMode`, extend `ActiveSelection`
2. Add 6 builtin profiles + new skills to `BuiltinPromptCatalog`
3. Migration tests pass

**Phase 2 — Router**
4. Add `StructureRouter.swift` + tests
5. Wire LLMRefiner to use router for `.structure` mode

**Phase 3 — UX integration**
6. Menu bar 4th item + selectors
7. fn+arrow key cycling in KeyMonitor + AppDelegate
8. Overlay toast for mode change feedback (small)

**Phase 4 — Settings**
9. ProfileSidebar picker gains structure tag
10. PromptStoreViewModel populates structure profiles

**Phase 5 — Polish**
11. Real-content few-shot tuning (replace placeholder examples in profile basePrompts)
12. Manual end-to-end smoke test
13. Update README

Each phase is independently shippable — Phase 1+2 alone gives a working structure mode (no UI), Phase 3 adds the toggle UX, Phase 4 adds Settings.

## Risks & open questions

- **Keyword router precision** — Chinese keywords may produce false positives ("會議" appears in "我等等會議結束才有空" → routes to meeting). Mitigation: tune keyword list during Phase 5 with real captures; later phase can upgrade to LLM router (Phase B from design discussion).
- **fn+arrow conflict** — fn+← is Home, used by some apps for cursor movement. Since our event tap intercepts only when `!fnPressed` (no recording in progress), it shouldn't conflict with held-fn recording. But could conflict with apps that listen for Home. Risk: medium. Mitigation: make this hotkey configurable in Settings (Phase 6, post-MVP).
- **Profile content quality** — 6 new profiles need few-shot examples. Without real captures, MVP examples may be weak. Mitigation: ship MVP with placeholder examples, iterate based on user usage.
- **`structureModeEnabled` + `claudeCodeModeEnabled` mutual exclusion** — Two bools could go inconsistent. Mitigation: enforce in setters (turning one on turns the other off). A cleaner refactor to a single enum is deferred to avoid breaking existing UserDefaults storage.

## Out of scope (future)

- LLM-based router (Phase B)
- User-editable keyword table in Settings
- Per-template eval golden sets
- Mode-aware few-shot generation (extend `gen_polish_zh_fewshot.py` for structure mode)

## File touch summary

| File | Change |
|---|---|
| `Prompts/PromptProfile.swift` | +RefineMode.structure, +ActiveSelection.structureProfileID, +SkillCategory.planning |
| `Prompts/StructureRouter.swift` | NEW |
| `Prompts/BuiltinPromptCatalog.swift` | +6 profiles, +2-3 skills |
| `Prompts/PromptStore.swift` | minor — listProfiles/activeProfile already mode-agnostic |
| `Prompts/PromptStoreViewModel.swift` | +profilesByMode[.structure] |
| `Prompts/PromptMigration.swift` | minor — refreshBuiltins picks up new profiles automatically |
| `LLMRefiner.swift` | +structureModeEnabled, +resolveProfileForRequest using router |
| `AppDelegate.swift` | +menu item, +selector, +cycleOutputMode, +mode-toast |
| `KeyMonitor.swift` | +onCycleNext/Prev, +fn+arrow detection |
| `Settings/Prompts/ProfileSidebar.swift` | picker +structure tag |
| `Tests/.../StructureRouterTests.swift` | NEW |
| `Tests/.../BuiltinPromptCatalogTests.swift` | +structure cases |
| `Tests/.../PromptMigrationTests.swift` | +structure migration cases |
| `README.md` | document new mode |

~12 files touched, 1 new module + 1 new test file.
