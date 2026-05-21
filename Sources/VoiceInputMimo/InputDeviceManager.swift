import AVFoundation
import CoreAudio
import Foundation
import os

/// Read/write the system default audio input device and observe device
/// changes via Core Audio HAL. Wraps verbose `AudioObjectGetPropertyData` /
/// `AudioObjectSetPropertyData` calls behind a small Swift surface.
///
/// Why HAL instead of `AVCaptureDevice`:
///   - AVCaptureDevice cannot *change* the system default — only enumerate.
///   - AVAudioEngine input is always bound to whatever HAL says is default;
///     to switch input source app-wide we must poke HAL directly.
///
/// Why peek-by-default only (no per-device peek):
///   - The phantom-device case we care about is always the system default
///     (a stale UID stuck in `kAudioHardwarePropertyDefaultInputDevice`).
///   - Peeking an arbitrary device would require temporarily switching
///     default, capturing, then restoring — visible to other apps and
///     racy. Not worth the API surface.
enum InputDeviceManager {

    // MARK: - Types

    struct InputDevice: Equatable, Hashable, Identifiable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transportType: UInt32

        var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }

        /// Human-readable label for the transport bus.
        /// Falls back to a hex code when Apple introduces new transports
        /// we haven't seen.
        var transportLabel: String {
            switch transportType {
            case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
            case kAudioDeviceTransportTypeUSB: return "USB"
            case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
            case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
            case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
            case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
            case kAudioDeviceTransportTypeHDMI: return "HDMI"
            case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
            case kAudioDeviceTransportTypeVirtual: return "Virtual"
            case kAudioDeviceTransportTypeAggregate: return "Aggregate"
            case kAudioDeviceTransportTypeAutoAggregate: return "AutoAggregate"
            case kAudioDeviceTransportTypeContinuityCaptureWired: return "Continuity (wired)"
            case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity (wireless)"
            case kAudioDeviceTransportTypeUnknown: return "Unknown"
            default: return String(format: "0x%08x", transportType)
            }
        }
    }

    enum HALError: Error, CustomStringConvertible {
        case enumerate(OSStatus)
        case readProperty(String, OSStatus)
        case writeDefault(OSStatus)
        case peek(String)

        var description: String {
            switch self {
            case .enumerate(let s): return "HAL enumerate failed (OSStatus \(s))"
            case .readProperty(let p, let s): return "HAL read \(p) failed (OSStatus \(s))"
            case .writeDefault(let s): return "HAL set default input failed (OSStatus \(s))"
            case .peek(let m): return "HAL peek failed: \(m)"
            }
        }
    }

    final class ListenerToken {
        fileprivate let block: AudioObjectPropertyListenerBlock
        fileprivate let address: AudioObjectPropertyAddress
        fileprivate init(block: @escaping AudioObjectPropertyListenerBlock,
                         address: AudioObjectPropertyAddress) {
            self.block = block
            self.address = address
        }
    }

    // MARK: - Listing

    static func listInputDevices() throws -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == noErr else { throw HALError.enumerate(status) }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        guard status == noErr else { throw HALError.enumerate(status) }

        return ids.compactMap { id -> InputDevice? in
            guard hasInputChannels(id) else { return nil }
            guard let uid = readString(id, kAudioDevicePropertyDeviceUID),
                  let name = readString(id, kAudioObjectPropertyName)
            else { return nil }
            let transport = readTransportType(id)
            return InputDevice(id: id, uid: uid, name: name, transportType: transport)
        }
    }

    // MARK: - Default input

    static func defaultInputDevice() throws -> InputDevice? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr else {
            throw HALError.readProperty("DefaultInputDevice", status)
        }
        guard id != 0 else { return nil }
        guard let uid = readString(id, kAudioDevicePropertyDeviceUID),
              let name = readString(id, kAudioObjectPropertyName) else { return nil }
        let transport = readTransportType(id)
        return InputDevice(id: id, uid: uid, name: name, transportType: transport)
    }

    static func setDefaultInputDevice(_ device: InputDevice) throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id)
        guard status == noErr else { throw HALError.writeDefault(status) }
    }

    // MARK: - Peek RMS (current default only)

    /// Capture a short window from the current default input and return
    /// its RMS in float32 amplitude space. Used at launch to detect a
    /// phantom default device (RMS ≈ 0 over a normal ambient-noise window).
    ///
    /// Returns 0 if no samples were captured (e.g. default device had no
    /// input bus) — caller treats that as "silent" the same as RMS < 1e-4.
    static func peekDefaultRMS(durationMs: Int = 250) async throws -> Float {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Float, Error>) in
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                cont.resume(throwing: HALError.peek("zero channels or sample rate"))
                return
            }

            // Accumulator state guarded by an unfair lock — async-safe
            // (NSLock is not). Float64 sum keeps precision over a quarter
            // second of 48 kHz mono.
            struct Accumulator { var sumSquares: Double = 0; var sampleCount: Int = 0 }
            let lock = OSAllocatedUnfairLock(initialState: Accumulator())

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                guard let chan = buffer.floatChannelData?[0] else { return }
                let frames = Int(buffer.frameLength)
                var running: Double = 0
                for i in 0..<frames {
                    let v = Double(chan[i])
                    running += v * v
                }
                // Bind to `let` so the Sendable closure captures an
                // immutable Double (Swift 6 rejects var capture).
                let localSum = running
                lock.withLock { acc in
                    acc.sumSquares += localSum
                    acc.sampleCount += frames
                }
            }

            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                cont.resume(throwing: HALError.peek("engine.start: \(error.localizedDescription)"))
                return
            }

            // Tap accumulates for `durationMs`, then we tear down and
            // resume with RMS. Using a detached Task keeps us off the
            // audio thread for the sleep.
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
                input.removeTap(onBus: 0)
                engine.stop()
                let snapshot = lock.withLock { ($0.sampleCount, $0.sumSquares) }
                let (n, s) = snapshot
                guard n > 0 else { cont.resume(returning: 0); return }
                let rms = Float((s / Double(n)).squareRoot())
                cont.resume(returning: rms)
            }
        }
    }

    // MARK: - Property listener

    static func observeDefaultInputChanges(_ handler: @escaping () -> Void) -> ListenerToken {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { handler() }
        }
        var local = address
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &local, DispatchQueue.main, block)
        return ListenerToken(block: block, address: address)
    }

    static func stopObserving(_ token: ListenerToken) {
        var addr = token.address
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, token.block)
    }

    // MARK: - Private helpers

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bufferList) == noErr else {
            return false
        }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func readString(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cf as String
    }

    private static func readTransportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else {
            return kAudioDeviceTransportTypeUnknown
        }
        return value
    }
}
