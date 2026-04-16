import Foundation

struct GroqTranscriptionSegment: Codable, Equatable {
    let text: String?
    let start: Double?
    let end: Double?
}

struct GroqTranscriptionPayload: Decodable, Equatable {
    let text: String
    let language: String?
    let duration: Double?
    let segments: [GroqTranscriptionSegment]?
}

struct GroqTranscriptionSanitizer {
    struct Result: Equatable {
        let text: String
        let removedTrailingText: String?
        let reason: String?
    }

    private static let japaneseOutroPhrases = [
        "ご視聴ありがとうございました。",
        "ご視聴ありがとうございました",
    ]

    static func sanitize(_ payload: GroqTranscriptionPayload) -> Result {
        let transcript = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return Result(text: "", removedTrailingText: nil, reason: nil)
        }

        guard let segments = payload.segments?
            .compactMap({ $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }),
              segments.count >= 2
        else {
            return Result(text: transcript, removedTrailingText: nil, reason: nil)
        }

        let trailing = segments.last ?? ""
        let leadingSegments = Array(segments.dropLast())
        let leadingText = leadingSegments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leadingText.isEmpty else {
            return Result(text: transcript, removedTrailingText: nil, reason: nil)
        }

        let normalizedTrailing = normalize(trailing)
        let trailingIsKnownOutro = japaneseOutroPhrases.contains(normalizedTrailing)
        let trailingLooksJapanese = containsJapaneseScript(trailing)
        let leadingLooksMostlyLatin = containsLatinScript(leadingText)

        guard trailingLooksJapanese, leadingLooksMostlyLatin, trailingIsKnownOutro else {
            return Result(text: transcript, removedTrailingText: nil, reason: nil)
        }

        let cleanedTranscript = removingTrailingOccurrence(of: trailing, from: transcript)
        let cleaned = cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return Result(text: transcript, removedTrailingText: nil, reason: nil)
        }

        return Result(
            text: cleaned,
            removedTrailingText: trailing,
            reason: "dropped_japanese_trailing_outro"
        )
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingTrailingOccurrence(of suffix: String, from transcript: String) -> String {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTranscript.hasSuffix(trimmedSuffix) else {
            return normalizedTranscript
        }

        let suffixStart = normalizedTranscript.index(normalizedTranscript.endIndex, offsetBy: -trimmedSuffix.count)
        var cleaned = String(normalizedTranscript[..<suffixStart])
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("。") || cleaned.hasSuffix(".") {
            return cleaned
        }
        return cleaned
    }

    private static func containsJapaneseScript(_ value: String) -> Bool {
        value.range(of: #"[ぁ-んァ-ヶ一-龯]"#, options: .regularExpression) != nil
    }

    private static func containsLatinScript(_ value: String) -> Bool {
        value.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
    }
}
