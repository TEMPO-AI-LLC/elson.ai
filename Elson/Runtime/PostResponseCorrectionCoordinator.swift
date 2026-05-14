import Foundation

private actor WordsCorrectionRunner {
    func run(seed: PostResponseCorrectionSeed, config: ElsonLocalConfig) async throws -> WordsCorrectionResult {
        guard config.runtimeMode == .hosted else {
            return WordsCorrectionResult(patch: nil, reason: "local_processing_skipped")
        }

        return try await LocalAIService().runWordsCorrection(
            seed: seed,
            provider: .cerebras,
            cerebrasAPIKey: config.cerebrasAPIKey,
            geminiAPIKey: config.geminiAPIKey
        )
    }
}

@MainActor
final class PostResponseCorrectionCoordinator {
    static let shared = PostResponseCorrectionCoordinator()

    private let runner = WordsCorrectionRunner()

    private init() {}

    func schedule(
        seed: PostResponseCorrectionSeed?,
        config: ElsonLocalConfig,
        appSettings: AppSettings
    ) {
        guard let seed else { return }
        let startedAt = Date()
        let refreshedSeed = seed.withMyElsonMarkdown(appSettings.myElsonMarkdown)

        guard WordsCorrectionGate.shouldRun(seed: refreshedSeed) else {
            DebugLog.runtime(
                "words_correction_skipped request_id=\(refreshedSeed.request.requestId) thread_id=\(refreshedSeed.request.threadId) surface=\(refreshedSeed.request.surface) input_source=\(refreshedSeed.request.inputSource) reason=no_name_correction_hints"
            )
            DebugLog.requestBackgroundTail(
                requestId: refreshedSeed.request.requestId,
                threadId: refreshedSeed.request.threadId,
                surface: refreshedSeed.request.surface,
                inputSource: refreshedSeed.request.inputSource,
                task: RequestTimelineStage.backgroundWordsCorrection.rawValue,
                durationMS: Int(Date().timeIntervalSince(startedAt) * 1000)
            )
            return
        }

        let providerName = config.runtimeMode == .local ? "local" : "cerebras"
        DebugLog.runtime(
            "words_correction_started request_id=\(refreshedSeed.request.requestId) thread_id=\(refreshedSeed.request.threadId) surface=\(refreshedSeed.request.surface) input_source=\(refreshedSeed.request.inputSource) provider=\(providerName)"
        )

        Task { @MainActor [runner] in
            do {
                let result = try await runner.run(seed: refreshedSeed, config: config)
                guard let patch = result.patch, !patch.isEmpty else {
                    DebugLog.runtime(
                        "words_correction_noop request_id=\(refreshedSeed.request.requestId) thread_id=\(refreshedSeed.request.threadId) reason=\(result.reason)"
                    )
                    DebugLog.requestBackgroundTail(
                        requestId: refreshedSeed.request.requestId,
                        threadId: refreshedSeed.request.threadId,
                        surface: refreshedSeed.request.surface,
                        inputSource: refreshedSeed.request.inputSource,
                        task: RequestTimelineStage.backgroundWordsCorrection.rawValue,
                        durationMS: Int(Date().timeIntervalSince(startedAt) * 1000)
                    )
                    return
                }

                let current = MyElsonDocument.normalizedMarkdown(from: appSettings.myElsonMarkdown)
                let merged = MyElsonDocument(markdown: current).merged(with: patch).renderedMarkdown
                guard merged != current else {
                    DebugLog.runtime(
                        "words_correction_noop request_id=\(refreshedSeed.request.requestId) thread_id=\(refreshedSeed.request.threadId) reason=no_merge_change"
                    )
                    DebugLog.requestBackgroundTail(
                        requestId: refreshedSeed.request.requestId,
                        threadId: refreshedSeed.request.threadId,
                        surface: refreshedSeed.request.surface,
                        inputSource: refreshedSeed.request.inputSource,
                        task: RequestTimelineStage.backgroundWordsCorrection.rawValue,
                        durationMS: Int(Date().timeIntervalSince(startedAt) * 1000)
                    )
                    return
                }

                appSettings.applyAgentMyElsonMarkdownUpdate(merged)
                DebugLog.runtime(
                    "words_correction_updated request_id=\(refreshedSeed.request.requestId) thread_id=\(refreshedSeed.request.threadId) added=\(patch.words.count) removed=\(patch.removeWords.count) replaced=\(patch.replaceWords.count) reason=\(result.reason)"
                )
                DebugLog.requestBackgroundTail(
                    requestId: refreshedSeed.request.requestId,
                    threadId: refreshedSeed.request.threadId,
                    surface: refreshedSeed.request.surface,
                    inputSource: refreshedSeed.request.inputSource,
                    task: RequestTimelineStage.backgroundWordsCorrection.rawValue,
                    durationMS: Int(Date().timeIntervalSince(startedAt) * 1000)
                )
            } catch {
                DebugLog.runtimeError(
                    "words_correction_failed request_id=\(refreshedSeed.request.requestId) thread_id=\(refreshedSeed.request.threadId) error=\(error.localizedDescription)"
                )
                DebugLog.requestBackgroundTail(
                    requestId: refreshedSeed.request.requestId,
                    threadId: refreshedSeed.request.threadId,
                    surface: refreshedSeed.request.surface,
                    inputSource: refreshedSeed.request.inputSource,
                    task: RequestTimelineStage.backgroundWordsCorrection.rawValue,
                    durationMS: Int(Date().timeIntervalSince(startedAt) * 1000)
                )
            }
        }
    }
}

private enum WordsCorrectionGate {
    private static let correctionCues = [
        "schreibt man",
        "schreibweise",
        "geschrieben",
        "heißt",
        "heisst",
        "nennt sich",
        "korrektur",
        "korrigier",
        "korrekt heißt",
        "korrekt heisst",
        "eigenname",
        "eigennamen",
        "produktname",
        "firmenname",
        "brand name",
        "company name",
        "spelling",
        "spelled",
        "spell it",
        "is called"
    ]

    private static let ignoredAcronyms: Set<String> = [
        "API",
        "ASR",
        "CPU",
        "CSV",
        "CSS",
        "HTML",
        "HTTP",
        "HTTPS",
        "ID",
        "IDE",
        "JPEG",
        "JPG",
        "JSON",
        "LLM",
        "OCR",
        "PDF",
        "PNG",
        "RAM",
        "SQL",
        "STT",
        "TCC",
        "TSV",
        "UI",
        "URI",
        "URL",
        "UX",
        "XML"
    ]

    private static let nameLikePatterns = [
        #"(?i)\b[A-Z0-9][A-Z0-9-]{1,}\.(?:ai|app|cloud|com|de|dev|io|net|org|sh|so|xyz)\b"#,
        #"\b[\p{L}0-9]*[a-zäöüß][A-ZÄÖÜ][\p{L}0-9.-]*\b"#,
        #"\b[A-ZÄÖÜ]{3,}[A-ZÄÖÜ0-9.-]*\b"#,
        #"(?i)\b[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+\b"#,
        #"\b[A-ZÄÖÜ][a-zäöüß]{2,}\s+(?:AI|App|Cloud|Flow|Labs|Studio|Systems|Tech|Technologies|Inc|LLC|GmbH|AG)\b"#
    ]

    static func shouldRun(seed: PostResponseCorrectionSeed) -> Bool {
        let request = seed.request
        let text = [
            request.rawTranscript,
            request.enhancedTranscript,
            request.screenContext.screenText,
            request.screenContext.screenDescription,
            seed.assistantReplyText
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

        guard !text.isEmpty else { return false }
        if containsCorrectionCue(in: text) { return true }
        return containsNameLikeCandidate(in: text)
    }

    private static func containsCorrectionCue(in text: String) -> Bool {
        let lowered = text.lowercased()
        if correctionCues.contains(where: { lowered.contains($0) }) {
            return true
        }
        return lowered.range(of: #"nicht\s+.+\s+sondern"#, options: .regularExpression) != nil
            || lowered.range(of: #"\bnot\s+.+\s+but\b"#, options: .regularExpression) != nil
    }

    private static func containsNameLikeCandidate(in text: String) -> Bool {
        nameLikePatterns
            .flatMap { matches(pattern: $0, in: text) }
            .contains { candidate in
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { return false }
                return !ignoredAcronyms.contains(normalized.uppercased())
            }
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let stringRange = Range(match.range, in: text) else { return nil }
            return String(text[stringRange])
        }
    }
}
