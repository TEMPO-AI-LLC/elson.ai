import Foundation

private actor WordsCorrectionRunner {
    func run(seed: PostResponseCorrectionSeed, config: ElsonLocalConfig) async throws -> WordsCorrectionResult {
        try await LocalAIService().runWordsCorrection(
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

        DebugLog.runtime(
            "words_correction_started request_id=\(seed.request.requestId) thread_id=\(seed.request.threadId) surface=\(seed.request.surface) input_source=\(seed.request.inputSource) provider=cerebras"
        )

        let refreshedSeed = seed.withMyElsonMarkdown(appSettings.myElsonMarkdown)

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
