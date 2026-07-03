# LLM Prewarm 與 503 重試行為

冷載情境下 refine 不降級的兩層 client 端機制。

## 錄音起點 prewarm（fnDown）

按下錄音鍵（fnDown）時，與 `warmUpASR` 並行觸發 LLM warmup：

- 觸發條件：本行程從未有成功的 LLM 活動，或距上次成功活動 > 90 秒（`LLMWarmState`，值型別、僅主執行緒存取）
- 請求形狀：一般的 `POST /v1/chat/completions`（**沒有專用 prewarm endpoint**），`mode=default`（30s gateway 預算，避免 quick 5s 在冷載中途 abort）、`max_tokens=1`（常數 `warmUpMaxTokens`）、client timeout 60s
- **fire-and-forget**：獨立 URLSession task，與 refine 的 `currentTask` 完全隔離；失敗僅記 debug log，不阻塞、不 gate 錄音或 refine
- warmup 成功與真實 refine 成功都會 stamp 活動時鐘（避免多餘的重複 warmup）

目的：讓模型載入（或 pageout 後的 page-in）與「說話 + ASR」窗口（p50 約 12s）重疊，refine 到達時模型已 warm。

## quick-mode 503 單次重試

refine（quick mode）收到 `503 + Retry-After` 時：

1. 等待 `min(Retry-After, 30s)`（缺 header 或畸形值 → 預設 15s；負值 → 預設；超大 → clamp 30s）
2. 改用 `mode=default`（30s gateway 預算）**重試恰一次**
3. 重試仍失敗 → 走既有 fallback（插入 raw ASR 文字，非錯誤畫面）

邊界：

- **僅原始 mode 為 quick 的 503 觸發重試**；default/batch 的 503 與所有非 503 錯誤（500/502/timeout）一律不重試（防 retry storm）
- 新錄音 interrupt 會取消 pending 重試：`generation` 世代計數器 + `armRetry`/`executeRetryIfCurrent` 雙層檢查，cancel 落在任何時序點都攔得下，過期重試不會執行、不會覆蓋新 job 的 `currentTask`
- 重試觸發時記 `.notice` 級 log（Console.app 可觀測機制是否生效）

測試：`LLMPrewarmTests`（10）、`LLMRefineRetryTests`（18，含 4 個注入式排程的競態測試）。
