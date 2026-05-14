import Foundation

enum ProcessingPipelineStage: String, Equatable, Sendable {
    case transcriptEnhancer
    case workingAgent
    case shortcutPrefetch
    case unknown

    init(screenContextStage: String) {
        switch screenContextStage {
        case "transcript_agent":
            self = .transcriptEnhancer
        case "working_agent":
            self = .workingAgent
        case "shortcut_prefetch":
            self = .shortcutPrefetch
        default:
            self = .unknown
        }
    }
}

struct ProcessingPipelineProfile: Equatable, Sendable {
    let runtimeMode: RuntimeMode
    let interactionMode: InteractionMode

    init(config: ElsonLocalConfig, mode: InteractionMode) {
        self.init(runtimeMode: config.runtimeMode, interactionMode: mode)
    }

    init(runtimeMode: RuntimeMode, interactionMode: InteractionMode) {
        self.runtimeMode = runtimeMode
        self.interactionMode = interactionMode
    }

    var shouldPrefetchScreenContext: Bool {
        switch runtimeMode {
        case .local:
            return interactionMode == .agent
        case .hosted:
            return true
        }
    }

    var shouldPassImagesToTranscriptEnhancer: Bool {
        runtimeMode == .hosted
    }

    var shouldPassImagesToWorkingAgent: Bool {
        true
    }

    var transcriptEnhancerProfileName: String {
        shouldPassImagesToTranscriptEnhancer ? "cloud_full_context" : "local_text_only"
    }

    func shouldResolveScreenContext(for stage: ProcessingPipelineStage) -> Bool {
        switch stage {
        case .transcriptEnhancer:
            return runtimeMode == .hosted
        case .workingAgent:
            return true
        case .shortcutPrefetch:
            return shouldPrefetchScreenContext
        case .unknown:
            return runtimeMode == .hosted
        }
    }

    func transcriptEnhancerRequest(from request: ElsonRequestEnvelope) -> ElsonRequestEnvelope {
        guard !shouldPassImagesToTranscriptEnhancer else { return request }
        return ElsonRequestEnvelope(
            requestId: request.requestId,
            threadId: request.threadId,
            surface: request.surface,
            inputSource: request.inputSource,
            modeHint: InteractionMode.transcription.rawValue,
            rawTranscript: request.rawTranscript,
            enhancedTranscript: request.enhancedTranscript,
            transcriptSnippetCount: request.transcriptSnippetCount,
            transcriptChunkTimings: request.transcriptChunkTimings,
            myElsonMarkdown: "",
            transcriptAgentPrompt: "",
            workingAgentPrompt: "",
            selectionNote: nil,
            clipboardText: nil,
            attachments: [],
            conversationHistory: [],
            screenContext: ElsonScreenContextPayload(
                hasScreenContext: false,
                screenText: nil,
                screenDescription: nil
            ),
            timestamps: request.timestamps,
            appContext: ElsonAppContextPayload(
                frontmostAppName: nil,
                frontmostAppBundleId: nil,
                frontmostWindowTitle: nil
            ),
            continuationContext: nil,
            systemContext: request.systemContext,
            selectedSkill: nil
        )
    }
}
