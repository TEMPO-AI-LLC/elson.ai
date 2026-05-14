import Foundation
import XCTest
@testable import Elson

final class SkillCatalogStoreTests: XCTestCase {
    private var tempHomeURL: URL!

    override func setUpWithError() throws {
        tempHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHomeURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHomeURL, FileManager.default.fileExists(atPath: tempHomeURL.path) {
            try FileManager.default.removeItem(at: tempHomeURL)
        }
    }

    func testRefreshDiscoversSkillsAndIgnoresNodeModules() async throws {
        try writeSkill(
            relativePath: ".agents/skills/copywriting/SKILL.md",
            contents: """
            ---
            name: copywriting
            description: Rewrite or improve copy.
            ---
            # Copywriting
            """
        )
        try writeSkill(
            relativePath: ".codex/skills/plan/SKILL.md",
            contents: """
            ---
            name: plan
            description: Strategic planning.
            ---
            # Plan
            """
        )
        try writeSkill(
            relativePath: "node_modules/fake-package/SKILL.md",
            contents: """
            ---
            name: should-not-appear
            description: ignored
            ---
            """
        )

        let store = SkillCatalogStore(homeURL: tempHomeURL)
        let snapshot = await store.refresh(force: true)

        XCTAssertEqual(snapshot.skills.count, 2)
        XCTAssertEqual(snapshot.skills.map(\.name).sorted(), ["copywriting", "plan"])
        XCTAssertEqual(snapshot.skills.first(where: { $0.name == "copywriting" })?.sourceFamily, .agents)
        XCTAssertEqual(snapshot.skills.first(where: { $0.name == "plan" })?.sourceFamily, .codex)
    }

    func testPromptBundleLoadsReferences() async throws {
        try writeSkill(
            relativePath: ".agents/skills/copywriting/SKILL.md",
            contents: """
            ---
            name: copywriting
            description: Rewrite or improve copy.
            ---
            # Copywriting
            Use this when writing or rewriting persuasive text.
            """
        )
        try writeFile(
            relativePath: ".agents/skills/copywriting/references/checklist.md",
            contents: "Check headline, CTA, and clarity."
        )

        let store = SkillCatalogStore(homeURL: tempHomeURL)
        _ = await store.refresh(force: true)
        let snapshot = await store.snapshot()
        let skill = try XCTUnwrap(snapshot.skills.first)
        let bundle = await store.promptBundle(for: skill.id)

        XCTAssertEqual(bundle?.skill.name, "copywriting")
        XCTAssertTrue(bundle?.renderedContext.contains("selected_skill_markdown") == true)
        XCTAssertTrue(bundle?.renderedContext.contains("Check headline, CTA, and clarity.") == true)
    }

    func testSelectSkillReturnsClearMatchForExplicitInvocation() async throws {
        try writeSkill(
            relativePath: ".agents/skills/copywriting/SKILL.md",
            contents: """
            ---
            name: copywriting
            description: Rewrite or improve copy.
            ---
            """
        )

        let store = SkillCatalogStore(homeURL: tempHomeURL)
        _ = await store.refresh(force: true)

        let result = await store.selectSkill(for: "Please use copywriting for this landing page.")
        guard case .clearMatch(let skill) = result else {
            return XCTFail("Expected a clear skill match.")
        }
        XCTAssertEqual(skill.name, "copywriting")
    }

    func testSelectSkillReturnsAmbiguousWhenTwoSkillsAreClose() async throws {
        try writeSkill(
            relativePath: ".agents/skills/friendly-email/SKILL.md",
            contents: """
            ---
            name: friendly-email
            description: Rewrite friendly email wording and improve tone.
            ---
            """
        )
        try writeSkill(
            relativePath: ".agents/skills/email-tone/SKILL.md",
            contents: """
            ---
            name: email-tone
            description: Rewrite email tone and improve friendly wording.
            ---
            """
        )

        let store = SkillCatalogStore(homeURL: tempHomeURL)
        _ = await store.refresh(force: true)

        let result = await store.selectSkill(for: "Which skill should I use for friendly email tone and wording?")
        guard case .ambiguous(let candidates) = result else {
            return XCTFail("Expected ambiguous skill candidates.")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    func testSelectSkillReturnsNoneForVisibleReplyRequestThatMentionsSkillLikeNouns() async throws {
        try writeSkill(
            relativePath: ".agents/skills/powerpoint/SKILL.md",
            contents: """
            ---
            name: powerpoint
            description: Prepare or rewrite powerpoint content.
            ---
            """
        )
        try writeSkill(
            relativePath: ".agents/skills/github-code-review/SKILL.md",
            contents: """
            ---
            name: github-code-review
            description: Review GitHub pull requests and code comments.
            ---
            """
        )

        let store = SkillCatalogStore(homeURL: tempHomeURL)
        _ = await store.refresh(force: true)

        let result = await store.selectSkill(
            for: "Answer that we can do it and I will finish the PowerPoint in the next two weeks and check the Miro board."
        )
        guard case .none = result else {
            return XCTFail("Expected no skill match for a visible reply request.")
        }
    }

    func testSelectSkillReturnsNoneForUnrelatedTranscript() async throws {
        try writeSkill(
            relativePath: ".agents/skills/copywriting/SKILL.md",
            contents: """
            ---
            name: copywriting
            description: Rewrite or improve copy.
            ---
            """
        )

        let store = SkillCatalogStore(homeURL: tempHomeURL)
        _ = await store.refresh(force: true)

        let result = await store.selectSkill(for: "Turn on the kitchen lights.")
        guard case .none = result else {
            return XCTFail("Expected no skill match.")
        }
    }

    private func writeSkill(relativePath: String, contents: String) throws {
        try writeFile(relativePath: relativePath, contents: contents)
    }

    private func writeFile(relativePath: String, contents: String) throws {
        let url = tempHomeURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
