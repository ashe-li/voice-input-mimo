import XCTest
import AVFoundation
@testable import VoiceInputMimo

final class AudioRecorderRMSTests: XCTestCase {

    private func writeWav(samples: [Float], sampleRate: Double = 16000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rms-test-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let format = AVAudioFormat(settings: settings) else {
            throw XCTSkip("Cannot create AVAudioFormat for test wav")
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw XCTSkip("Cannot allocate PCM buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let chan = buffer.floatChannelData?[0] else {
            throw XCTSkip("PCM buffer has no float channel data")
        }
        for i in 0..<samples.count { chan[i] = samples[i] }
        try file.write(from: buffer)
        return url
    }

    func testComputeRMS_silentWavReturnsZero() throws {
        let samples = [Float](repeating: 0, count: 8000) // 0.5s @ 16kHz
        let url = try writeWav(samples: samples)
        defer { try? FileManager.default.removeItem(at: url) }
        let rms = AudioRecorder.computeRMS(at: url)
        XCTAssertEqual(rms, 0, accuracy: 1e-6)
    }

    func testComputeRMS_sineWavMatchesExpectedAmplitude() throws {
        // 440 Hz sine at amplitude 0.5 → RMS = 0.5 / sqrt(2) ≈ 0.3536
        let sr: Double = 16000
        let freq: Double = 440
        let amp: Float = 0.5
        let count = Int(sr) // 1 second
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = amp * Float(sin(2 * .pi * freq * Double(i) / sr))
        }
        let url = try writeWav(samples: samples)
        defer { try? FileManager.default.removeItem(at: url) }
        let rms = AudioRecorder.computeRMS(at: url)
        XCTAssertEqual(rms, amp / sqrtf(2), accuracy: 1e-3)
    }

    func testComputeRMS_nonexistentFileReturnsZero() {
        let url = URL(fileURLWithPath: "/tmp/voice-input-mimo-does-not-exist-\(UUID().uuidString).wav")
        XCTAssertEqual(AudioRecorder.computeRMS(at: url), 0)
    }
}
