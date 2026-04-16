import Foundation

struct MyElsonDocument: Hashable {
    enum Section: CaseIterable {
        case identityAndProfile
        case preferences
        case words
        case notes
        case reminders
        case openLoops

        var title: String {
            switch self {
            case .identityAndProfile:
                return "Identity & Profile"
            case .preferences:
                return "Preferences"
            case .words:
                return "Words"
            case .notes:
                return "Notes"
            case .reminders:
                return "Reminders"
            case .openLoops:
                return "Open Loops"
            }
        }

        static func fromHeading(_ heading: String) -> Section? {
            let normalized = heading
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "##", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            switch normalized {
            case "identity & profile", "identity and profile":
                return .identityAndProfile
            case "preferences":
                return .preferences
            case "words":
                return .words
            case "notes":
                return .notes
            case "reminders":
                return .reminders
            case "open loops":
                return .openLoops
            default:
                return nil
            }
        }
    }

    private var entries: [Section: [String]]

    init(markdown: String) {
        entries = Dictionary(uniqueKeysWithValues: Section.allCases.map { ($0, []) })

        let lines = markdown.components(separatedBy: .newlines)
        var currentSection: Section?
        var fallbackNotes: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let section = Section.fromHeading(line) {
                currentSection = section
                continue
            }

            let cleaned = normalizeEntryLine(line)
            guard !cleaned.isEmpty else { continue }

            if let currentSection {
                entries[currentSection, default: []].append(cleaned)
            } else {
                fallbackNotes.append(cleaned)
            }
        }

        if !fallbackNotes.isEmpty {
            entries[.notes, default: []].append(contentsOf: fallbackNotes)
        }

        for section in Section.allCases {
            entries[section] = deduped(entries[section] ?? [])
        }
    }

    static func normalizedMarkdown(from markdown: String) -> String {
        MyElsonDocument(markdown: markdown).renderedMarkdown
    }

    static func wordsGlossaryMarkdown(from markdown: String) -> String {
        let entries = MyElsonDocument(markdown: markdown).entries(for: .words)
        guard !entries.isEmpty else { return "" }
        return "## Words\n" + entries.map { "- \($0)" }.joined(separator: "\n")
    }

    func entries(for section: Section) -> [String] {
        entries[section] ?? []
    }

    func merged(with patch: MyElsonPatch) -> MyElsonDocument {
        var copy = self
        copy.entries[.identityAndProfile] = mergedEntries(
            current: copy.entries[.identityAndProfile] ?? [],
            additions: patch.identityAndProfile,
            removals: patch.removeIdentityAndProfile,
            replacements: patch.replaceIdentityAndProfile
        )
        copy.entries[.preferences] = mergedEntries(
            current: copy.entries[.preferences] ?? [],
            additions: patch.preferences,
            removals: patch.removePreferences,
            replacements: patch.replacePreferences
        )
        copy.entries[.words] = mergedEntries(
            current: copy.entries[.words] ?? [],
            additions: patch.words,
            removals: patch.removeWords,
            replacements: patch.replaceWords
        )
        copy.entries[.notes] = mergedEntries(
            current: copy.entries[.notes] ?? [],
            additions: patch.notes,
            removals: patch.removeNotes,
            replacements: patch.replaceNotes
        )
        copy.entries[.reminders] = mergedEntries(
            current: copy.entries[.reminders] ?? [],
            additions: patch.reminders,
            removals: patch.removeReminders,
            replacements: patch.replaceReminders
        )
        copy.entries[.openLoops] = mergedEntries(
            current: copy.entries[.openLoops] ?? [],
            additions: patch.openLoops,
            removals: patch.removeOpenLoops,
            replacements: patch.replaceOpenLoops
        )

        return copy
    }

    var renderedMarkdown: String {
        Section.allCases.map { section in
            let body = (entries[section] ?? [])
                .map { "- \($0)" }
                .joined(separator: "\n")
            return body.isEmpty ? "## \(section.title)" : "## \(section.title)\n\(body)"
        }
        .joined(separator: "\n\n")
        + "\n"
    }

    private func normalizeEntryLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deduped(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []

        for value in values {
            let trimmed = normalizeEntryLine(value)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(trimmed)
        }

        return output
    }

    private func mergedEntries(
        current: [String],
        additions: [String],
        removals: [String],
        replacements: [MyElsonReplaceOperation]
    ) -> [String] {
        let normalizedCurrent = current.map(normalizeEntryLine)
        let replacementSources = Set(replacements.map { normalizeEntryLine($0.from).lowercased() }.filter { !$0.isEmpty })
        let removalKeys = Set(removals.map(normalizeEntryLine).map { $0.lowercased() }.filter { !$0.isEmpty })

        let retained = normalizedCurrent.filter { value in
            let key = normalizeEntryLine(value).lowercased()
            guard !key.isEmpty else { return false }
            return !replacementSources.contains(key) && !removalKeys.contains(key)
        }

        let replacementTargets = replacements.compactMap { operation -> String? in
            let from = normalizeEntryLine(operation.from)
            let to = normalizeEntryLine(operation.to)
            guard !from.isEmpty, !to.isEmpty else { return nil }
            return to
        }

        return deduped(retained + replacementTargets + additions.map(normalizeEntryLine))
    }
}
