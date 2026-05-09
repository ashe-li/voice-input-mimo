import XCTest
@testable import VoiceInputMimo

final class PromptComposerTests: XCTestCase {

    private func makeProfile(
        basePrompt: String = "/no_think You clean up text.",
        skillIDs: [String] = []
    ) -> PromptProfile {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        return PromptProfile(
            id: "p",
            name: "P",
            mode: .refine,
            basePrompt: basePrompt,
            skillIDs: skillIDs,
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeSkill(id: String, content: String) -> PromptSkill {
        PromptSkill(id: id, name: id, category: .style, content: content)
    }

    // MARK: - render

    func testRenderWithNoSkillsReturnsBasePromptUnchanged() {
        let profile = makeProfile(basePrompt: "BASE")
        XCTAssertEqual(PromptComposer.render(profile: profile, skills: []), "BASE")
    }

    func testRenderAppendsSingleSkillWithDoubleNewline() {
        let profile = makeProfile(basePrompt: "BASE", skillIDs: ["s1"])
        let skill = makeSkill(id: "s1", content: "RULE")
        XCTAssertEqual(
            PromptComposer.render(profile: profile, skills: [skill]),
            "BASE\n\nRULE"
        )
    }

    func testRenderPreservesSkillOrderFromProfileSkillIDs() {
        let profile = makeProfile(basePrompt: "BASE", skillIDs: ["s2", "s1", "s3"])
        let skills = [
            makeSkill(id: "s1", content: "ONE"),
            makeSkill(id: "s2", content: "TWO"),
            makeSkill(id: "s3", content: "THREE"),
        ]
        XCTAssertEqual(
            PromptComposer.render(profile: profile, skills: skills),
            "BASE\n\nTWO\n\nONE\n\nTHREE"
        )
    }

    func testRenderSkipsMissingSkillIDsSilently() {
        let profile = makeProfile(basePrompt: "BASE", skillIDs: ["s1", "ghost", "s2"])
        let skills = [
            makeSkill(id: "s1", content: "A"),
            makeSkill(id: "s2", content: "B"),
        ]
        XCTAssertEqual(
            PromptComposer.render(profile: profile, skills: skills),
            "BASE\n\nA\n\nB"
        )
    }

    func testRenderSkipsSkillsWithBlankContent() {
        let profile = makeProfile(basePrompt: "BASE", skillIDs: ["s1", "s2", "s3"])
        let skills = [
            makeSkill(id: "s1", content: "A"),
            makeSkill(id: "s2", content: "   "),
            makeSkill(id: "s3", content: "B"),
        ]
        XCTAssertEqual(
            PromptComposer.render(profile: profile, skills: skills),
            "BASE\n\nA\n\nB"
        )
    }

    func testRenderTrimsTrailingWhitespaceOnBasePrompt() {
        let profile = makeProfile(basePrompt: "BASE\n\n", skillIDs: ["s1"])
        let skill = makeSkill(id: "s1", content: "RULE")
        XCTAssertEqual(
            PromptComposer.render(profile: profile, skills: [skill]),
            "BASE\n\nRULE"
        )
    }

    func testRenderTrimsTrailingWhitespaceOnSkillContent() {
        let profile = makeProfile(basePrompt: "BASE", skillIDs: ["s1", "s2"])
        let skills = [
            makeSkill(id: "s1", content: "ONE\n"),
            makeSkill(id: "s2", content: "TWO\n\n"),
        ]
        XCTAssertEqual(
            PromptComposer.render(profile: profile, skills: skills),
            "BASE\n\nONE\n\nTWO"
        )
    }

    func testRenderHandlesAllMissingSkillsAsEmptyAppend() {
        let profile = makeProfile(basePrompt: "BASE", skillIDs: ["ghost1", "ghost2"])
        XCTAssertEqual(PromptComposer.render(profile: profile, skills: []), "BASE")
    }

    func testRenderEmptyBasePromptStillJoinsSkills() {
        let profile = makeProfile(basePrompt: "", skillIDs: ["s1", "s2"])
        let skills = [
            makeSkill(id: "s1", content: "A"),
            makeSkill(id: "s2", content: "B"),
        ]
        XCTAssertEqual(
            PromptComposer.render(profile: profile, skills: skills),
            "A\n\nB"
        )
    }

    // MARK: - token estimation

    func testEstimateTokenCountEmpty() {
        XCTAssertEqual(PromptComposer.estimateTokenCount(""), 0)
    }

    func testEstimateTokenCountUsesCharsDividedByFour() {
        // 16 chars -> ~4 tokens
        XCTAssertEqual(PromptComposer.estimateTokenCount("0123456789abcdef"), 4)
    }

    func testEstimateTokenCountRoundsUp() {
        // 5 chars -> ceil(5/4) = 2 tokens
        XCTAssertEqual(PromptComposer.estimateTokenCount("abcde"), 2)
    }

    func testEstimateTokenCountForRenderedProfile() {
        let profile = makeProfile(basePrompt: "abcd", skillIDs: ["s1"])  // 4 chars
        let skill = makeSkill(id: "s1", content: "abcd")  // 4 chars + 2 newline = 10 chars total
        let rendered = PromptComposer.render(profile: profile, skills: [skill])
        let estimate = PromptComposer.estimateTokenCount(rendered)
        XCTAssertEqual(rendered.count, 10)
        XCTAssertEqual(estimate, 3)  // ceil(10/4)
    }
}
