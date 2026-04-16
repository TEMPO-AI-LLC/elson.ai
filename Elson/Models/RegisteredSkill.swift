import Foundation

enum SkillSourceFamily: String, Codable, CaseIterable, Hashable, Sendable {
    case codex = "Codex"
    case agents = "Agents"
    case claude = "Claude"
    case hermes = "Hermes"
    case other = "Other"
}

enum SkillSelectionScope: String, Codable, CaseIterable, Hashable, Sendable {
    case all = "all"
    case selectedOnly = "selected_only"

    var title: String {
        switch self {
        case .all:
            return "All skills"
        case .selectedOnly:
            return "Selected skills only"
        }
    }
}

struct RegisteredSkill: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let skillFilePath: String
    let skillDirectoryPath: String
    let sourceFamily: SkillSourceFamily

    var displayPath: String { skillFilePath }
}

struct SkillPromptBundle: Hashable, Sendable {
    struct ReferenceFile: Hashable, Sendable {
        let path: String
        let contents: String
    }

    let skill: RegisteredSkill
    let skillBody: String
    let referenceFiles: [ReferenceFile]

    var renderedContext: String {
        var sections: [String] = [
            """
            selected_skill:
            name: \(skill.name)
            description: \(skill.description)
            source_family: \(skill.sourceFamily.rawValue)
            skill_file_path: \(skill.skillFilePath)

            selected_skill_markdown:
            \(skillBody)
            """
        ]

        if !referenceFiles.isEmpty {
            let renderedReferences = referenceFiles.map { reference in
                """
                reference_file: \(reference.path)
                \(reference.contents)
                """
            }.joined(separator: "\n\n")
            sections.append(
                """
                selected_skill_references:
                \(renderedReferences)
                """
            )
        }

        return sections.joined(separator: "\n\n")
    }
}

enum SkillSelectionResult: Hashable, Sendable {
    case none
    case clearMatch(skill: RegisteredSkill)
    case ambiguous(candidates: [RegisteredSkill])
}
