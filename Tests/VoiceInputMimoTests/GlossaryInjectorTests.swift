import XCTest
@testable import VoiceInputMimo

final class GlossaryInjectorTests: XCTestCase {

    func testEmptyEntriesReturnsOriginalPrompt() {
        let base = "Refine the speech."
        let out = GlossaryInjector.inject(systemPrompt: base, entries: [])
        XCTAssertEqual(out, base)
    }

    func testEntriesWithBlankFieldsAreSkipped() {
        let base = "Refine."
        let entries = [
            GlossaryEntry(spoken: "", canonical: "x"),
            GlossaryEntry(spoken: "y", canonical: ""),
        ]
        XCTAssertEqual(GlossaryInjector.inject(systemPrompt: base, entries: entries), base)
    }

    func testSingleEntryAppendsSection() {
        let base = "Refine."
        let entry = GlossaryEntry(spoken: "vocus", canonical: "vocus", context: "公司名")
        let out = GlossaryInjector.inject(systemPrompt: base, entries: [entry])
        XCTAssertTrue(out.contains(GlossaryInjector.sectionHeader))
        XCTAssertTrue(out.contains("- vocus → vocus（公司名）"))
        XCTAssertTrue(out.hasPrefix("Refine."))
    }

    func testEntryWithoutContextOmitsParentheses() {
        let entry = GlossaryEntry(spoken: "PDT-9624", canonical: "PDT-9624", context: "")
        let line = GlossaryInjector.renderLine(entry)
        XCTAssertEqual(line, "- PDT-9624 → PDT-9624")
    }

    func testEntryWithWhitespaceContextOmitsParentheses() {
        let entry = GlossaryEntry(spoken: "a", canonical: "A", context: "   ")
        let line = GlossaryInjector.renderLine(entry)
        XCTAssertEqual(line, "- a → A")
    }

    func testMultipleEntriesAllListed() {
        let entries = [
            GlossaryEntry(spoken: "vocus", canonical: "vocus"),
            GlossaryEntry(spoken: "Lexical", canonical: "Lexical", context: "編輯器"),
            GlossaryEntry(spoken: "PDT", canonical: "PDT-9624"),
        ]
        let out = GlossaryInjector.inject(systemPrompt: "X", entries: entries)
        XCTAssertTrue(out.contains("- vocus → vocus"))
        XCTAssertTrue(out.contains("- Lexical → Lexical（編輯器）"))
        XCTAssertTrue(out.contains("- PDT → PDT-9624"))
    }

    func testTrailingWhitespaceInBasePromptIsTrimmed() {
        let base = "Refine.\n\n\n   "
        let out = GlossaryInjector.inject(
            systemPrompt: base,
            entries: [GlossaryEntry(spoken: "a", canonical: "b")]
        )
        // No more than one blank line between base and glossary block.
        XCTAssertFalse(out.contains("Refine.\n\n\n\n"))
        XCTAssertTrue(out.hasPrefix("Refine.\n\n##"))
    }
}
