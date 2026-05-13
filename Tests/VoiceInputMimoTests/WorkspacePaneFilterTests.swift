import XCTest
@testable import VoiceInputMimo

final class WorkspacePaneFilterTests: XCTestCase {

    private struct Sample: Identifiable, Equatable {
        let id: String
        let label: String
    }

    private let items: [Sample] = [
        .init(id: "1", label: "vocus"),
        .init(id: "2", label: "Lexical"),
        .init(id: "3", label: "PDT-9624"),
    ]

    private let matchByLabel: (Sample, String) -> Bool = { item, query in
        item.label.localizedCaseInsensitiveContains(query)
    }

    func testEmptyQueryReturnsAll() {
        let result = WorkspacePaneFilter.apply(items: items, query: "", match: matchByLabel)
        XCTAssertEqual(result, items)
    }

    func testWhitespaceQueryReturnsAll() {
        let result = WorkspacePaneFilter.apply(items: items, query: "   ", match: matchByLabel)
        XCTAssertEqual(result, items)
    }

    func testQueryFiltersByMatch() {
        let result = WorkspacePaneFilter.apply(items: items, query: "lex", match: matchByLabel)
        XCTAssertEqual(result, [Sample(id: "2", label: "Lexical")])
    }

    func testQueryWithNoMatchesReturnsEmpty() {
        let result = WorkspacePaneFilter.apply(items: items, query: "zzz", match: matchByLabel)
        XCTAssertTrue(result.isEmpty)
    }

    func testNilMatchReturnsAllRegardlessOfQuery() {
        let result = WorkspacePaneFilter.apply(items: items, query: "vocus", match: nil)
        XCTAssertEqual(result, items)
    }

    func testQueryIsTrimmedBeforeMatching() {
        let result = WorkspacePaneFilter.apply(items: items, query: "  PDT  ", match: matchByLabel)
        XCTAssertEqual(result, [Sample(id: "3", label: "PDT-9624")])
    }
}
