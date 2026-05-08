import Foundation

/// Result of a transcribe call. requestId is propagated as `X-Request-Id` so
/// downstream LLM refiner / engine logs can grep the same id end-to-end.
struct TranscribeResult {
    let text: String
    let requestId: String
}

/// HTTP client for the local MiMo-V2.5-ASR FastAPI server (Whisper-compatible).
final class ASRClient {
    static let shared = ASRClient()

    var baseURL: String {
        get { UserDefaults.standard.string(forKey: "asrBaseURL") ?? "http://127.0.0.1:8766" }
        set { UserDefaults.standard.set(newValue, forKey: "asrBaseURL") }
    }

    /// "auto" | "zh" | "en"
    var language: String {
        get { UserDefaults.standard.string(forKey: "asrLanguage") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "asrLanguage") }
    }

    /// "zh-TW" (default) | "none"
    var outputLocale: String {
        get { UserDefaults.standard.string(forKey: "asrOutputLocale") ?? "zh-TW" }
        set { UserDefaults.standard.set(newValue, forKey: "asrOutputLocale") }
    }

    private var currentTask: URLSessionDataTask?

    func transcribe(wavURL: URL, completion: @escaping (Result<TranscribeResult, Error>) -> Void) {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/v1/audio/transcriptions") else {
            completion(.failure(ASRError.invalidURL))
            return
        }

        // request_id derived from wav filename (already contains timestamp +
        // UUID from RecordingArchive) so the same id appears in:
        //   - voice-input app NSLog
        //   - engine.log / transcribe.jsonl
        //   - LLM refiner log
        let requestId = wavURL.deletingPathExtension().lastPathComponent

        let boundary = "----VoiceInputMimo-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")

        guard let audioData = try? Data(contentsOf: wavURL) else {
            completion(.failure(ASRError.fileReadFailed))
            return
        }

        var body = Data()
        let crlf = "\r\n"

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(value)\(crlf)".data(using: .utf8)!)
        }

        // file
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(wavURL.lastPathComponent)\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(audioData)
        body.append(crlf.data(using: .utf8)!)

        // form fields
        appendField("language", language)
        appendField("output_locale", outputLocale)

        // close
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        request.httpBody = body

        currentTask = URLSession.shared.dataTask(with: request) { data, response, error in
            // Archive wav to retention dir (LRU: keep last N files OR <= M MB)
            RecordingArchive.archive(wavURL, audioBytes: audioData.count)
            try? FileManager.default.removeItem(at: wavURL)

            if let data, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String {
                    let raw = json["raw_text"] as? String ?? "(same)"
                    NSLog("[ASRClient] [req=%@] ASR result: text='%@' raw='%@'", requestId, text, raw)
                }
            }

            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(ASRError.invalidResponse)) }
                return
            }
            guard (200...299).contains(http.statusCode), let data else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async {
                    completion(.failure(ASRError.httpError(http.statusCode, body)))
                }
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String
            else {
                DispatchQueue.main.async { completion(.failure(ASRError.invalidResponse)) }
                return
            }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                completion(.success(TranscribeResult(text: cleaned, requestId: requestId)))
            }
        }
        currentTask?.resume()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// GET /v1/health → JSON dict (or error).
    func health(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        getJSON(path: "/v1/health", completion: completion)
    }

    /// GET /admin/memory → JSON dict（含 asr.idle.level / current_window / time_since_use_s）.
    /// Uses cached snapshot — Phase 2 engine returns instantly without vmmap subprocess tax.
    func adminMemory(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        getJSON(path: "/admin/memory", completion: completion)
    }

    private func getJSON(path: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)\(path)") else {
            completion(.failure(ASRError.invalidURL)); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }; return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                DispatchQueue.main.async { completion(.failure(ASRError.invalidResponse)) }; return
            }
            DispatchQueue.main.async { completion(.success(json)) }
        }.resume()
    }

    /// Smoke transcribe — POST a synthetic 1-second silence WAV, measure end-to-end
    /// latency. Triggers cold load if model evicted; useful as a real "is the pipeline
    /// actually fast" probe rather than just /v1/health which may be misleadingly fast.
    func smokeTranscribe(completion: @escaping (Result<(elapsedMs: Int, text: String, wasCold: Bool, jsonText: String), Error>) -> Void) {
        let wavData = Self.generateSilenceWav()
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("asr-smoke-\(UUID().uuidString).wav")
        do {
            try wavData.write(to: tempURL)
        } catch {
            completion(.failure(error)); return
        }
        let startedAt = Date()
        // Need to know cold/warm BEFORE transcribe — read /admin/memory first.
        adminMemory { [weak self] memResult in
            let preLoaded: Bool = {
                if case .success(let mem) = memResult {
                    return ((mem["asr"] as? [String: Any])?["loaded"] as? Bool) ?? false
                }
                return false
            }()
            self?.transcribe(wavURL: tempURL) { result in
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                try? FileManager.default.removeItem(at: tempURL)
                switch result {
                case .success(let r):
                    completion(.success((elapsedMs: elapsed, text: r.text, wasCold: !preLoaded, jsonText: r.text)))
                case .failure(let e):
                    completion(.failure(e))
                }
            }
        }
    }

    /// Build minimal 16 kHz mono PCM 16-bit WAV of `durationSec` of silence (zeros).
    /// Used by smokeTranscribe — engine is fine with silence input (returns empty text
    /// or filler), latency measurement is the goal.
    private static func generateSilenceWav(durationSec: Double = 1.0, sampleRate: Int = 16000) -> Data {
        let numSamples = Int(durationSec * Double(sampleRate))
        let dataSize = numSamples * 2   // 16-bit mono = 2 bytes/sample
        let totalSize = 36 + dataSize   // header (44 - 8) + audio data
        var data = Data()
        func u32le(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16le(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append("RIFF".data(using: .ascii)!)
        u32le(UInt32(totalSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        u32le(16)                         // fmt chunk size
        u16le(1)                          // PCM
        u16le(1)                          // mono
        u32le(UInt32(sampleRate))
        u32le(UInt32(sampleRate * 2))     // byte rate (sampleRate × bytesPerSample × channels)
        u16le(2)                          // block align
        u16le(16)                         // bits per sample
        data.append("data".data(using: .ascii)!)
        u32le(UInt32(dataSize))
        data.append(Data(count: dataSize))   // silence (zeros)
        return data
    }

    enum ASRError: LocalizedError {
        case invalidURL
        case invalidResponse
        case fileReadFailed
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid ASR base URL"
            case .invalidResponse: return "Invalid response from ASR server"
            case .fileReadFailed: return "Failed to read recorded WAV"
            case .httpError(let code, let body):
                return "ASR HTTP \(code): \(body.prefix(200))"
            }
        }
    }
}
