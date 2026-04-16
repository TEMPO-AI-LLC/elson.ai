import Foundation

enum ShortcutWakeWord {
    private static let standalonePattern = #"\belson\b"#
    private static let leadingPattern = #"^\s*elson(?:[\s,.:;!?-]+)?"#
    private static let trailingPattern = #"(?:[\s,.:;!?-]+)?elson\s*$"#

    static func containsStandaloneWakeWord(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(
            of: standalonePattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func strippingWakeWordForCommand(_ transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let withoutLeading = trimmed.replacingOccurrences(
            of: leadingPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let withoutLeadingOrTrailing = withoutLeading.replacingOccurrences(
            of: trailingPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        let collapsed = withoutLeadingOrTrailing.replacingOccurrences(
            of: #"\s{2,}"#,
            with: " ",
            options: .regularExpression
        )

        let stripped = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? trimmed : stripped
    }
}
