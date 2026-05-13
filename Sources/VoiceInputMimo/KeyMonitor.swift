import Cocoa

final class KeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    /// Fired when the user presses Ctrl+Option+→. Cycles output mode forward
    /// (raw → refine → claudeCode → structure → raw).
    var onCycleNext: (() -> Void)?
    /// Fired when the user presses Ctrl+Option+←. Cycles output mode backward.
    var onCyclePrev: (() -> Void)?
    /// Fired when the user begins pressing Ctrl+Option+R. Hold-to-record
    /// "park" mode: ASR + archive + trace, but no paste / no LLM.
    var onParkDown: (() -> Void)?
    /// Fired when the user releases Ctrl+Option+R (any modifiers).
    var onParkUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnPressed = false
    private var activeKeyCode: Int64?
    private var parkActive = false
    private var cachedShortcuts: [ShortcutBinding]?
    private var cachedCycleEnabled: Bool?
    private var cachedParkEnabled: Bool?

    // Arrow keycodes on macOS.
    private static let leftArrowKeyCode: Int64 = 123
    private static let rightArrowKeyCode: Int64 = 124
    private static let rKeyCode: Int64 = 15

    /// Drop the cached shortcut bindings. Call from Settings after the user
    /// changes a shortcut so the EventTap thread picks up the new binding on
    /// its next event.
    func invalidateShortcutCache() {
        cachedShortcuts = nil
        cachedCycleEnabled = nil
        cachedParkEnabled = nil
    }

    /// Start monitoring. Returns false if accessibility permission is missing.
    func start() -> Bool {
        if eventTap != nil {
            return true
        }
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                // passUnretained: tap callback gets event with implicit ref;
                // pass-through must NOT add a second retain (would leak per event).
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        fnPressed = false
        activeKeyCode = nil
        parkActive = false
    }

    // MARK: - Private

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if the system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("[KeyMonitor] tap disabled by %@ — re-enabling",
                  type == .tapDisabledByTimeout ? "timeout" : "user input")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Cached shortcut snapshot. Re-loading from UserDefaults on every
        // CGEvent (incl. flagsChanged that fires per modifier-key event) was
        // pegging the EventTap thread enough to hit `tapDisabledByTimeout`
        // during fast typing — the system would suspend the tap mid-recording
        // and the Fn key-up event would be missed, leaving the app stuck in
        // "Listening" forever. The cache is invalidated externally via
        // `invalidateShortcutCache()` after a Settings save.
        let shortcuts = cachedShortcuts ?? {
            let s = ShortcutBinding.loadAll()
            cachedShortcuts = s
            return s
        }()

        if type == .flagsChanged, shortcuts.contains(where: { $0.preset == .function }) {
            let flags = event.flags
            let fnDown = flags.contains(.maskSecondaryFn)
            if fnDown && !fnPressed {
                fnPressed = true
                DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
                return nil
            } else if !fnDown && fnPressed {
                fnPressed = false
                DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
                return nil
            }
        }

        // Ctrl+Option+arrow cycles output mode. Intercept BEFORE the
        // recording-shortcut match so this combo is never misread as a
        // recording trigger. Guard `activeKeyCode == nil` suppresses cycling
        // while a recording is in progress. Gated by a UserDefaults toggle
        // so users can disable the cycle hotkey from Settings.
        let cycleEnabled = cachedCycleEnabled ?? {
            let v = ShortcutBinding.loadCycleHotkeyEnabled()
            cachedCycleEnabled = v
            return v
        }()
        if cycleEnabled, type == .keyDown, activeKeyCode == nil,
           event.flags.containsAll([.maskControl, .maskAlternate]) {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            if kc == Self.leftArrowKeyCode {
                DispatchQueue.main.async { [weak self] in self?.onCyclePrev?() }
                return nil
            }
            if kc == Self.rightArrowKeyCode {
                DispatchQueue.main.async { [weak self] in self?.onCycleNext?() }
                return nil
            }
        }

        // Ctrl+Option+R = park-mode hold-to-record. Hand off to the
        // dedicated callbacks; AppDelegate routes through the park
        // pipeline (no LLM, no paste). Gated by `parkHotkeyEnabled`.
        //
        // keyUp matches only on R-keycode without re-checking modifiers,
        // because the user may release Ctrl or Option first — relying on
        // flag presence at release time would strand `parkActive`.
        let parkEnabled = cachedParkEnabled ?? {
            let v = ShortcutBinding.loadParkHotkeyEnabled()
            cachedParkEnabled = v
            return v
        }()
        if parkEnabled, activeKeyCode == nil {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyDown, !parkActive, kc == Self.rKeyCode,
               event.flags.containsAll([.maskControl, .maskAlternate]) {
                parkActive = true
                DispatchQueue.main.async { [weak self] in self?.onParkDown?() }
                return nil
            }
            if type == .keyUp, parkActive, kc == Self.rKeyCode {
                parkActive = false
                DispatchQueue.main.async { [weak self] in self?.onParkUp?() }
                return nil
            }
        }

        if type == .keyDown, activeKeyCode == nil {
            if let shortcut = shortcuts.first(where: { $0.matchesKeyDown(event: event) }),
               let keyCode = shortcut.preset.keyCode {
                activeKeyCode = keyCode
                DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
                return nil
            }
        }

        if type == .keyUp, let keyCode = activeKeyCode {
            if event.getIntegerValueField(.keyboardEventKeycode) == keyCode {
                activeKeyCode = nil
                DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
