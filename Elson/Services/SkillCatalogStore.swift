import Foundation

actor SkillCatalogStore {
    struct Snapshot: Sendable {
        let skills: [RegisteredSkill]
        let lastScanAt: Date?
        let lastError: String?
    }

    static let shared = SkillCatalogStore()

    private static let maxReferenceFileBytes = 128 * 1024
    private static let allowedReferenceExtensions: Set<String> = ["md", "txt", "json", "yaml", "yml"]
    private static let ignoredDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".next",
        ".swiftpm",
        "__pycache__",
        "build",
        "coverage",
        "dist",
        "node_modules",
        "tmp",
        "vendor",
    ]

    private let fileManager: FileManager
    private let homeURL: URL
    private var cachedSkills: [RegisteredSkill] = []
    private var lastScanAt: Date?
    private var lastError: String?

    init(
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeURL = homeURL
    }

    func snapshot() -> Snapshot {
        Snapshot(skills: cachedSkills, lastScanAt: lastScanAt, lastError: lastError)
    }

    @discardableResult
    func refresh(force: Bool = false) -> Snapshot {
        if !force, lastScanAt != nil {
            return snapshot()
        }

        do {
            let scannedSkills = try scanSkills()
            cachedSkills = scannedSkills.sorted { lhs, rhs in
                if lhs.sourceFamily != rhs.sourceFamily {
                    return lhs.sourceFamily.rawValue < rhs.sourceFamily.rawValue
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            lastScanAt = Date()
            lastError = nil
        } catch {
            lastScanAt = Date()
            lastError = error.localizedDescription
        }

        return snapshot()
    }

    func promptBundle(for skillID: String) -> SkillPromptBundle? {
        guard let skill = cachedSkills.first(where: { $0.id == skillID }) else { return nil }
        do {
            let skillURL = URL(fileURLWithPath: skill.skillFilePath)
            let skillBody = try String(contentsOf: skillURL, encoding: .utf8)
            let referenceFiles = try loadReferenceFiles(in: URL(fileURLWithPath: skill.skillDirectoryPath))
            return SkillPromptBundle(skill: skill, skillBody: skillBody, referenceFiles: referenceFiles)
        } catch {
            lastError = "Failed to load skill context for \(skill.name): \(error.localizedDescription)"
            return nil
        }
    }

    func selectSkill(for transcript: String, in skills: [RegisteredSkill]? = nil) -> SkillSelectionResult {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return .none }
        let candidateSkills = skills ?? cachedSkills
        guard !candidateSkills.isEmpty else { return .none }

        let normalizedTranscript = normalize(trimmedTranscript)
        let genericSkillCuePresent = containsGenericSkillCue(in: normalizedTranscript)
        let transcriptTokens = Set(tokenize(normalizedTranscript))

        let scoredSkills = candidateSkills.compactMap { skill -> (skill: RegisteredSkill, score: Int, explicit: Bool)? in
            let normalizedName = normalize(skill.name)
            let explicitPhrases = [
                "$\(normalizedName)",
                "use \(normalizedName)",
                "run \(normalizedName)",
                "with \(normalizedName)",
            ]
            let isExplicit = explicitPhrases.contains(where: normalizedTranscript.contains)
            let nameTokens = tokenize(normalizedName)
            let descriptionTokens = Set(tokenize(skill.description))

            var score = 0
            if isExplicit {
                score += 100
            }

            if !nameTokens.isEmpty {
                let matchingNameTokens = nameTokens.filter { transcriptTokens.contains($0) }.count
                if matchingNameTokens == nameTokens.count {
                    score += 40
                } else {
                    score += matchingNameTokens * 8
                }
            }

            let matchingDescriptionTokens = descriptionTokens.intersection(transcriptTokens).count
            score += min(24, matchingDescriptionTokens * 2)

            guard isExplicit || genericSkillCuePresent else { return nil }
            guard score > 0 else { return nil }
            return (skill, score, isExplicit)
        }
        .sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.skill.name.localizedCaseInsensitiveCompare($1.skill.name) == .orderedAscending
        }

        guard let top = scoredSkills.first else { return .none }

        if top.explicit {
            return .clearMatch(skill: top.skill)
        }

        if top.score >= 46,
           let second = scoredSkills.dropFirst().first {
            if top.score - second.score >= 12 {
                return .clearMatch(skill: top.skill)
            }
        }

        if top.score >= 58, scoredSkills.count == 1 {
            return .clearMatch(skill: top.skill)
        }

        if let second = scoredSkills.dropFirst().first,
           top.score >= 10,
           second.score >= 6,
           top.score - second.score <= 10 {
            return .ambiguous(candidates: Array(scoredSkills.prefix(3).map(\.skill)))
        }

        return .none
    }

    private func containsGenericSkillCue(in normalizedTranscript: String) -> Bool {
        let cueTokens: Set<String> = ["skill", "skills", "workflow", "workflows"]
        let tokens = Set(
            normalizedTranscript
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        )
        return !cueTokens.isDisjoint(with: tokens)
    }

    private func scanSkills() throws -> [RegisteredSkill] {
        let root = homeURL
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        var discoveredSkills: [RegisteredSkill] = []
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        )

        while let url = enumerator?.nextObject() as? URL {
            let lastComponent = url.lastPathComponent

            if shouldIgnore(url: url) {
                enumerator?.skipDescendants()
                continue
            }

            guard lastComponent == "SKILL.md" else { continue }
            guard let skill = try parseSkill(at: url) else { continue }
            discoveredSkills.append(skill)
        }

        return discoveredSkills
    }

    private func shouldIgnore(url: URL) -> Bool {
        let lastComponent = url.lastPathComponent
        if Self.ignoredDirectoryNames.contains(lastComponent) {
            return true
        }

        if lastComponent.hasPrefix("."),
           ![".agents", ".claude", ".codex", ".hermes"].contains(lastComponent) {
            return true
        }

        return false
    }

    private func parseSkill(at url: URL) throws -> RegisteredSkill? {
        let rawText = try String(contentsOf: url, encoding: .utf8)
        let frontmatter = parseFrontmatter(from: rawText)
        let fallbackName = url.deletingLastPathComponent().lastPathComponent
        let name = normalizedFrontmatterValue(frontmatter["name"]) ?? fallbackName
        let description = normalizedFrontmatterValue(frontmatter["description"]) ?? "No description."

        return RegisteredSkill(
            id: url.path,
            name: name,
            description: description,
            skillFilePath: url.path,
            skillDirectoryPath: url.deletingLastPathComponent().path,
            sourceFamily: classifySourceFamily(for: url)
        )
    }

    private func loadReferenceFiles(in skillDirectory: URL) throws -> [SkillPromptBundle.ReferenceFile] {
        let referencesDirectory = skillDirectory.appendingPathComponent("references", isDirectory: true)
        guard fileManager.fileExists(atPath: referencesDirectory.path) else { return [] }

        let enumerator = fileManager.enumerator(
            at: referencesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        )

        var references: [SkillPromptBundle.ReferenceFile] = []
        while let url = enumerator?.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            guard Self.allowedReferenceExtensions.contains(ext) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values?.fileSize, fileSize > Self.maxReferenceFileBytes {
                continue
            }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            references.append(
                SkillPromptBundle.ReferenceFile(
                    path: url.path,
                    contents: trimmed
                )
            )
        }

        return references.sorted { $0.path < $1.path }
    }

    private func parseFrontmatter(from text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---" else { return [:] }

        var frontmatter: [String: String] = [:]
        for line in lines.dropFirst() {
            if line == "---" {
                break
            }

            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            frontmatter[key] = value
        }

        return frontmatter
    }

    private func normalizedFrontmatterValue(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return value.isEmpty ? nil : value
    }

    private func classifySourceFamily(for url: URL) -> SkillSourceFamily {
        let path = url.path
        if path.contains("/.codex/") { return .codex }
        if path.contains("/.agents/") { return .agents }
        if path.contains("/.claude/") { return .claude }
        if path.contains("/.hermes/") { return .hermes }
        return .other
    }

    private func normalize(_ value: String) -> String {
        value
            .lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9$]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenize(_ value: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "bitte", "das", "de", "den", "der", "die", "ein", "eine",
            "for", "in", "make", "mit", "or", "plan", "please", "rewrite", "schreib",
            "schreibe", "text", "texte", "the", "this", "to", "um", "use", "with", "write"
        ]

        return value
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { token in
                token.count > 2 && !stopWords.contains(token)
            }
    }
}
