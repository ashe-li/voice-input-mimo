import AppKit

let app = NSApplication.shared
let isPreview = ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_PREVIEW"] == "1"
app.setActivationPolicy(isPreview ? .regular : .accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
