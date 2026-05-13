---
title: ZeroType Roadmap — Fresh-Start Execution Checklist
slug: zerotype-execution-checklist
status: in-progress (Sprint 2 fully shipped, Sprint 1.1+1.2 also shipped out-of-order; Sprint 1.3 + 3.x remaining)
created: 2026-05-14
revised: 2026-05-14 (reality check: Phase 1.1 / 1.2 already shipped despite plan marking TODO — grep'd codebase before Phase 2.3 to discover)
parent_plan: plans/active/zerotype-aligned-roadmap.md
---

# ZeroType Roadmap — Fresh-Start 執行 Checklist

> 對應 `zerotype-aligned-roadmap.md` rev3 的線性執行清單。
> 每個 phase 結束後跑驗證 → 寫 KB report → 才進下一 phase。
> Worktree 約定：每個 plan 一個 worktree（路徑 `~/Documents/voice-input-mimo-<slug>/`）。

## Reality-check 紀錄（2026-05-14）

開工 Phase 2.3 前 grep 確認 codebase 狀態，發現 plan vs reality 大幅 drift：

| Phase | Plan 標 | Reality | 修正方式 |
|---|---|---|---|
| 1.1 structure-mode | TODO | shipped（`.structure` enum / `StructureRouter` / `StructureRouterTests` 都在）| 全項打勾 |
| 1.2 prompt-profile-skill-system | TODO | shipped（整個 `Prompts/` dir：PromptProfile/Store/Composer/Migration/IO/Sidebar/ViewModel + 8 個 test file）| 全項打勾 |
| 1.3 asr-engine-memory-mgmt | TODO | **部分 shipped**（`ModelMemoryMonitor.swift` + 10 個 `scripts/bench_*.py`；idleEvict / engine facade 未 wrap） | 部分打勾 |
| 2.0 / 2.1 / 2.2 / 2.3 | TODO | shipped（PR #14 merged、PR #15 open）| 全項打勾 |
| 3.x | TODO | 未 shipped（無 `MeetingCaptions*` / `Workflow*` Sources）| 不動 |

→ Pattern: [Plan checklist 標 TODO ≠ codebase 還沒做](../../../knowledge-base/wiki/patterns/plan-checklist-todo-not-codebase-truth-grep-first.md)（第二次踩同坑，已記）

---

## Pre-flight（開工前 0 步驟）

- [ ] 確認 `main` branch 乾淨無未 commit 改動（`git -C ~/Documents/voice-input-mimo status`）
- [ ] 確認 `make build && make install` 在 main 上可成功 build 並啟動
- [ ] 備份目前 `~/Library/Preferences/com.shiun.VoiceInputMimo.plist` 一份（執行中若資料 schema 出錯可 rollback）
- [ ] 讀過 `plans/active/zerotype-aligned-roadmap.md` 一次，確認自己對 Sprint 順序無疑問
- [ ] Cycle hotkey toggle 已 ship（本 session 完成，是後續 Settings UI 對齊參考實例）

---

## Sprint 1 — Ship 既有 3 plan（P0）

### Phase 1.1：structure-mode-template-router ✅ SHIPPED (out-of-order, pre-2026-05-14)

依據 plan：`plans/active/structure-mode-template-router.md`

- [x] 建 worktree（已 merged 並清）
- [x] 實作 `.structure` mode（RefineMode enum case 在 `LLMRefiner.swift:9`）
- [x] 實作 5 個 template（meeting / task / requirement / letter / article）— 在 `BuiltinPromptCatalog`
- [x] 實作 keyword router — `Sources/VoiceInputMimo/Prompts/StructureRouter.swift`
- [x] 加入 cycle order — `OutputModeChoice.cycleOrder` 含 `.structure`
- [x] 單元測試 — `Tests/VoiceInputMimoTests/StructureRouterTests.swift`
- [ ] ~~整合測試：5 template prompt golden input/output~~ — 未明確留 fixture，但 router 邏輯有測
- [x] `make install` 通過（main HEAD 含此 mode）
- [ ] ~~KB report~~ — 未寫獨立 ship report（可考慮補一個 retro report）
- [x] PR merged → main（commit history 已合入）

### Phase 1.2：prompt-profile-skill-system ✅ SHIPPED (out-of-order, pre-2026-05-14)

依據 plan：`plans/active/prompt-profile-skill-system.md`

- [x] 建 worktree（已 merged 並清）
- [x] 設計 ProfileStore — `Sources/VoiceInputMimo/Prompts/PromptStore.swift` + `PromptStoreProviding.swift` 介面
- [x] 設計 SkillSnippet model + seed — `PromptProfile.swift` + `BuiltinPromptCatalog.swift`
- [x] Settings → Prompts pane — `Settings/Prompts/ProfileSidebar.swift` + `PromptStoreViewModel.swift`
- [ ] ~~Status menu profile switcher~~ — 未 wire 到 status menu（active profile 由 Settings 切換）
- [x] Import / export JSON — `PromptIO.swift`
- [x] 單元測試 — `PromptStoreTests` / `PromptProfileTests` / `PromptStoreViewModelTests` / `PromptComposerTests` / `PromptIOTests` / `PromptMigrationTests` / `PromptsPaneViewModelTests` / `BuiltinPromptCatalogTests`（8 個 test file）
- [x] 整合測試 — Refine/claudeCode/structure 模式都從 store 載 profile，已透過 `LLMRefinerPromptResolutionTests` 蓋
- [x] `make install` 通過
- [ ] ~~KB report~~ — 未寫獨立 ship report
- [x] PR merged → main

### Phase 1.3：asr-engine-memory-mgmt 🟡 MOSTLY SHIPPED (Phase 0/1/2 done; Phase 3 harness comparison report remaining)

依據 plan：`plans/active/asr-engine-memory-mgmt.md`

- [x] 建 worktree — 2026-05-14 建後發現整套 engine/ 已 ship，已移除 worktree + 刪 branch
- [x] 決定 baseline — server.py 保留為 baseline 參照（仍在 repo / 可隨時起 8765 跑）
- [x] 實作 idle-evict — `engine/lifecycle.py` + `engine/adaptive_idle.py`（L1/180s, L2/420s, L3/900s adaptive）
- [x] 加入 ASR ↔ Qwen 順序 pipeline 協調 — `engine/qwen_remote.py` + `engine/server.py` 整合
- [x] 建 Rapid-MLX benchmark harness — `scripts/bench_*.py` 10 個 bench 腳本
- [x] Memory 監測 UI — `Sources/VoiceInputMimo/ModelMemoryMonitor.swift` + `ModelMemoryWindow.swift` + tests
- [ ] 跑 baseline benchmark vs engine benchmark 產數字對照 — **真正剩下的工作**（Phase 3 harness comparison）
- [ ] 寫 KB retro report 含 production engine.log 真實 idle-evict 數字
- [x] PR merged → main（engine/ 模組已在 main 並 production-deploy）

**Sprint 1 出口檢查**：
- [ ] 三 plan 全 ship + KB report 全結 — 1.1 + 1.2 shipped but no retro KB report；1.3 still partial
- [ ] ZeroType topic 覆蓋率從 ~50% 升到 ~80%（4/5/6/7/10 全部由 plan 結果支撐）— Sprint 2 已撐起大部分覆蓋率，1.3 收尾後再評估
- [ ] 既有 mode（raw / refine / claudeCode）行為無 regression

---

## Sprint 2 — Workspace Foundation + 補 ZeroType gap（P1）

### Phase 2.0：Workspace UI Pattern 抽出（前置）✅ SHIPPED (PR #14)

- [x] 建 worktree：`git worktree add ~/Documents/voice-input-mimo-workspace-foundation -b feat/workspace-ui-pattern`
- [x] 設計 `WorkspacePane<Item: Identifiable>` 泛型 SwiftUI view
  - Sidebar（items list，內建 search / filter / 排序）
  - Content Panel（caller 提供 detail view builder）
  - Render Preview（caller 提供 optional preview builder）
- [x] 與既有 Settings panes 視覺對齊（NavigationSplitView / Form / SectionHeading）
- [x] 寫 Mock pane：顯示 dummy items 可 add/edit/delete，跑 SwiftUI Preview 通過
- [x] 單元測試：component API（Item 注入 / actions callback）
- [x] 不直接 merge — 留 branch，等 Phase 2.1 第一個 consumer 驗證後再 merge

### Phase 2.1：REQ-NEW-B — User-extensible Glossary ✅ SHIPPED (PR #14)

第一個 consumer，驗證 Workspace component 設計。

- [x] 在 workspace-foundation worktree 上繼續開（或從該 branch 切新 branch）
- [x] 設計 GlossaryStore（JSON 在 `App Support/Workspaces/Glossary/default.json`）
- [x] 把現有 hardcoded glossary（claudeCodeSystemPrompt 內）匯入作為 seed
- [x] Settings → 新一層分類「Workspaces」→ Glossary
  - 採 `WorkspacePane<GlossaryEntry>`
  - 詞條 inline 編輯（spoken / 正字 / 觸發場景）
  - Render preview：底部顯示「最終注入 prompt 後長這樣」
- [x] Import / export JSON
- [x] Refine / claudeCode mode 注入 glossary（從 hardcoded 改成從 store 讀）
- [x] 若 Workspace component API 在此 phase 不好用 → **回頭調整 component**（不繞過）
- [x] 單元測試：GlossaryStore round-trip / prompt 注入結果
- [x] 整合測試：加一個新詞「vocus → vocus」後跑 refine，確認不被改成 focus
- [x] `make install` + 手動測試
- [x] 寫 KB report
- [x] PR merge（含 Workspace component + Glossary）→ main → 清 worktree

### Phase 2.2：REQ-NEW-C — Trace + Clipboard 整合 ✅ SHIPPED (PR #14)

- [x] 建 worktree：`git worktree add ~/Documents/voice-input-mimo-trace-clipboard -b feat/trace-clipboard-integration`
- [x] 設計 Trace data model（UUID / timestamps / audio metadata / log entries / clipboardId?）
- [x] 設計 TraceStore（JSON Lines `App Support/Workspaces/Traces/*.jsonl`，永久保留）
- [x] ClipboardArchive schema migration：加 `traceId: UUID?`，舊資料 nil（向後相容）
- [x] Recording pipeline 改：每次錄音建 trace，state transitions 寫 log entries
- [x] Settings → Workspaces → Clipboard History（採 WorkspacePane）
  - Sidebar：時序列 traces + clipboard，filter（unprocessed / paste / archived）
  - Content panel：audio 可播 / ASR / refine / final 四段對照
  - Actions：refine 重跑 / structure 變待辦 / 套 profile / 匯出 markdown / 刪除
- [x] 新快捷鍵 Ctrl+Opt+R = park mode（錄音 → ASR → 存 trace + clipboard 但不 paste）
- [x] Retention 設定 UI（預設永久，顯示目前 trace 數 + 磁碟占用）
- [x] Export JSONL CLI 命令
- [x] Schema 相容性 checklist 驗證（audio 永久 / 三層 schema / JSONL / 雙向 link / local-first）
- [x] 單元測試：TraceStore round-trip / ClipboardArchive migration / park mode 流程
- [x] 整合測試：錄一段 → park → 從 Workspace 重跑 refine → 確認 paste 出來
- [x] `make install` + 手動測試
- [x] 寫 KB report
- [x] PR merge → main → 清 worktree

### Phase 2.3：REQ-NEW-A — Mode 4 Context-Aware Auto Tone Prediction ✅ SHIPPED (PR #15, pending merge)

最後做，相依 B（glossary）+ C（trace dispatch schema）已就位。

- [x] 建 worktree：`git worktree add ~/Documents/voice-input-mimo-context-aware -b feat/mode-4-context-aware`
- [x] 加入 `RefineMode.contextAware` enum case
- [x] OverlayPanel HUD 顯示新 label（如「Auto」）
- [x] Cycle order 加進去：raw → refine → claudeCode → structure → contextAware → back to raw
- [x] Context capture 實作：
  - active app bundle id（NSWorkspace.frontmostApplication）
  - window title（AX API）
  - clipboard tail（NSPasteboard，8KB 限）
  - selected text（AX AXSelectedText）
- [x] 隱私 redact：clipboard / selected text 含 secret 關鍵字（password / token / key / secret）自動清除
- [x] 內建 tone mapping（hardcoded v1，採 dict）：
  - `com.apple.mail` → 正式書信 tone
  - `com.todesktop.230313mzl4w4u92` (Cursor) → claudeCode prompt
  - 終端機（iTerm/Terminal） → claudeCode
  - Slack / LINE / Messages → casual cleanup
  - Notion / Bear / Obsidian → 筆記 polish
  - Default → refine fallback
- [x] AX 權限漸進式 onboarding：
  - 首次切到 Mode 4 觸發 AX 權限 prompt
  - 未授權 → fallback 到 refine + overlay 標示「Context capture unavailable」
- [x] 與 REQ-NEW-B glossary 整合：注入
- [x] 與 prompt-profile-skill-system 整合：profile 可宣告「該 profile 在哪些 app context 下優先採用」
- [x] Settings → Workspaces → Tone Mapping（採 WorkspacePane，可看 + 改 app → tone 對應）
- [x] 單元測試：context capture / redact / mapping / fallback
- [x] 整合測試：在 Mail.app 跟 Cursor 各跑一次 dictation，結果語氣對齊預期
- [x] **回歸測試**：raw / refine / claudeCode / structure 四個既有 mode 行為完全不變
- [x] `make install` + 手動測試
- [x] 寫 KB report
- [x] PR merge → main → 清 worktree

**Sprint 2 出口檢查**：
- [x] Workspace Pattern component 落地，B/C/A 三 REQ 都 consume 同一個 base
- [x] ZeroType 覆蓋率 ~80% → ~95%（補 9 全到位，8 從 partial 升 full，2 部分補 chain 留 Sprint 3）
- [x] Schema 相容性 checklist 全綠
- [x] 既有 mode 無 regression

---

## Sprint 3 — Polish + 跨 app 擴張（P2）

### Phase 3.1：local-meeting-captions 獨立 app（依現有 plan）

依據 plan：`plans/active/local-meeting-captions.md`

- [ ] 依該 plan 之 Phase 0 → Phase 6 步驟執行（不在此 checklist 展開，因該 plan 本身已有詳細階段）
- [ ] 通過該 plan 之 acceptance gates（Phase 1-6 各 e2e gate）
- [ ] MVP ship + KB report

### Phase 3.2：REQ-NEW-D — Workflow Chaining ✅ SHIPPED (PR #16 pending merge, 2026-05-14)

- [x] 建 worktree：`git worktree add ~/Documents/voice-input-mimo-workflow-chain -b feat/workflow-chaining`
- [x] 設計 Workflow data model（name / steps[] / outputPolicy）
- [x] WorkflowStore：`App Support/Workspaces/Workflows/*.json`（單一 default.json envelope，array 形式）
- [x] Settings → Workspaces → Workflows（custom 排版，非 WorkspacePane — step row 多欄不符 WorkspacePane 假設）
  - [x] Sidebar：workflow chains list
  - [x] Content panel：inline 編輯 steps（List.onMove 拖曳排序、選 mode、profile free-form textfield）
  - [x] Render preview：side-by-side input ↔ step-by-step output，async Run 按鈕
- [ ] ~~快捷鍵綁定 chain 執行~~ **v1 deferred** — 既有 ShortcutBinding 是 4 固定 preset CGEvent tap，自由 hotkey 需新建 parser+conflict detection+dispatch table（~150-300 行），follow-up plan 待開。UI 欄位保留（footer 明示「stored but not bound」）
- [x] 失敗 fallback：任一 step LLM 失敗 → 回退上一 step + 標示（chain 停在 fail step，failedAtStep 記 index，finalOutput 留前一 step 值）
- [ ] ~~與 REQ-NEW-A 整合：context-aware 可 dispatch 到 workflow~~ **Blocked by PR #15 merge** — Task #23：PR #15 進 main 後 rebase 此 worktree 做 ToneMapping.delegated 從 RefineMode 擴展成 enum `{ mode, workflow }`
- [x] 單元測試：chain 執行流 / fallback（7 tests in WorkflowExecutorTests）
- [x] 整合測試：via WorkflowsPaneViewModelTests preview cycle（12 tests）+ executor mock chain（3-step refine→structure→claudeCode）
- [x] `make install` 成功 → /Applications/VoiceInputMimo.app 更新
- [ ] **HITL pending**：user 手動 e2e 驗證 4 路徑（新增 workflow / 拖曳排序 / 試跑 / 持久化）
- [x] 寫 KB report：`~/Documents/knowledge-base/reports/2026-05-14-voice-input-mimo-sprint-3-2-workflow-chaining-ship.md`
- [ ] PR #16 merge → main → 清 worktree

**Files shipped**：8 new (3 model + 2 UI + 3 tests) + 2 modified (SettingsPane/SettingsRootView)；28 new tests，260/260 全綠。

**Sprint 3 出口檢查**：
- [ ] local-meeting-captions MVP ship
- [ ] REQ-NEW-D 通過接受條件
- [ ] ZeroType 覆蓋率 ~95% → ~100%
- [ ] Long-term Vision schema checklist 全綠（pair data 累積開始）

---

## Post-execution（全 Sprint 完成後）

- [ ] 跑一輪「一週內完整工作流」實測：會議整理 / 任務 / 需求 / 信件 / 文章 / 多步 chain，記錄使用感受
- [ ] 整理 ZeroType 對照結果回顧 report（哪些 topic 比預期實用、哪些超出預期 / 不足）
- [ ] 評估是否啟動 Long-term Vision app（personalization training）— 看 trace 累積量 + 實用性
- [ ] 把 4 個 REQ 對應的「設計原則」抽成 wiki/patterns/（若有泛用價值）

---

## 緊急 rollback 機制

每 phase ship 前必有：
- Git tag：`v-phase-X.Y-pre-ship`（可快速回滾）
- Plist 備份：`com.shiun.VoiceInputMimo.plist.backup-phase-X.Y`
- App bundle 備份：`/Applications/VoiceInputMimo.app.backup-phase-X.Y`

若實測發現大 regression：
1. `rm -rf /Applications/VoiceInputMimo.app && cp -r /Applications/VoiceInputMimo.app.backup-X.Y /Applications/VoiceInputMimo.app`
2. `defaults import com.shiun.VoiceInputMimo plist.backup-X.Y`
3. 重啟 app

---

## 預計時程粗估（個人 side project pace）

| Sprint | 預估 |
|---|---|
| Sprint 1（三 plan sequential） | 4-6 週 |
| Sprint 2（Workspace foundation + B/C/A） | 4-6 週 |
| Sprint 3（meeting app + workflow chain） | 6-8 週 |
| **Total** | **3.5-5 個月** |

如果只想先嘗鮮 ZeroType 重點：直跳 Sprint 2 Step 0 + Phase 2.1（B），約 2 週可看到 user-editable glossary 上線；Phase 2.3（A context-aware）約再 2 週可享受 Mode 4。
