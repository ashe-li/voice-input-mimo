import Cocoa

final class KeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnPressed = false
    private var activeKeyCode: Int64?
    private var cachedShortcuts: [ShortcutBinding]?

    /// Drop the cached shortcut bindings. Call from Settings after the user
    /// changes a shortcut so the EventTap thread picks up the new binding on
    /// its next event.
    func invalidateShortcutCache() {
        cachedShortcuts = nil
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
