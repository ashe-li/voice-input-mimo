# Engine 併發模型

MiMo ASR engine（FastAPI/uvicorn 單行程）的推論排程與 Metal 操作序列化。

## 推論執行緒模型

所有 MLX 推論與 Metal cache 操作序列化於兩層機制：

1. **專屬 `ThreadPoolExecutor(max_workers=1)`**（thread 名前綴 `mlx-infer`）
   - 私有 pool（非 asyncio 預設 threadpool）
   - 保證每次推論落在同一條 OS thread（MLX/Metal 有 thread-affinity 敏感性）
2. **`asyncio.Lock`（`infer_lock`）**
   - `POST /v1/audio/transcriptions` 於呼叫 `asr.transcribe()` 前取鎖
   - `/admin/evict` 與 idle 驅逐（`idle_check_loop` 的 `_guarded_evict`，鎖內重驗 idle 是否仍成立）同樣取鎖
   - 保證同時間僅有一個推論或 Metal trim 在執行

推論期間 event loop 保持存活：`GET /v1/health` 不取鎖、不碰模型，於推論 in-flight 時仍以毫秒級回應（實測 0.9–6ms）。

## 已知限制：cold-load 仍在 event loop 上

`asr_model.get()` 的 loader 目前同步跑在 event loop（未 offload），**模型冷載期間 `/v1/health` 會被 block 該冷載時長**。冷載屬一次性（啟動或 idle 驅逐後首次請求），warm 推論路徑不受影響。可用 `ENGINE_PRELOAD=1`（或相容別名 `MIMO_PRELOAD=1`）於啟動即載入以避開首請求延遲。

## Shutdown 順序（lifespan 清理）

1. 取消背景任務（idle loop、Qwen poll loop）
2. **Drain post-response audit tasks**（`app.state.post_work_tasks`，上限 `ENGINE_POST_WORK_DRAIN_TIMEOUT_S`=10s）——保證每筆請求的 JSONL audit 記錄在關閉前寫出
3. **鎖內 evict**（`async with infer_lock: await asr_model.evict()`）——trim 經仍存活的 executor 執行於 `mlx-infer` thread
4. `infer_executor.shutdown(wait=True)`

Post-response 工作（Metal trim + vmmap snapshot）於 handler 交還 event loop 前即提交 executor（排在下一個請求的推論之前，不會被持續流量無限延後）。

## 相關環境變數

| Env Var | 預設 | 用途 |
|---|---|---|
| `ENGINE_PRELOAD`（別名 `MIMO_PRELOAD`） | `0` | `1` = 啟動即載入模型，避免首請求冷載 |
| `ENGINE_METAL_CACHE_LIMIT_MB` | `1024` | Metal cache 上限 |
| `ENGINE_POST_WORK_DRAIN_TIMEOUT_S` | `10` | shutdown 時等待 audit 背景工作的上限 |
| `ENGINE_IDLE_LADDER_SECONDS` | `180,420,900` | adaptive idle 驅逐階梯 |
| `ENGINE_IDLE_HARD_CEILING_SECONDS` | `1800` | idle 驅逐硬上限 |

回歸測試：`scripts/test_engine_transcribe_offload.py`（health in-flight 可用、推論序列化、單執行緒 affinity、例外傳播、evict 序列化、post-work thread、shutdown drain audit）。
