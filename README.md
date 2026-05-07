# voice-input-mimo

獨立分支 — 改用 **MiMo-V2.5-ASR**（Xiaomi 開源、原生支援中英 code-switching）取代 Apple Speech 做語音辨識，搭配本地 LLM（LM Studio）做後處理。

> **狀態**：Phase A — Python ASR service 已可運作。Phase B（Swift app fork）尚未動工。
>
> 不污染 `~/Documents/voice-input-src/`（Apple Speech 版繼續存在）。

## 為什麼需要這個分支

`voice-input-src` 用 Apple Speech zh-TW 做 STT，對中英混場景不行：

- Apple Speech 把英文縮寫聽成 ASCII 散字（`LLM` → `L M K`、`API` → `A屁I`）
- 把英文詞音譯成中文（`Python` → `派森`、`React` → `瑞克特`、`component` → `康波奶特`）
- LLM 後處理可救一些，但只用 4B 模型救不回大部分

MiMo-V2.5-ASR 原生支援中英 code-switching（Xiaomi 訓練資料含大量混合語言），對開發者場景顯著好。

代價：失去 streaming partial result（要錄完才轉），多一個 Python service 要管。

## 架構

```
~/Documents/voice-input-mimo/
├── server/                      ← Phase A（已完成）
│   ├── server.py                FastAPI + Whisper-compat endpoint
│   ├── pyproject.toml           uv-managed dependencies
│   ├── run.sh                   啟動腳本
│   ├── test_smoke.sh            curl 測試
│   └── .venv/                   Python 3.12 venv
└── (Sources/, Package.swift, Makefile ...)   ← Phase B（待 Phase A 驗證後開工）
```

## Server API

OpenAI Whisper 相容：

| Method | Path | 說明 |
|---|---|---|
| GET | `/v1/health` | 健康檢查 + 已 load model + OpenCC 設定 + zhtw rules 數 |
| GET | `/v1/models` | 列出已掛載模型 |
| POST | `/v1/audio/transcriptions` | 上傳音檔 → 文字 |

POST 表單欄位（multipart）：
- `file`（必填）：wav / aiff / mp3 etc.
- `language`（選填）：`auto` / `zh` / `en`，預設 `auto`
- `model`（選填）：相容性接受但忽略
- `response_format`（選填）：`json`（預設）/ `text`
- `output_locale`（選填）：`zh-TW`（預設）/ `none`

## 簡體 → 繁體（兩段 post-process）

MiMo-V2.5-ASR 訓練資料以簡體為主，輸出預設是簡體。本 server 預設套用兩段 post-process：

1. **OpenCC s2twp** — 廣域字元 + 一般詞彙轉換（软件→軟體、默认→預設、视频→影片、内存→記憶體）
2. **zhtw-mcp ruleset**（[sysprog21/zhtw-mcp](https://github.com/sysprog21/zhtw-mcp)）— IT 領域專業術語替換（主線程→主執行緒、網關→閘道器、内核映象→核心映像檔）

啟動時自動載入；無 OpenCC / 無 ruleset 時 silently fallback 為純 ASR 輸出。

### 觀察輸出時 raw vs converted

```bash
curl -s -X POST http://127.0.0.1:8765/v1/audio/transcriptions \
    -F file=@audio.wav -F language=auto | jq .
```

回應：
```json
{
  "text": "幫我重構這個軟體的閘道器設定",
  "raw_text": "帮我重构这个软件的网关设置",
  "language": "auto",
  "output_locale": "zh-TW",
  "duration_ms": 1768
}
```

`raw_text` 只在 post-process 改變內容時才出現（節省 payload）。

## 啟動

```bash
cd ~/Documents/voice-input-mimo/server

# 第一次跑會下載 4.5 GB model（int4 MLX）到 ~/.cache/mimo-asr/
MIMO_PRELOAD=1 ./run.sh
```

環境變數：
| Var | 預設 | 說明 |
|---|---|---|
| `MIMO_PRECISION` | `int4` | 也可 `bf16`（品質微高、顯存翻倍） |
| `MIMO_MODEL_ROOT` | `~/.cache/mimo-asr` | 模型存放位置 |
| `MIMO_PRELOAD` | `0` | `1` = 啟動時就 load（首次啟動較慢但首請求快） |
| `PORT` | `8765` | HTTP port |
| `MIMO_DEFAULT_LANGUAGE` | `auto` | 缺省語言 hint |

## Smoke test

```bash
./test_smoke.sh
```

會用 macOS `say` 生成三段音檔（純中、中英混、技術術語），打 server 比對轉錄品質。

## Phase B：Swift app（尚未動工）

目標：fork voice-input-src，把 `SpeechEngine.swift` 換成：
- `AudioRecorder.swift`：AVAudioEngine 錄成 wav (16kHz mono PCM)
- `ASRClient.swift`：multipart POST → JSON
- AppDelegate flow：Fn down → 開錄音、Fn up → 停 → POST → LLMRefiner → 貼上

不同 bundle id（`com.shiun.VoiceInputMimo`）讓兩個 app 並存。

## License

服務端程式：MIT。
模型權重：MiMo-V2.5-ASR (MIT)、carloshuang1224/MiMo-V2.5-ASR-MLX-INT4 (sub-license follows)。
