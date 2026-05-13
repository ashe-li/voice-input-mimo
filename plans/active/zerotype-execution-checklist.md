---
title: ZeroType Roadmap — Fresh-Start Execution Checklist
slug: zerotype-execution-checklist
status: ready-to-execute
created: 2026-05-14
parent_plan: plans/active/zerotype-aligned-roadmap.md
---

# ZeroType Roadmap — Fresh-Start 執行 Checklist

> 對應 `zerotype-aligned-roadmap.md` rev3 的線性執行清單。
> 每個 phase 結束後跑驗證 → 寫 KB report → 才進下一 phase。
> Worktree 約定：每個 plan 一個 worktree（路徑 `~/Documents/voice-input-mimo-<slug>/`）。

---

## Pre-flight（開工前 0 步驟）

- [ ] 確認 `main` branch 乾淨無未 commit 改動（`git -C ~/Documents/voice-input-mimo status`）
- [ ] 確認 `make build && make install` 在 main 上可成功 build 並啟動
- [ ] 備份目前 `~/Library/Preferences/com.shiun.VoiceInputMimo.plist` 一份（執行中若資料 schema 出錯可 rollback）
- [ ] 讀過 `plans/active/zerotype-aligned-roadmap.md` 一次，確認自己對 Sprint 順序無疑問
- [ ] Cycle hotkey toggle 已 ship（本 session 完成，是後續 Settings UI 對齊參考實例）

---

## Sprint 1 — Ship 既有 3 plan（P0）

### Phase 1.1：structure-mode-template-router

依據 plan：`plans/active/structure-mode-template-router.md`

- [ ] 建 worktree：`git worktree add ~/Documents/voice-input-mimo-structure-mode -b feat/structure-mode-template-router`
- [ ] 實作 `.structure` mode（RefineMode enum 加 case，OverlayPanel label 對應）
- [ ] 實作 5 個 template（meeting / task / requirement / letter / article）
- [ ] 實作 keyword router（Swift 端，hardcoded keyword table v1）
- [ ] 加入 cycle order（raw → refine → claudeCode → structure）
- [ ] 單元測試：keyword router 對 20 條樣本句正確 dispatch
- [ ] 整合測試：5 template prompt 各有一條 golden input/output 對照通過
- [ ] `make install` + 手動測試 5 種情境
- [ ] 寫 KB report：`reports/2026-05-XX-structure-mode-template-router-ship.md`
- [ ] PR merge → main → 清 worktree（依 `worktree-prompt.md` 規範）

### Phase 1.2：prompt-profile-skill-system

依據 plan：`plans/active/prompt-profile-skill-system.md`

- [ ] 建 worktree：`git worktree add ~/Documents/voice-input-mimo-prompt-profile -b feat/prompt-profile-skill-system`
- [ ] 設計 ProfileStore（App Support JSON，shape：name / skills[] / mode / glossary?）
- [ ] 設計 SkillSnippet model + 內建 seed snippets
- [ ] Settings → Prompts pane（profile list / skill picker / preview）
- [ ] Status menu profile switcher（一鍵切 active profile）
- [ ] Import / export JSON（dotfile 同步用）
- [ ] 單元測試：ProfileStore round-trip / SkillSnippet 組合輸出
- [ ] 整合測試：切 profile 後 refine 結果跟預期 prompt 對齊
- [ ] `make install` + 手動測試 2 個 profile
- [ ] 寫 KB report
- [ ] PR merge → main → 清 worktree

### Phase 1.3：asr-engine-memory-mgmt

依據 plan：`plans/active/asr-engine-memory-mgmt.md`

- [ ] 建 worktree：`git worktree add ~/Documents/voice-input-mimo-asr-engine -b feat/asr-engine-memory-mgmt`
- [ ] 決定 baseline：commit server.py 未 commit 的 10 行或拷貝當 baseline（plan 內有此決策點）
- [ ] 實作 idle-evict（30s idle → evict）
- [ ] 加入 ASR ↔ Qwen 順序 pipeline 協調
- [ ] 建 Rapid-MLX 4-tier benchmark harness
- [ ] 跑 baseline benchmark + 改進版 benchmark，產數字對照
- [ ] 寫 KB report 含 benchmark 結果
- [ ] PR merge → main → 清 worktree

**Sprint 1 出口檢查**：
- [ ] 三 plan 全 ship + KB report 全結
- [ ] ZeroType topic 覆蓋率從 ~50% 升到 ~80%（4/5/6/7/10 全部由 plan 結果支撐）
- [ ] 既有 mode（raw / refine / claudeCode）行為無 regression

---

## Sprint 2 — Workspace Foundation + 補 ZeroType gap（P1）

### Phase 2.0：Workspace UI Pattern 抽出（前置）

- [ ] 建 worktree：`git worktree add ~/Documents/voice-input-mimo-workspace-foundation -b feat/workspace-ui-pattern`
- [ ] 設計 `WorkspacePane<Item: Identifiable>` 泛型 SwiftUI view
  - Sidebar（items list，內建 search / filter / 排序）
  - Content Panel（caller 提供 detail view builder）
  - Render Preview（caller 提供 optional preview builder）
- [ ] 與既有 Settings panes 視覺對齊（NavigationSplitView / Form / SectionHeading）
- [ ] 寫 Mock pane：顯示 dummy items 可 add/edit/delete，跑 SwiftUI Preview 通過
- [ ] 單元測試：component API（Item 注入 / actions callback）
- [ ] 不直接 merge — 留 branch，等 Phase 2.1 第一個 consumer 驗證後再 merge

### Phase 2.1：REQ-NEW-B — User-extensible Glossary

第一個 consumer，驗證 Workspace component 設計。

- [ ] 在 workspace-foundation worktree 上繼續開（或從該 branch 切新 branch）
- [ ] 設計 GlossaryStore（JSON 在 `App Support/Workspaces/Glossary/default.json`）
- [ ] 把現有 hardcoded glossary（claudeCodeSystemPrompt 內）匯入作為 seed
- [ ] Settings → 新一層分類「Workspaces」→ Glossary
  - 採 `WorkspacePane<GlossaryEntry>`
  - 詞條 inline 編輯（spoken / 正字 / 觸發場景）
  - Render preview：底部顯示「最終注入 prompt 後長這樣」
- [ ] Import / export JSON
- [ ] Refine / claudeCode mode 注入 glossary（從 hardcoded 改成從 store 讀）
- [ ] 若 Workspace component API 在此 phase 不好用 → **回頭調整 component**（不繞過）
- [ ] 單元測試：GlossaryStore round-trip / prompt 注入結果
- [ ] 整合測試：加一個新詞「vocus → vocus」後跑 refine，確認不被改成 focus
- [ ] `make install` + 手動測試
- [ ] 寫 KB report
- [ ] PR merge（含 Workspace component + Glossary）→ main → 清 worktree

### Phase 2.2：REQ-NEW-C — Trace + Clipboard 整合

- [ ] 建 worktree：`git worktree add ~/Documents/voice-input-mimo-trace-clipboard -b feat/trace-clipboard-integration`
- [ ] 設計 Trace data model（UUID / timestamps / audio metadata / log entries / clipboardId?）
- [ ] 設計 TraceStore（JSON Lines `App Support/Workspaces/Traces/*.jsonl`，永久保留）
- [ ] ClipboardArchive schema migration：加 `traceId: UUID?`，舊資料 nil（向後相容）
- [ ] Recording pipeline 改：每次錄音建 trace，state transitions 寫 log entries
- [ ] Settings → Workspaces → Clipboard History（採 WorkspacePane）
  - Sidebar：時序列 traces + clipboard，filter（unprocessed / paste / archived）
  - Content panel：audio 可播 / ASR / refine / final 四段對照
  - Actions：refine 重跑 / structure 變待辦 / 套 profile / 匯出 markdown / 刪除
- [ ] 新快捷鍵 Ctrl+Opt+R = park mode（錄音 → ASR → 存 trace + clipboard 但不 paste）
- [ ] Retention 設定 UI（預設永久，顯示目前 trace 數 + 磁碟占用）
- [ ] Export JSONL CLI 命令
- [ ] Schema 相容性 checklist 驗證（audio 永久 / 三層 schema / JSONL / 雙向 link / local-first）
- [ ] 單元測試：TraceStore round-trip / ClipboardArchive migration / park mode 流程
- [ ] 整合測試：錄一段 → park → 從 Workspace 重跑 refine → 確認 paste 出來
- [ ] `make install` + 手動測試
- [ ] 寫 KB report
- [ ] PR merge → main → 清 worktree

### Phase 2.3：REQ-NEW-A — Mode 4 Context-Aware Auto Tone Prediction

最後做，相依 B（glossary）+ C（trace dispatch schema）已就位。

- [ ] 建 worktree：`git worktree add ~/Documents/voice-input-mimo-context-aware -b feat/mode-4-context-aware`
- [ ] 加入 `RefineMode.contextAware` enum case
- [ ] OverlayPanel HUD 顯示新 label（如「Auto」）
- [ ] Cycle order 加進去：raw → refine → claudeCode → structure → contextAware → back to raw
- [ ] Context capture 實作：
  - active app bundle id（NSWorkspace.frontmostApplication）
  - window title（AX API）
  - clipboard tail（NSPasteboard，8KB 限）
  - selected text（AX AXSelectedText）
- [ ] 隱私 redact：clipboard / selected text 含 secret 關鍵字（password / token / key / secret）自動清除
- [ ] 內建 tone mapping（hardcoded v1，採 dict）：
  - `com.apple.mail` → 正式書信 tone
  - `com.todesktop.230313mzl4w4u92` (Cursor) → claudeCode prompt
  - 終端機（iTerm/Terminal） → claudeCode
  - Slack / LINE / Messages → casual cleanup
  - Notion / Bear / Obsidian → 筆記 polish
  - Default → refine fallback
- [ ] AX 權限漸進式 onboarding：
  - 首次切到 Mode 4 觸發 AX 權限 prompt
  - 未授權 → fallback 到 refine + overlay 標示「Context capture unavailable」
- [ ] 與 REQ-NEW-B glossary 整合：注入
- [ ] 與 prompt-profile-skill-system 整合：profile 可宣告「該 profile 在哪些 app context 下優先採用」
- [ ] Settings → Workspaces → Tone Mapping（採 WorkspacePane，可看 + 改 app → tone 對應）
- [ ] 單元測試：context capture / redact / mapping / fallback
- [ ] 整合測試：在 Mail.app 跟 Cursor 各跑一次 dictation，結果語氣對齊預期
- [ ] **回歸測試**：raw / refine / claudeCode / structure 四個既有 mode 行為完全不變
- [ ] `make install` + 手動測試
- [ ] 寫 KB report
- [ ] PR merge → main → 清 worktree

**Sprint 2 出口檢查**：
- [ ] Workspace Pattern component 落地，B/C/A 三 REQ 都 consume 同一個 base
- [ ] ZeroType 覆蓋率 ~80% → ~95%（補 9 全到位，8 從 partial 升 full，2 部分補 chain 留 Sprint 3）
- [ ] Schema 相容性 checklist 全綠
- [ ] 既有 mode 無 regression

---

## Sprint 3 — Polish + 跨 app 擴張（P2）

### Phase 3.1：local-meeting-captions 獨立 app（依現有 plan）

依據 plan：`plans/active/local-meeting-captions.md`

- [ ] 依該 plan 之 Phase 0 → Phase 6 步驟執行（不在此 checklist 展開，因該 plan 本身已有詳細階段）
- [ ] 通過該 plan 之 acceptance gates（Phase 1-6 各 e2e gate）
- [ ] MVP ship + KB report

### Phase 3.2：REQ-NEW-D — Workflow Chaining

- [ ] 建 worktree：`git worktree add ~/Documents/voice-input-mimo-workflow-chain -b feat/workflow-chaining`
- [ ] 設計 Workflow data model（name / steps[] / outputPolicy）
- [ ] WorkflowStore：`App Support/Workspaces/Workflows/*.json`
- [ ] Settings → Workspaces → Workflows（採 WorkspacePane）
  - Sidebar：workflow chains list
  - Content panel：inline 編輯 steps（拖曳排序、選 mode、綁 profile）
  - Render preview：試跑樣本看 step-by-step 輸出
- [ ] 快捷鍵綁定 chain 執行
- [ ] 失敗 fallback：任一 step LLM 失敗 → 回退上一 step + 標示
- [ ] 與 REQ-NEW-A 整合：context-aware 可 dispatch 到 workflow
- [ ] 單元測試：chain 執行流 / fallback
- [ ] 整合測試：跑「refine → structure → 翻 EN」三步 chain
- [ ] `make install` + 手動測試
- [ ] 寫 KB report
- [ ] PR merge → main → 清 worktree

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
