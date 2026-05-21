import XCTest
import CoreAudio
@testable import VoiceInputMimo

final class InputDeviceManagerTests: XCTestCase {

    func testListInputDevicesReturnsAtLeastOne() throws {
        let devices = try InputDeviceManager.listInputDevices()
        // Test hosts always have at least the built-in mic or an aggregate.
        // If this fails the CI runner genuinely has no audio devices — not a
        // bug in the manager, but worth surfacing.
        XCTAssertFalse(devices.isEmpty, "Expected at least one input device")
        // UIDs must be unique — Core Audio guarantees this; we sanity-check.
        let uids = devices.map(\.uid)
        XCTAssertEqual(uids.count, Set(uids).count, "Duplicate UIDs in listInputDevices()")
    }

    func testDefaultInputDeviceIsAmongListed() throws {
        guard let defaultDevice = try InputDeviceManager.defaultInputDevice() else {
            throw XCTSkip("No default input device on test host")
        }
        let listed = try InputDeviceManager.listInputDevices()
        XCTAssertTrue(
            listed.contains(where: { $0.uid == defaultDevice.uid }),
            "Default device UID \(defaultDevice.uid) not found in listInputDevices()"
        )
    }

    func testTransportLabelDecodesCommonValues() {
        let cases: [(UInt32, String)] = [
            (kAudioDeviceTransportTypeBuiltIn, "Built-in"),
            (kAudioDeviceTransportTypeUSB, "USB"),
            (kAudioDeviceTransportTypeBluetooth, "Bluetooth"),
            (kAudioDeviceTransportTypeAirPlay, "AirPlay"),
            (kAudioDeviceTransportTypeAggregate, "Aggregate"),
            (kAudioDeviceTransportTypeUnknown, "Unknown"),
        ]
        for (raw, expected) in cases {
            let dev = InputDeviceManager.InputDevice(
                id: 0, uid: "test", name: "test", transportType: raw)
            XCTAssertEqual(dev.transportLabel, expected,
                           "transportLabel mismatch for raw \(String(format: "0x%08x", raw))")
        }
    }

    func testTransportLabelFallsBackToHexForUnknownValues() {
        let dev = InputDeviceManager.InputDevice(
            id: 0, uid: "test", name: "test", transportType: 0xDEADBEEF)
        XCTAssertEqual(dev.transportLabel, "0xdeadbeef")
    }

    func testPeekDefaultRMSReturnsFiniteNonNegative() async throws {
        // 200ms peek — short enough to keep tests fast, long enough for
        // tap to deliver at least one buffer at 48kHz.
        let rms = try await InputDeviceManager.peekDefaultRMS(durationMs: 200)
        XCTAssertTrue(rms.isFinite, "RMS must be finite, got \(rms)")
        XCTAssertGreaterThanOrEqual(rms, 0, "RMS must be non-negative")
    }
}
