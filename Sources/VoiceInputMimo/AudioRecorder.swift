import AVFoundation
import Foundation

/// Captures microphone audio to a 16 kHz mono PCM WAV file.
/// Uses AVAudioRecorder (high-level) so file I/O stays off the real-time audio thread.
final class AudioRecorder {
    var onAudioLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var currentURL: URL?

    static func requestPermissions(completion: @escaping (Bool, String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted {
                    completion(true, nil)
                } else {
                    completion(false, "Microphone access denied.\nGrant in System Settings → Privacy & Security → Microphone.")
                }
            }
        }
    }

    func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-input-mimo-\(UUID().uuidString).wav")
        currentURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.prepareToRecord() else {
                onError?("AVAudioRecorder.prepareToRecord() returned false")
                cleanup()
                return
            }
            guard r.record() else {
                onError?("AVAudioRecorder.record() returned false (mic busy?)")
                cleanup()
                return
            }
            recorder = r
            startLevelTimer()
        } catch {
            onError?("AVAudioRecorder init failed: \(error.localizedDescription)")
            cleanup()
        }
    }

    @discardableResult
    func stopRecording() -> URL? {
        stopLevelTimer()
        recorder?.stop()
        recorder = nil
        let url = currentURL
        currentURL = nil
        return url
    }

    func cancel() {
        stopLevelTimer()
        recorder?.stop()
        recorder = nil
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentURL = nil
    }

    // MARK: - Level metering

    private func startLevelTimer() {
        stopLevelTimer()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder, r.isRecording else { return }
            r.updateMeters()
            // averagePower returns dBFS in [-160, 0]. Normalize to [0, 1].
            let dB = r.averagePower(forChannel: 0)
            let norm = max(Float(0), min(Float(1), (dB + 50) / 40))
            self.onAudioLevel?(norm)
        }
        RunLoop.main.add(t, forMode: .common)
        levelTimer = t
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func cleanup() {
        stopLevelTimer()
        recorder = nil
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        currentURL = nil
    }
}
