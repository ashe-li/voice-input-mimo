import Cocoa

final class KeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnPressed = false

    /// Start monitoring. Returns false if accessibility permission is missing.
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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

        let flags = event.flags
        let fnDown = flags.contains(.maskSecondaryFn)
        // Diagnostic: log every flagsChanged event so we know the tap is firing
        NSLog("[KeyMonitor] flagsChanged: fnDown=%@ raw=0x%llx",
              fnDown ? "YES" : "no", flags.rawValue)

        if fnDown && !fnPressed {
            fnPressed = true
            DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
            return nil // suppress Fn press (prevents emoji picker)
        } else if !fnDown && fnPressed {
            fnPressed = false
            DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
            return nil // suppress Fn release
        }

        return Unmanaged.passUnretained(event)
    }
}
