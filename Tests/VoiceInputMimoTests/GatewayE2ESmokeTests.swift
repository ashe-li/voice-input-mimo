import XCTest
@testable import VoiceInputMimo

/// Cross-repo E2E smoke test: VIM as HTTP client → local-llm-backend gateway.
///
/// Prerequisites (each test XCTSkips when missing — never fails-loud on a
/// missing dev environment, so `swift test` stays green for unrelated work):
/// 1. Gateway running at GATEWAY_E2E_URL (default http://127.0.0.1:4000)
/// 2. Fixture short.wav at FIXTURE_DIR/audio/short.wav (default
///    ~/Documents/local-llm-backend/harness/fixtures/audio/short.wav)
/// 3. At least one ASR backend healthy (probed via /health)
///
/// To run explicitly:
///   cd ~/Documents/voice-input-mimo
///   GATEWAY_E2E_URL=http://127.0.0.1:4000 \
///     swift test --filter GatewayE2ESmokeTests
///
/// What these tests assert is intentionally minimal — they're not regression
/// gates (that's harness/e2e/run.ts on the gateway side). They verify the
/// VIM-side request shape (multipart boundary, SSE framing, JSON body) still
/// matches what the gateway accepts, providing an early drift warning when
/// either side's contract changes.
final class GatewayE2ESmokeTests: XCTestCase {

    private var gatewayURL: URL!
    private var fixtureDir: URL!

    override func setUpWithError() throws {
        let urlString = ProcessInfo.processInfo.environment["GATEWAY_E2E_URL"]
            ?? "http://127.0.0.1:4000"
        guard let url = URL(string: urlString) else {
            throw XCTSkip("invalid GATEWAY_E2E_URL: \(urlString)")
        }
        gatewayURL = url

        let fixtureDirPath = ProcessInfo.processInfo.environment["FIXTURE_DIR"]
            ?? NSString(string: "~/Documents/local-llm-backend/harness/fixtures").expandingTildeInPath
        fixtureDir = URL(fileURLWithPath: fixtureDirPath)

        // probeHealth runs inside each test instead of setUp because
        // setUpWithError is sync; async setUp would require XCTest's
        // setUp() async throws variant (macOS 13+ only). The per-test
        // overhead is one HTTP HEAD-ish call, negligible.
    }

    // MARK: - Tests

    func testASREndpointReturnsTranscript() async throws {
        try await probeHealth()
        let wav = fixtureDir.appendingPathComponent("audio/short.wav")
        try skipIfFixtureMissing(at: wav)

        let url = gatewayURL.appendingPathComponent("v1/audio/transcriptions")
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = try multipartBody(
            boundary: boundary,
            wavURL: wav,
            modelField: "mimo",
            modeField: "quick"
        )
        req.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        XCTAssertEqual(status, 200, "ASR should return 200; got \(status)")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = json?["text"] as? String
        XCTAssertNotNil(text, "response body must contain 'text' field")
        XCTAssertFalse((text ?? "").isEmpty, "transcribed text should be non-empty")
    }

    func testChatCompletionsRefineMode() async throws {
        try await runChatModeTest(mode: "quick")
    }

    func testChatCompletionsDefaultMode() async throws {
        try await runChatModeTest(mode: "default")
    }

    func testChatCompletionsBatchMode() async throws {
        try await runChatModeTest(mode: "batch")
    }

    // MARK: - Helpers

    /// Probe /health; XCTSkip the test when gateway is down or reports no
    /// backends ok. We deliberately use throw XCTSkip rather than XCTAssert
    /// so unrelated CI / dev environments don't see red.
    private func probeHealth() async throws {
        let url = gatewayURL.appendingPathComponent("health")
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                throw XCTSkip("gateway /health returned \(status) — is `bun run src/main.ts` running?")
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let backends = json?["backends"] as? [String: [String: Any]]
            let okCount = backends?.values.filter {
                ($0["status"] as? String) == "ok"
            }.count ?? 0
            guard okCount > 0 else {
                throw XCTSkip("no backend reports ok — start MiMo/Rapid-MLX before E2E tests")
            }
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip("gateway unreachable at \(gatewayURL.absoluteString): \(error.localizedDescription)")
        }
    }

    private func skipIfFixtureMissing(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture missing: \(url.path) — record via VIM «Export Fixtures» menu")
        }
    }

    private func runChatModeTest(mode: String) async throws {
        try await probeHealth()
        let url = gatewayURL.appendingPathComponent("v1/chat/completions")
        let body: [String: Any] = [
            "model": "qwen3-8b-mlx",
            "mode": mode,
            "stream": true,
            "messages": [["role": "user", "content": "Hello"]],
            "max_tokens": 32,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        XCTAssertEqual(status, 200, "chat (mode=\(mode)) should return 200; got \(status)")

        // Drain the SSE stream and verify at least one chunk contains "content"
        var sawContent = false
        for try await line in asyncBytes.lines {
            if line.contains("\"content\"") {
                sawContent = true
                break
            }
        }
        XCTAssertTrue(sawContent, "mode=\(mode) SSE stream must include at least one content chunk")
    }

    private func multipartBody(
        boundary: String,
        wavURL: URL,
        modelField: String,
        modeField: String
    ) throws -> Data {
        var body = Data()
        let crlf = "\r\n"
        let appendString: (String) -> Void = { s in body.append(s.data(using: .utf8) ?? Data()) }

        appendString("--\(boundary)\(crlf)")
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"short.wav\"\(crlf)")
        appendString("Content-Type: audio/wav\(crlf)\(crlf)")
        body.append(try Data(contentsOf: wavURL))
        appendString(crlf)

        appendString("--\(boundary)\(crlf)")
        appendString("Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)")
        appendString("\(modelField)\(crlf)")

        appendString("--\(boundary)\(crlf)")
        appendString("Content-Disposition: form-data; name=\"mode\"\(crlf)\(crlf)")
        appendString("\(modeField)\(crlf)")

        appendString("--\(boundary)--\(crlf)")
        return body
    }
}
