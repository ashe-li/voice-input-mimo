---
title: ZeroType Roadmap — Cross-Session Handoff Prompt
slug: zerotype-handoff
status: ready-to-paste
created: 2026-05-14
purpose: 直接貼到新 Claude Code session 或 /compact 後使用，自包含恢復 context
---

# Handoff Prompt（複製下方 fenced code block 整段貼到新 session）

```
我要繼續執行 VoiceInputMimo（macOS dictation app）的 ZeroType roadmap 實作。請先讀以下兩份文件建立 context，之後我會指定要從哪個 phase 開工。

## Repo + 工具現況

- Repo 路徑：~/Documents/voice-input-mimo
- Bundle id：com.shiun.VoiceInputMimo（個人 app，shiun 是 macOS username）
- App 安裝位置：/Applications/VoiceInputMimo.app
- Build 指令：cd ~/Documents/voice-input-mimo && make install（會跑 swift build -c release + codesign + 複製到 /Applications）
- ASR 在 localhost:8766（mimo-asr int4）
- LLM refine 在 localhost:8082（qwen3-8b-mlx）
- 全 local-first，無雲端依賴

## 必讀文件（按順序）

1. plans/active/zerotype-aligned-roadmap.md（rev3）— 設計依據 / Why+What
2. plans/active/zerotype-execution-checklist.md — 線性執行清單 / How

讀完上面兩份後，再視需要快速瀏覽其他既有 plan：
- plans/active/structure-mode-template-router.md
- plans/active/prompt-profile-skill-system.md
- plans/active/asr-engine-memory-mgmt.md
- plans/active/local-meeting-captions.md

KB 中可參考：
- ~/Documents/knowledge-base/reports/2026-05-14-voice-input-mimo-zerotype-aligned-roadmap.md（roadmap 摘要）
- ~/Documents/knowledge-base/reports/2026-05-14-voice-input-mimo-fn-cycle-conflict.md（之前 ship 的 cycle toggle，是 Settings UI 對齊參考實例）

## 已鎖定的關鍵決策（不要重新討論）

1. ZeroType 10 topic 對照已完成；4 個新 REQ（A/B/C/D）已 spec
2. Sprint 1 順序（sequential）：structure-mode-template-router → prompt-profile-skill-system → asr-engine-memory-mgmt
3. Sprint 2 順序：Step 0（Workspace UI Pattern foundation）→ B（Glossary）→ C（Trace + Clipboard）→ A（Mode 4 Context-Aware）
4. Sprint 3：local-meeting-captions 獨立 app + REQ-NEW-D Workflow Chaining
5. Audio retention：永久保留，不主動 GC
6. REQ-NEW-A AX 權限：漸進式 onboarding（首次切到 Mode 4 才提示，未授權 fallback refine）
7. REQ-NEW-A 是獨立 mode 4（或 5，依 structure ship 順序），既有 raw / refine / claudeCode / structure 行為不變
8. Workspace UI Pattern（sidebar + content panel + render preview）為 B/C/D 共用 base，由 Sprint 2 Step 0 抽出
9. 長期 vision（個人語音資料 foundation app）schema 相容性 checklist 已列在 roadmap rev3，短期 ship 必須滿足

## 工作流規範

- Worktree 約定：每個 plan/phase 一個 worktree，路徑 ~/Documents/voice-input-mimo-<slug>/（sibling，非 .claude/worktrees/）
- 每 phase 結束：單元測試 + 整合測試 + make install 手動測試 + KB report + PR merge → main → 清 worktree
- 緊急 rollback：每 phase ship 前建 git tag v-phase-X.Y-pre-ship + 備份 plist + 備份 app bundle
- 既有 mode 行為**嚴格不變**：新功能不可污染 raw / refine / claudeCode / structure 任一行為

## 目前狀態：所有 plan 已完成，尚未開工

剛完成的是規劃（roadmap rev3 + execution checklist）。實作從 Pre-flight 5 項開始。

## 我接下來要做的事（請等我指定）

請先確認你已讀完上述 2 份必讀文件，回覆我「context 已建立 + 確認 Sprint X / Phase X.Y 是下一步」。我會回覆要從哪個 phase 開工（可能是 Sprint 1 Phase 1.1，也可能跳 Sprint 2 嘗鮮路線從 Phase 2.0 開始）。

開工前**不要**先動 code，先：
1. 確認 main branch 乾淨
2. 跑 Pre-flight checklist 5 項
3. 建對應 worktree

之後依 execution-checklist 對應 phase 的勾選項逐項推進。
```

---

# 使用方式

1. 在新 Claude Code session（或 `/compact` 後）複製上面 fenced code block 內全部文字
2. 貼到 prompt 並送出
3. Claude 應該會先讀兩份必讀文件後回覆「context 已建立」
4. 你再指定從 Sprint X / Phase X.Y 開始

# 注意事項

- 若 Claude 沒讀檔就要動工，請強制要求它先讀
- 若 Claude 想重新討論已鎖定的決策（例如「要不要把 context 機制縫進既有 mode」），引用本檔「已鎖定的關鍵決策」第 7 條回覆「決策已敲定，不重新討論」
- 若 plan 文件路徑改變或被歸檔，請更新本檔的「必讀文件」路徑
