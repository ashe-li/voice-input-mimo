import Foundation

struct ModelMemoryRow: Equatable {
    let name: String
    let state: String
    let primaryMB: Double?
    let detail: String
}

enum ModelMemoryParser {
    static func parseASR(_ json: [String: Any]) -> ModelMemoryRow {
        let memory = json["memory"] as? [String: Any] ?? [:]
        let asr = json["asr"] as? [String: Any] ?? [:]
        let loaded = (asr["loaded"] as? Bool) ?? false
        let phys = double(memory["phys_mb"])
        let rss = double(memory["rss_mb"])
        let active = double(memory["metal_active_mb"])
        let cache = double(memory["metal_cache_mb"])
        let pid = memory["pid"].map { "\($0)" } ?? "?"

        let detail = [
            "pid \(pid)",
            "rss \(formatMB(rss))",
            "mlx active \(formatMB(active))",
            "mlx cache \(formatMB(cache))",
        ].joined(separator: " · ")

        return ModelMemoryRow(
            name: "Speech model",
            state: loaded ? "loaded" : "idle / unloaded",
            primaryMB: phys,
            detail: detail
        )
    }

    static func parseEngineManagedTextModel(_ json: [String: Any]) -> ModelMemoryRow? {
        guard let qwen = json["qwen"] as? [String: Any],
              (qwen["enabled"] as? Bool) != false
        else { return nil }

        let observed = qwen["last_observed"] as? [String: Any] ?? [:]
        let cache = double(observed["cache_mb"])
        let reachable = (qwen["reachable"] as? Bool) ?? false
        let base = (qwen["base_url"] as? String) ?? "unknown"
        let requests = observed["total_requests"].map { "\($0)" } ?? "?"
        let detail = "\(base) · requests \(requests)"

        return ModelMemoryRow(
            name: "Text model cache",
            state: reachable ? "reachable" : "unreachable",
            primaryMB: cache,
            detail: detail
        )
    }

    static func parseLLMStatus(_ json: [String: Any], baseURL: String) -> ModelMemoryRow {
        let cache = json["cache"] as? [String: Any] ?? [:]
        let cacheMB = double(cache["current_memory_mb"])
        let requests = json["total_requests_processed"].map { "\($0)" } ?? "?"
        let detail = "\(baseURL) · requests \(requests)"
        return ModelMemoryRow(
            name: "Text model",
            state: "reachable",
            primaryMB: cacheMB,
            detail: detail
        )
    }

    static func formatMB(_ value: Double?) -> String {
        guard let value else { return "-" }
        if value >= 1024 {
            return String(format: "%.2f GB", value / 1024)
        }
        return String(format: "%.0f MB", value)
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

final class ModelMemoryMonitor {
    static let shared = ModelMemoryMonitor()

    func refresh(completion: @escaping ([ModelMemoryRow]) -> Void) {
        ASRClient.shared.adminMemory { asrResult in
            var rows: [ModelMemoryRow] = []
            if case .success(let json) = asrResult {
                rows.append(ModelMemoryParser.parseASR(json))
                if let qwen = ModelMemoryParser.parseEngineManagedTextModel(json) {
                    rows.append(qwen)
                }
            } else {
                rows.append(ModelMemoryRow(
                    name: "Speech model",
                    state: "unreachable",
                    primaryMB: nil,
                    detail: ASRClient.shared.baseURL
                ))
            }

            self.fetchLLMStatus { row in
                if let row,
                   !rows.contains(where: { $0.detail.contains(row.detail.components(separatedBy: " · ").first ?? "") }) {
                    rows.append(row)
                } else if LLMRefiner.shared.isEnabled,
                          !rows.contains(where: { $0.name.hasPrefix("Text model") }) {
                    rows.append(ModelMemoryRow(
                        name: "Text model",
                        state: "status unavailable",
                        primaryMB: nil,
                        detail: LLMRefiner.shared.apiBaseURL
                    ))
                }
                completion(rows)
            }
        }
    }

    private func fetchLLMStatus(completion: @escaping (ModelMemoryRow?) -> Void) {
        let configured = LLMRefiner.shared.apiBaseURL
        guard LLMRefiner.shared.isEnabled,
              let statusURL = Self.statusURL(from: configured)
        else {
            completion(nil)
            return
        }

        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let row = ModelMemoryParser.parseLLMStatus(json, baseURL: configured)
            DispatchQueue.main.async { completion(row) }
        }.resume()
    }

    static func statusURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if trimmed.hasSuffix("/v1") {
            return URL(string: "\(trimmed)/status")
        }
        return URL(string: "\(trimmed)/v1/status")
    }
}
