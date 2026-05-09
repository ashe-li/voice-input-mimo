import XCTest
@testable import VoiceInputMimo

final class ModelMemoryMonitorTests: XCTestCase {
    func testParseASRUsesProcessFootprintAndMLXDetails() {
        let row = ModelMemoryParser.parseASR([
            "memory": [
                "pid": 123,
                "phys_mb": NSNumber(value: 5836.0),
                "rss_mb": NSNumber(value: 512.0),
                "metal_active_mb": NSNumber(value: 2048.0),
                "metal_cache_mb": NSNumber(value: 256.0),
            ],
            "asr": ["loaded": true],
        ])

        XCTAssertEqual(row.name, "Speech model")
        XCTAssertEqual(row.state, "loaded")
        XCTAssertEqual(row.primaryMB, 5836.0)
        XCTAssertTrue(row.detail.contains("pid 123"))
        XCTAssertTrue(row.detail.contains("mlx active 2.00 GB"))
    }

    func testParseEngineManagedTextModelReadsOnlyEngineReportedCache() {
        let row = ModelMemoryParser.parseEngineManagedTextModel([
            "qwen": [
                "enabled": true,
                "reachable": true,
                "base_url": "http://127.0.0.1:8000",
                "last_observed": [
                    "cache_mb": 1420.0,
                    "total_requests": 9,
                ],
            ],
        ])

        XCTAssertEqual(row?.name, "Text model cache")
        XCTAssertEqual(row?.state, "reachable")
        XCTAssertEqual(row?.primaryMB, 1420.0)
        XCTAssertTrue(row?.detail.contains("http://127.0.0.1:8000") == true)
    }

    func testStatusURLNormalizesV1BaseURL() {
        XCTAssertEqual(
            ModelMemoryMonitor.statusURL(from: "http://localhost:1234/v1")?.absoluteString,
            "http://localhost:1234/v1/status"
        )
        XCTAssertEqual(
            ModelMemoryMonitor.statusURL(from: "http://localhost:1234")?.absoluteString,
            "http://localhost:1234/v1/status"
        )
    }
}
