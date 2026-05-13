import XCTest
@testable import VoiceInputMimo

final class GlossaryImportExportAdapterTests: XCTestCase {

    // MARK: - Codec

    func testEncodeDecodeRoundTrip() throws {
        let entries = [
            GlossaryEntry(id: "a", spoken: "vocus", canonical: "vocus", context: "公司名"),
            GlossaryEntry(id: "b", spoken: "PDT", canonical: "PDT-9624", context: ""),
        ]
        let data = try GlossaryImportExportAdapter.encode(entries)
        let decoded = try GlossaryImportExportAdapter.decode(data)
        XCTAssertEqual(decoded.map(\.id), ["a", "b"])
        XCTAssertEqual(decoded.map(\.canonical), ["vocus", "PDT-9624"])
    }

    func testDecodeAcceptsTopLevelArrayFallback() throws {
        let arrayJSON = """
            [
              {
                "id": "x",
                "spoken": "foo",
                "canonical": "Foo",
                "context": "",
                "createdAt": "2026-05-14T00:00:00Z",
                "updatedAt": "2026-05-14T00:00:00Z"
              }
            ]
            """
        let data = Data(arrayJSON.utf8)
        let decoded = try GlossaryImportExportAdapter.decode(data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.canonical, "Foo")
    }

    func testDecodeMalformedThrowsImportError() {
        let data = Data("{ not json }".utf8)
        XCTAssertThrowsError(try GlossaryImportExportAdapter.decode(data)) { error in
            guard case GlossaryImportExportAdapter.ImportError.decodeFailed = error else {
                XCTFail("expected ImportError.decodeFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Merge

    func testMergeAddsToEmptyExisting() {
        let incoming = [GlossaryEntry(id: "a", spoken: "x", canonical: "X")]
        let merged = GlossaryImportExportAdapter.merge(existing: [], incoming: incoming)
        XCTAssertEqual(merged.entries.map(\.id), ["a"])
        XCTAssertEqual(merged.result.added, 1)
        XCTAssertEqual(merged.result.replaced, 0)
    }

    func testMergeReplacesSameId() {
        let existing = [GlossaryEntry(id: "a", spoken: "old", canonical: "OLD")]
        let incoming = [GlossaryEntry(id: "a", spoken: "new", canonical: "NEW")]
        let merged = GlossaryImportExportAdapter.merge(existing: existing, incoming: incoming)
        XCTAssertEqual(merged.entries.count, 1)
        XCTAssertEqual(merged.entries.first?.canonical, "NEW")
        XCTAssertEqual(merged.result.added, 0)
        XCTAssertEqual(merged.result.replaced, 1)
    }

    func testMergeMixedAddsAndReplaces() {
        let existing = [
            GlossaryEntry(id: "a", spoken: "a-old", canonical: "A-OLD"),
            GlossaryEntry(id: "b", spoken: "b", canonical: "B"),
        ]
        let incoming = [
            GlossaryEntry(id: "a", spoken: "a-new", canonical: "A-NEW"),
            GlossaryEntry(id: "c", spoken: "c", canonical: "C"),
        ]
        let merged = GlossaryImportExportAdapter.merge(existing: existing, incoming: incoming)
        XCTAssertEqual(merged.entries.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(merged.entries.first?.canonical, "A-NEW")
        XCTAssertEqual(merged.result.added, 1)
        XCTAssertEqual(merged.result.replaced, 1)
    }

    func testMergeEmptyIncomingIsNoop() {
        let existing = [GlossaryEntry(id: "a", spoken: "x", canonical: "X")]
        let merged = GlossaryImportExportAdapter.merge(existing: existing, incoming: [])
        XCTAssertEqual(merged.entries.map(\.id), ["a"])
        XCTAssertEqual(merged.result.added, 0)
        XCTAssertEqual(merged.result.replaced, 0)
    }
}
