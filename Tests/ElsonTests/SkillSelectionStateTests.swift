import XCTest
@testable import Elson

@MainActor
final class SkillSelectionStateTests: XCTestCase {
    func testActiveSkillsUsesAllSkillsInAllScope() {
        let settings = AppSettings()
        settings.applySkillCatalogSnapshot(skills: [
            RegisteredSkill(
                id: "a",
                name: "copywriting",
                description: "Copy help",
                skillFilePath: "/tmp/a",
                skillDirectoryPath: "/tmp",
                sourceFamily: .agents
            ),
            RegisteredSkill(
                id: "b",
                name: "seo-audit",
                description: "SEO help",
                skillFilePath: "/tmp/b",
                skillDirectoryPath: "/tmp",
                sourceFamily: .codex
            ),
        ], lastScanAt: nil, lastError: nil)
        settings.skillSelectionScope = .all
        settings.selectedSkillIDs = ["a"]

        XCTAssertEqual(settings.activeSkills.map(\.id), ["a", "b"])
        XCTAssertEqual(settings.selectedSkillsCount, 2)
    }

    func testActiveSkillsUsesOnlySelectedSkillsInWhitelistScope() {
        let settings = AppSettings()
        settings.applySkillCatalogSnapshot(skills: [
            RegisteredSkill(
                id: "a",
                name: "copywriting",
                description: "Copy help",
                skillFilePath: "/tmp/a",
                skillDirectoryPath: "/tmp",
                sourceFamily: .agents
            ),
            RegisteredSkill(
                id: "b",
                name: "seo-audit",
                description: "SEO help",
                skillFilePath: "/tmp/b",
                skillDirectoryPath: "/tmp",
                sourceFamily: .codex
            ),
        ], lastScanAt: nil, lastError: nil)
        settings.skillSelectionScope = .selectedOnly
        settings.selectedSkillIDs = ["b"]

        XCTAssertEqual(settings.activeSkills.map(\.id), ["b"])
        XCTAssertEqual(settings.selectedSkillsCount, 1)
    }

    func testFilteredSkillsMatchesNameDescriptionAndSource() {
        let settings = AppSettings()
        settings.applySkillCatalogSnapshot(skills: [
            RegisteredSkill(
                id: "a",
                name: "copywriting",
                description: "Improve landing page copy",
                skillFilePath: "/tmp/a",
                skillDirectoryPath: "/tmp",
                sourceFamily: .agents
            ),
            RegisteredSkill(
                id: "b",
                name: "plan",
                description: "Strategic planning",
                skillFilePath: "/tmp/b",
                skillDirectoryPath: "/tmp",
                sourceFamily: .codex
            ),
        ], lastScanAt: nil, lastError: nil)

        XCTAssertEqual(settings.filteredSkills(searchQuery: "copy").map(\.id), ["a"])
        XCTAssertEqual(settings.filteredSkills(searchQuery: "strategic").map(\.id), ["b"])
        XCTAssertEqual(settings.filteredSkills(searchQuery: "codex").map(\.id), ["b"])
        XCTAssertEqual(settings.filteredSkills(searchQuery: "").map(\.id), ["a", "b"])
    }
}
