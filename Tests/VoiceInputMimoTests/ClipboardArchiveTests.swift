import XCTest
@testable import VoiceInputMimo

final class ClipboardArchiveTests: XCTestCase {
    func testParseLegacyClipboardEntriesDefaultsToClipboardKind() {
        let raw = """
        ─── 2026-05-08T05:43:22Z ───
        previous clipboard text

        """

        let entries = ClipboardArchive.parse(raw)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].timestamp, "2026-05-08T05:43:22Z")
        XCTAssertEqual(entries[0].kind, .clipboard)
        XCTAssertEqual(entries[0].content, "previous clipboard text")
    }

    func testParseSessionEntriesPreservesKindAndContent() {
        let raw = """
        ─── 2026-05-09T01:02:03Z | session ───
        Chinese (ASR)
        幫我把這個 API 改成 async

        English / Output
        Change this API to async.

        """

        let entries = ClipboardArchive.parse(raw)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].timestamp, "2026-05-09T01:02:03Z")
        XCTAssertEqual(entries[0].kind, .session)
        XCTAssertTrue(entries[0].content.contains("幫我把這個 API 改成 async"))
        XCTAssertTrue(entries[0].content.contains("Change this API to async."))
    }

    func testParseHeaderWithTracePopulatesTraceId() {
        let raw = """
        ─── 2026-05-14T10:00:00Z | session | trace=trace-abc12345 ───
        hello

        """
        let entries = ClipboardArchive.parse(raw)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .session)
        XCTAssertEqual(entries[0].traceId, "trace-abc12345")
        XCTAssertEqual(entries[0].content, "hello")
    }

    func testParseHeaderWithoutTraceKeepsTraceIdNil() {
        let raw = """
        ─── 2026-05-14T10:00:00Z | clipboard ───
        body

        """
        let entries = ClipboardArchive.parse(raw)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].traceId)
    }

    func testParseHeaderAcceptsTraceBeforeKind() {
        // Robustness: extension keys must be order-independent so old parsers
        // can read entries written by future versions in any order.
        let raw = """
        ─── 2026-05-14T10:00:00Z | trace=trace-xyz | session ───
        body

        """
        let entries = ClipboardArchive.parse(raw)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .session)
        XCTAssertEqual(entries[0].traceId, "trace-xyz")
    }

    func testParseEmptyTraceValueLeavesTraceIdNil() {
        let raw = """
        ─── 2026-05-14T10:00:00Z | clipboard | trace= ───
        body

        """
        let entries = ClipboardArchive.parse(raw)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].traceId)
    }

    func testParseLegacyMultipleEntriesWithMixedHeaders() {
        let raw = """
        ─── 2026-05-14T10:00:00Z | session | trace=trace-new ───
        new

        ─── 2026-05-13T10:00:00Z | clipboard ───
        mid

        ─── 2026-05-12T10:00:00Z ───
        old legacy

        """
        let entries = ClipboardArchive.parse(raw)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].traceId, "trace-new")
        XCTAssertNil(entries[1].traceId)
        XCTAssertNil(entries[2].traceId)
        XCTAssertEqual(entries[2].kind, .clipboard)
    }

    func testFormatSessionContentKeepsChineseAndEnglishSections() {
        let content = ClipboardArchive.formatSessionContent(
            zh: "  請修 clipboard 清單  ",
            english: "  Fix the clipboard list.  "
        )

        XCTAssertEqual(
            content,
            """
            Chinese (ASR)
            請修 clipboard 清單

            English / Output
            Fix the clipboard list.
            """
        )
    }
}
