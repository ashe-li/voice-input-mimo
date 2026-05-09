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
