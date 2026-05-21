# Mic Device Status Bar Dropdown + Phantom Detection

**起因：** 2026-05-22 phantom「外接麥克風」default input 導致 VoiceInputMimo 全錄 silence，user 不知道用的是哪個 mic、也沒有自助切換途徑。

**目標：** 在 menu bar 提供 input device 顯示 + 切換能力，並在 app 啟動時偵測 phantom default → 主動警告。

---

## Scope

### A. Menu bar 「Microphone」submenu

加在 `AppDelegate.swift:625` ASR Server submenu 旁邊（同 ladder 層級）：

```
🎙 Microphone ▶
   Current: MacBook Pro 的麥克風  (灰色，非互動)
   ────────────────────────
   ✓ MacBook Pro 的麥克風       ← 圓點表示當前 default
     外接麥克風 ⚠              ← 偵測到 phantom 時加警告 emoji
     Microsoft Teams Audio
   ────────────────────────
   Refresh devices
```

- 點 device 名稱 → 切系統 default input
- 不依賴 `SwitchAudioSource` CLI（user 不一定裝 brew package）→ 用 Core Audio HAL API

### B. Phantom detection（app 啟動時）

啟動流程加入 `InputDeviceDiagnostics.checkPhantomOnLaunch()`：

1. 列舉所有 input devices
2. 對 system default input 做 200ms peek capture（用 `AVCaptureSession` 或 `AVAudioEngine` tap）
3. 計算 RMS — 若 < 1e-4：
   - Console.log 警告
   - Menu bar status icon 加紅色徽章（NSStatusItem.button.image with overlay）
   - 首次彈 NSAlert：「偵測到 default mic 可能無訊號（RMS=...），建議切換到 [...]」+ 兩個按鈕：「切到 MacBook Pro 的麥克風」/「忽略」

### C. Live RMS indicator（stretch goal，可後續迭代）

Submenu Current 行可加上即時 RMS bar：
```
Current: MacBook Pro 的麥克風 ▁▃▅▇▅▃▁
```

第一版**不做**，避免動 audio capture path。

---

## Files to Modify

1. **新增** `Sources/VoiceInputMimo/InputDeviceManager.swift`
   - `listInputDevices() -> [InputDevice]` — Core Audio HAL 列舉
   - `defaultInputDevice() -> InputDevice?`
   - `setDefaultInputDevice(_ device: InputDevice) throws`
   - `peekRMS(device: InputDevice, durationMs: Int) async throws -> Float` — 短測錄音算 RMS

2. **新增** `Tests/VoiceInputMimoTests/InputDeviceManagerTests.swift`
   - 列舉至少回一個 device（test host built-in mic）
   - default device 不為 nil
   - peekRMS 對 built-in mic > 0（環境噪音）

3. **修改** `Sources/VoiceInputMimo/AppDelegate.swift`
   - Line ~625 之後加 Microphone submenu 建構
   - `setupMicrophoneSubmenu()` helper
   - 監聽 Core Audio property listener (`kAudioHardwarePropertyDefaultInputDevice`) → submenu 自動 refresh
   - `applicationDidFinishLaunching` 結尾加 `Task { await checkPhantomOnLaunch() }`

4. **修改** `Sources/VoiceInputMimo/AudioRecorder.swift`
   - 沒實質改動（AVAudioRecorder 已用 system default）
   - 但加 callback `onPostRecord: (Float /* rms */) -> Void` 讓 UI 端可顯示「上次錄音 RMS = 0.012」

---

## Core Audio HAL API 速查

```swift
// 列舉 input devices
AudioObjectGetPropertyData(
    kAudioObjectSystemObject,
    kAudioHardwarePropertyDevices, ...
)

// Default input
kAudioHardwarePropertyDefaultInputDevice

// Set default input
AudioObjectSetPropertyData(
    kAudioObjectSystemObject,
    kAudioHardwarePropertyDefaultInputDevice, ...
)

// Listen device change
AudioObjectAddPropertyListener(
    kAudioObjectSystemObject,
    kAudioHardwarePropertyDefaultInputDevice, ...
)

// Device 名稱
kAudioDevicePropertyDeviceNameCFString
// Transport
kAudioDevicePropertyTransportType
// Input channels
kAudioDevicePropertyStreamConfiguration (scope: input)
```

---

## Test Plan

1. Unit: `InputDeviceManagerTests` — 列舉、default、setDefault、peekRMS 四個方法
2. Manual:
   - 啟動 app → 看 menu bar 是否新增 🎙 Microphone submenu
   - Submenu Current 行 = 目前 default device 名稱
   - 切換 device → 系統設定 → 聲音 → 輸入 看是否同步切換
   - 手動 `SwitchAudioSource -s 外接麥克風 -t input` → submenu 自動 refresh（property listener）
   - 重啟 app while default = 外接麥克風 → 跳 phantom alert
3. Regression: 既有錄音流程不變（AudioRecorder 不動 capture path）

---

## Build Order

1. InputDeviceManager.swift + 單元測試（純 HAL，無 UI）
2. Menu submenu wiring（AppDelegate）— 用 manual test 確認 UI
3. Phantom detection + alert — 製造 phantom 場景驗證
4. AudioRecorder callback（最小改動）
5. CHANGELOG + KB report 收尾

---

## Out of Scope

- Live RMS bar in menu submenu（stretch，下次）
- Audio output device 顯示/切換（symmetric feature 但今天不需要）
- 多 input device 同時錄（aggregate device）
