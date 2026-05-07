import Foundation

/// HTTP client for the local MiMo-V2.5-ASR FastAPI server (Whisper-compatible).
final class ASRClient {
    static let shared = ASRClient()

    var baseURL: String {
        get { UserDefaults.standard.string(forKey: "asrBaseURL") ?? "http://127.0.0.1:8765" }
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

    func transcribe(wavURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/v1/audio/transcriptions") else {
            completion(.failure(ASRError.invalidURL))
            return
        }

        let boundary = "----VoiceInputMimo-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

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
                    NSLog("[ASRClient] ASR result: text='%@' raw='%@'", text, raw)
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
            DispatchQueue.main.async { completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        currentTask?.resume()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// GET /v1/health → JSON dict (or error).
    func health(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/v1/health") else {
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
