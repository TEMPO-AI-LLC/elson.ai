import AppKit
import Foundation

struct RuntimeExecutionResult {
    let requestId: String
    let rawTranscript: String?
    let transcript: String
    let replyText: String
    let clipboardText: String
    let replyMode: String
    let actualRoute: String
    let routingSource: String
    let forcedRouteReason: String?
    let debugReason: String
    let actions: [ElsonAction]
    let responseThreadId: String?
    let threadDecision: AudioDeciderThreadDecision?
    let replyRelation: AudioDeciderReplyRelation?
    let replyConfidence: Double?
    let responseMessageId: String?
    let sessionKey: String?
    let updatedMyElsonMarkdown: String?
    let postResponseCorrectionSeed: PostResponseCorrectionSeed?
    let timeline: RequestTimelineSnapshot
    let visibleOutputSource: String
    let sourceSurface: String
    let hasScreenContext: Bool

    var feedbackSubject: FeedbackSubject {
        FeedbackSubject(
            requestId: requestId,
            threadId: responseThreadId,
            rawTranscript: rawTranscript,
            processedText: replyText,
            replyMode: replyMode,
            actualRoute: actualRoute,
            sourceSurface: sourceSurface,
            routingSource: routingSource,
            forcedRouteReason: forcedRouteReason,
            debugReason: debugReason,
            visibleOutputSource: visibleOutputSource,
            hasScreenContext: hasScreenContext
        )
    }
}

private enum RoutingSource: String {
    case explicitShortcut = "explicit_shortcut_mode"
    case explicitThreadMode = "explicit_thread_mode"
    case explicitMode = "explicit_mode"
}

struct AudioLatencyContext: Sendable {
    let shortcutDetectedAt: Date?
    let microphonePermissionStartedAt: Date?
    let microphonePermissionGrantedAt: Date?
    let recordingStartedAt: Date?
    let recordingStoppedAt: Date?
    let firstChunkTranscriptionCompletedAt: Date?
}

private enum VisibleOutputSource: String {
    case speculativeTranscriptReuse = "speculative_transcript_reuse"
    case transcriptRerunAfterIntent = "transcript_rerun_after_intent"
    case workingAgentPath = "working_agent_path"
    case explicitTranscriptPath = "explicit_transcript_path"
    case explicitAgentPath = "explicit_agent_path"
}

enum SpeculativeTranscriptDisposition {
    case reuse
    case rerun
    case ignore
}

private struct PrecomputedTranscriptResult {
    let text: String
    let durationMS: Int
}

final class ElsonRuntime: @unchecked Sendable {
    static let shared = ElsonRuntime()

    private init() {}

    private func transcriptProvider() -> LocalModelProvider { .cerebras }
    private func agentProvider() -> LocalModelProvider { .google }
    private func screenContextProvider() -> LocalModelProvider { .cerebras }

    func prefetchShortcutScreenContext(
        requestId: String,
        surface: String,
        threadId: String,
        config: ElsonLocalConfig,
        attachments: [AgentAttachment],
        screenshotJPEGData: [Data]
    ) async throws -> (context: LocalScreenContext, durationMS: Int)? {
        _ = config

        let requestAttachments = makeAttachmentsPayload(attachments: attachments, screenshotJPEGData: screenshotJPEGData)
        guard requestAttachments.contains(where: { $0.kind == "image" || $0.mime.lowercased().hasPrefix("image/") }) else {
            return nil
        }

        let timeline = RequestTimelineSnapshot(
            requestId: requestId,
            threadId: threadId,
            surface: surface,
            inputSource: "audio"
        )
        DebugLog.requestStageStart(timeline, stage: .screenContext, metadata: "prefetch=true")
        let startedAt = Date()
        let context = try await screenContextForStage(
            provider: screenContextProvider(),
            stage: "shortcut_prefetch",
            attachments: requestAttachments,
            requestId: requestId,
            threadId: threadId,
            surface: surface,
            inputSource: "audio",
            config: config,
            myElsonMarkdown: currentMyElsonMarkdown(from: config),
            lazy: false
        )
        let durationMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        DebugLog.requestStageEnd(timeline, stage: .screenContext, durationMS: durationMS, metadata: "prefetch=true")
        return (context, durationMS)
    }

    func processAudio(
        audioURL: URL,
        requestId: String? = nil,
        mode: InteractionMode,
        surface: String,
        threadId: String,
        config: ElsonLocalConfig,
        clipboardText: String? = nil,
        attachments: [AgentAttachment] = [],
        screenshotJPEGData: [Data] = [],
        conversationHistory: [ElsonConversationTurnPayload] = []
    ) async throws -> RuntimeExecutionResult {
        let aiService = LocalAIService()
        let resolvedRequestId = requestId ?? UUID().uuidString
        let requestAttachments = makeAttachmentsPayload(attachments: attachments, screenshotJPEGData: screenshotJPEGData)
        let transcriptionStartedAt = Date()
        DebugLog.requestStageStart(
            RequestTimelineSnapshot(
                requestId: resolvedRequestId,
                threadId: threadId,
                surface: surface,
                inputSource: "audio"
            ),
            stage: .groqTranscription
        )
        let rawTranscript = try await aiService.transcribe(
            audioURL: audioURL,
            groqAPIKey: config.groqAPIKey,
            logContext: LocalRequestLogContext(
                requestId: resolvedRequestId,
                threadId: threadId,
                surface: surface,
                inputSource: "audio"
            )
        )
        let transcriptionDurationMS = Int(Date().timeIntervalSince(transcriptionStartedAt) * 1000)
        DebugLog.requestStageEnd(
            RequestTimelineSnapshot(
                requestId: resolvedRequestId,
                threadId: threadId,
                surface: surface,
                inputSource: "audio"
            ),
            stage: .groqTranscription,
            durationMS: transcriptionDurationMS
        )
        return try await processAudioTranscript(
            requestId: resolvedRequestId,
            rawTranscript: rawTranscript,
            snippetCount: 1,
            inputSource: "audio",
            mode: mode,
            surface: surface,
            threadId: threadId,
            config: config,
            clipboardText: clipboardText,
            requestAttachments: requestAttachments,
            conversationHistory: conversationHistory,
            initialTimeline: RequestTimelineSnapshot(
                requestId: resolvedRequestId,
                threadId: threadId,
                surface: surface,
                inputSource: "audio"
            ).addingStage(.groqTranscription, durationMS: transcriptionDurationMS, countTowardProvider: true)
        )
    }

    func processAudioTranscript(
        requestId: String? = nil,
        rawTranscript: String,
        snippetCount: Int?,
        mode: InteractionMode,
        surface: String,
        threadId: String,
        config: ElsonLocalConfig,
        clipboardText: String? = nil,
        attachments: [AgentAttachment] = [],
        screenshotJPEGData: [Data] = [],
        conversationHistory: [ElsonConversationTurnPayload] = [],
        prefetchedDeciderScreenContext: LocalScreenContext? = nil,
        audioLatencyContext: AudioLatencyContext? = nil
    ) async throws -> RuntimeExecutionResult {
        let resolvedRequestId = requestId ?? UUID().uuidString
        let requestAttachments = makeAttachmentsPayload(attachments: attachments, screenshotJPEGData: screenshotJPEGData)
        return try await processAudioTranscript(
            requestId: resolvedRequestId,
            rawTranscript: rawTranscript,
            snippetCount: snippetCount,
            inputSource: "audio",
            mode: mode,
            surface: surface,
            threadId: threadId,
            config: config,
            clipboardText: clipboardText,
            requestAttachments: requestAttachments,
            conversationHistory: conversationHistory,
            initialTimeline: RequestTimelineSnapshot(
                requestId: resolvedRequestId,
                threadId: threadId,
                surface: surface,
                inputSource: "audio"
            ),
            prefetchedDeciderScreenContext: prefetchedDeciderScreenContext,
            audioLatencyContext: audioLatencyContext
        )
    }

    func processAudioTranscriptWithRetry(
        requestId: String? = nil,
        rawTranscript: String,
        snippetCount: Int?,
        mode: InteractionMode,
        surface: String,
        threadId: String,
        config: ElsonLocalConfig,
        clipboardText: String? = nil,
        attachments: [AgentAttachment] = [],
        screenshotJPEGData: [Data] = [],
        conversationHistory: [ElsonConversationTurnPayload] = [],
        prefetchedDeciderScreenContext: LocalScreenContext? = nil,
        audioLatencyContext: AudioLatencyContext? = nil,
        maxAttempts: Int = 3
    ) async throws -> RuntimeExecutionResult {
        var attempt = 0
        let resolvedRequestId = requestId ?? UUID().uuidString

        while true {
            do {
                return try await processAudioTranscript(
                    requestId: resolvedRequestId,
                    rawTranscript: rawTranscript,
                    snippetCount: snippetCount,
                    mode: mode,
                    surface: surface,
                    threadId: threadId,
                    config: config,
                    clipboardText: clipboardText,
                    attachments: attachments,
                    screenshotJPEGData: screenshotJPEGData,
                    conversationHistory: conversationHistory,
                    prefetchedDeciderScreenContext: prefetchedDeciderScreenContext,
                    audioLatencyContext: audioLatencyContext
                )
            } catch {
                attempt += 1
                if attempt >= maxAttempts || !shouldRetryAudioSend(after: error) {
                    throw error
                }

                let delaySeconds = min(Double(attempt), 3)
                DebugLog.runtime(
                    "audio_transcript_send_retry_scheduled thread_id=\(threadId) surface=\(surface) attempt=\(attempt + 1) delay_s=\(String(format: "%.1f", delaySeconds)) error=\(error.localizedDescription)"
                )
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
    }

    func processText(
        _ text: String,
        requestId: String? = nil,
        mode: InteractionMode,
        surface: String,
        threadId: String,
        config: ElsonLocalConfig,
        clipboardText: String? = nil,
        attachments: [AgentAttachment] = [],
        screenshotJPEGData: [Data] = [],
        conversationHistory: [ElsonConversationTurnPayload] = []
    ) async throws -> RuntimeExecutionResult {
        let resolvedRequestId = requestId ?? UUID().uuidString
        let requestAttachments = makeAttachmentsPayload(attachments: attachments, screenshotJPEGData: screenshotJPEGData)
        let effectiveMode = mode
        let currentMyElsonMarkdown = currentMyElsonMarkdown(from: config)
        var timeline = RequestTimelineSnapshot(
            requestId: resolvedRequestId,
            threadId: threadId,
            surface: surface,
            inputSource: "text"
        )
        DebugLog.requestStageStart(timeline, stage: .screenContext)
        let screenContextStartedAt = Date()
        let screenContext = try await screenContextForStage(
            provider: screenContextProvider(),
            stage: effectiveMode == .agent ? "working_agent" : "transcript_agent",
            attachments: requestAttachments,
            requestId: resolvedRequestId,
            threadId: threadId,
            surface: surface,
            inputSource: "text",
            config: config,
            myElsonMarkdown: currentMyElsonMarkdown,
            lazy: false
        )
        let screenContextDurationMS = Int(Date().timeIntervalSince(screenContextStartedAt) * 1000)
        DebugLog.requestStageEnd(timeline, stage: .screenContext, durationMS: screenContextDurationMS)
        timeline = timeline.addingStage(.screenContext, durationMS: screenContextDurationMS, countTowardProvider: true)

        if surface == "chat", effectiveMode == .transcription {
            let localTimeline = timeline
                .addingAnnotation("routing_source", value: RoutingSource.explicitThreadMode.rawValue)
                .addingAnnotation("thread_continuation", value: "local_current_thread")
            DebugLog.routingDecision(
                "thread_id=\(threadId) surface=\(surface) input_source=text route=direct_transcript routing_source=\(RoutingSource.explicitThreadMode.rawValue) thread_decision=continue_current_thread reply_relation=none"
            )
            return try await processTranscript(
                requestId: resolvedRequestId,
                rawTranscript: nil,
                enhancedTranscript: text,
                snippetCount: nil,
                inputSource: "text",
                mode: .transcription,
                surface: surface,
                threadId: threadId,
                config: config,
                clipboardText: clipboardText,
                requestAttachments: requestAttachments,
                screenContext: screenContext,
                conversationHistory: conversationHistory,
                appContext: makeAppContextPayload(),
                continuationContext: nil,
                threadDecision: .continueCurrentThread,
                replyRelation: AudioDeciderReplyRelation.none,
                initialTimeline: localTimeline,
                visibleOutputSource: .explicitTranscriptPath,
                routingSource: .explicitThreadMode
            )
        }

        return try await processTranscript(
            requestId: resolvedRequestId,
            rawTranscript: nil,
            enhancedTranscript: text,
            snippetCount: nil,
            inputSource: "text",
            mode: mode,
            surface: surface,
            threadId: threadId,
            config: config,
            clipboardText: clipboardText,
            requestAttachments: requestAttachments,
            screenContext: screenContext,
            conversationHistory: conversationHistory,
            initialTimeline: timeline,
            visibleOutputSource: effectiveMode == .agent ? .explicitAgentPath : .explicitTranscriptPath,
            routingSource: .explicitThreadMode
        )
    }

    private func processExplicitShortcutAudioTranscript(
        requestId: String,
        rawTranscript: String,
        snippetCount: Int?,
        mode: InteractionMode,
        inputSource: String,
        surface: String,
        threadId: String,
        config: ElsonLocalConfig,
        clipboardText: String?,
        requestAttachments: [ElsonAttachmentPayload],
        conversationHistory: [ElsonConversationTurnPayload],
        appContext: ElsonAppContextPayload,
        initialTimeline: RequestTimelineSnapshot,
        prefetchedDeciderScreenContext: LocalScreenContext?,
        audioLatencyContext: AudioLatencyContext?
    ) async throws -> RuntimeExecutionResult {
        let currentMyElsonMarkdown = currentMyElsonMarkdown(from: config)
        var timeline = initialTimeline.addingAnnotation(
            "routing_source",
            value: RoutingSource.explicitShortcut.rawValue
        )

        let initialScreenContext: LocalScreenContext
        if let prefetchedDeciderScreenContext {
            initialScreenContext = prefetchedDeciderScreenContext
        } else {
            DebugLog.requestStageStart(timeline, stage: .screenContext)
            let screenContextStartedAt = Date()
            initialScreenContext = try await screenContextForStage(
                provider: screenContextProvider(),
                stage: mode == .agent ? "working_agent" : "transcript_agent",
                attachments: requestAttachments,
                requestId: requestId,
                threadId: threadId,
                surface: surface,
                inputSource: inputSource,
                config: config,
                myElsonMarkdown: currentMyElsonMarkdown,
                lazy: false
            )
            let screenContextDurationMS = Int(Date().timeIntervalSince(screenContextStartedAt) * 1000)
            DebugLog.requestStageEnd(timeline, stage: .screenContext, durationMS: screenContextDurationMS)
            timeline = timeline.addingStage(.screenContext, durationMS: screenContextDurationMS, countTowardProvider: true)
        }

        let speculativeTranscriptTask: Task<PrecomputedTranscriptResult, Error>? = if mode == .transcription {
            Task {
                let startedAt = Date()
                let request = makeRequestEnvelope(
                    requestId: requestId,
                    rawTranscript: rawTranscript,
                    enhancedTranscript: rawTranscript,
                    snippetCount: snippetCount,
                    inputSource: inputSource,
                    mode: .transcription,
                    surface: surface,
                    threadId: threadId,
                    myElsonMarkdown: currentMyElsonMarkdown,
                    transcriptAgentPrompt: config.transcriptAgentPrompt,
                    workingAgentPrompt: config.workingAgentPrompt,
                    clipboardText: clipboardText,
                    attachments: requestAttachments,
                    screenContext: initialScreenContext,
                    conversationHistory: conversationHistory,
                    appContext: appContext,
                    continuationContext: nil
                )
                let formatted = try await LocalAIService().runTranscriptAgent(
                    request: makeSpeculativeTranscriptRequest(from: request),
                    provider: transcriptProvider(),
                    cerebrasAPIKey: config.cerebrasAPIKey,
                    geminiAPIKey: config.geminiAPIKey
                )
                return PrecomputedTranscriptResult(
                    text: formatted,
                    durationMS: Int(Date().timeIntervalSince(startedAt) * 1000)
                )
            }
        } else {
            nil
        }

        var debugReason = mode == .agent
            ? "Agent shortcut selected."
            : "Transcript shortcut selected."

        var finalScreenContext = initialScreenContext
        if mode == .agent, !finalScreenContext.hasScreenContext {
            DebugLog.requestStageStart(timeline, stage: .screenContext)
            let screenContextStartedAt = Date()
            finalScreenContext = try await screenContextForStage(
                provider: screenContextProvider(),
                stage: "working_agent",
                attachments: requestAttachments,
                requestId: requestId,
                threadId: threadId,
                surface: surface,
                inputSource: inputSource,
                config: config,
                myElsonMarkdown: currentMyElsonMarkdown,
                lazy: true
            )
            let screenContextDurationMS = Int(Date().timeIntervalSince(screenContextStartedAt) * 1000)
            DebugLog.requestStageEnd(timeline, stage: .screenContext, durationMS: screenContextDurationMS, metadata: "lazy=true")
            timeline = timeline.addingStage(.screenContext, durationMS: screenContextDurationMS, countTowardProvider: true)
        }

        var precomputedTranscript: PrecomputedTranscriptResult?
        if mode == .transcription, let speculativeTranscriptTask {
            precomputedTranscript = try? await speculativeTranscriptTask.value
        }

        DebugLog.routingDecision(
            "thread_id=\(threadId) surface=\(surface) input_source=\(inputSource) route=\(mode == .agent ? "full_agent" : "direct_transcript") routing_source=\(RoutingSource.explicitShortcut.rawValue) thread_decision=start_new_thread reply_relation=none"
        )

        return try await processTranscript(
            requestId: requestId,
            rawTranscript: rawTranscript,
            enhancedTranscript: rawTranscript,
            snippetCount: snippetCount,
            inputSource: inputSource,
            mode: mode,
            surface: surface,
            threadId: threadId,
            config: config,
            clipboardText: clipboardText,
            requestAttachments: requestAttachments,
            screenContext: finalScreenContext,
            conversationHistory: conversationHistory,
            audioDirectDebugReason: debugReason,
            appContext: appContext,
            continuationContext: nil,
            threadDecision: .startNewThread,
            replyRelation: AudioDeciderReplyRelation.none,
            replyConfidence: nil,
            initialTimeline: timeline,
            precomputedTranscript: precomputedTranscript,
            audioLatencyContext: audioLatencyContext,
            visibleOutputSource: mode == .agent ? .explicitAgentPath : .explicitTranscriptPath,
            routingSource: .explicitShortcut
        )
    }

    func formatRawTranscriptForChatComposer(
        requestId: String? = nil,
        rawTranscript: String,
        threadId: String,
        config: ElsonLocalConfig,
        conversationHistory: [ElsonConversationTurnPayload]
    ) async throws -> String {
        let resolvedRequestId = requestId ?? UUID().uuidString
        let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawTranscript.isEmpty else { return "" }

        let request = makeRequestEnvelope(
            requestId: resolvedRequestId,
            rawTranscript: trimmedRawTranscript,
            enhancedTranscript: trimmedRawTranscript,
            snippetCount: nil,
            inputSource: "audio",
            mode: .transcription,
            surface: "chat",
            threadId: threadId,
            myElsonMarkdown: currentMyElsonMarkdown(from: config),
            transcriptAgentPrompt: config.transcriptAgentPrompt,
            workingAgentPrompt: config.workingAgentPrompt,
            clipboardText: nil,
            attachments: [],
            screenContext: .none,
            conversationHistory: conversationHistory
        )

        return try await LocalAIService().runTranscriptAgent(
            request: request,
            provider: transcriptProvider(),
            cerebrasAPIKey: config.cerebrasAPIKey,
            geminiAPIKey: config.geminiAPIKey
        )
    }

    private func processAudioTranscript(
        requestId: String,
        rawTranscript: String,
        snippetCount: Int?,
        inputSource: String,
        mode: InteractionMode,
        surface: String,
        threadId: String,
        config: ElsonLocalConfig,
        clipboardText: String?,
        requestAttachments: [ElsonAttachmentPayload],
        conversationHistory: [ElsonConversationTurnPayload],
        initialTimeline: RequestTimelineSnapshot,
        prefetchedDeciderScreenContext: LocalScreenContext? = nil,
        audioLatencyContext: AudioLatencyContext? = nil
    ) async throws -> RuntimeExecutionResult {
        let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentMyElsonMarkdown = currentMyElsonMarkdown(from: config)
        var timeline = initialTimeline
        let appContext = makeAppContextPayload()

        if surface == "shortcut" {
            return try await processExplicitShortcutAudioTranscript(
                requestId: requestId,
                rawTranscript: trimmedRawTranscript,
                snippetCount: snippetCount,
                mode: mode,
                inputSource: inputSource,
                surface: surface,
                threadId: threadId,
                config: config,
                clipboardText: clipboardText,
                requestAttachments: requestAttachments,
                conversationHistory: conversationHistory,
                appContext: appContext,
                initialTimeline: timeline,
                prefetchedDeciderScreenContext: prefetchedDeciderScreenContext,
                audioLatencyContext: audioLatencyContext
            )
        }

        if surface == "chat", mode == .transcription {
            let chatScreenContext: LocalScreenContext
            if let prefetchedDeciderScreenContext {
                chatScreenContext = prefetchedDeciderScreenContext
            } else {
                DebugLog.requestStageStart(timeline, stage: .screenContext)
                let screenContextStartedAt = Date()
                chatScreenContext = try await screenContextForStage(
                    provider: screenContextProvider(),
                    stage: "transcript_agent",
                    attachments: requestAttachments,
                    requestId: requestId,
                    threadId: threadId,
                    surface: surface,
                    inputSource: inputSource,
                    config: config,
                    myElsonMarkdown: currentMyElsonMarkdown,
                    lazy: false
                )
                let screenContextDurationMS = Int(Date().timeIntervalSince(screenContextStartedAt) * 1000)
                DebugLog.requestStageEnd(timeline, stage: .screenContext, durationMS: screenContextDurationMS)
                timeline = timeline.addingStage(.screenContext, durationMS: screenContextDurationMS, countTowardProvider: true)
            }

            let localTimeline = timeline
                .addingAnnotation("routing_source", value: RoutingSource.explicitThreadMode.rawValue)
                .addingAnnotation("thread_continuation", value: "local_current_thread")
            DebugLog.routingDecision(
                "thread_id=\(threadId) surface=\(surface) input_source=\(inputSource) route=direct_transcript routing_source=\(RoutingSource.explicitThreadMode.rawValue) thread_decision=continue_current_thread reply_relation=none"
            )
            return try await processTranscript(
                requestId: requestId,
                rawTranscript: trimmedRawTranscript,
                enhancedTranscript: trimmedRawTranscript,
                snippetCount: snippetCount,
                inputSource: inputSource,
                mode: .transcription,
                surface: surface,
                threadId: threadId,
                config: config,
                clipboardText: clipboardText,
                requestAttachments: requestAttachments,
                screenContext: chatScreenContext,
                conversationHistory: conversationHistory,
                appContext: appContext,
                continuationContext: nil,
                threadDecision: .continueCurrentThread,
                replyRelation: AudioDeciderReplyRelation.none,
                initialTimeline: localTimeline,
                audioLatencyContext: audioLatencyContext,
                visibleOutputSource: .explicitTranscriptPath,
                routingSource: .explicitThreadMode
            )
        }

        if surface == "chat", mode == .agent {
            let chatScreenContext: LocalScreenContext
            if let prefetchedDeciderScreenContext {
                chatScreenContext = prefetchedDeciderScreenContext
            } else {
                DebugLog.requestStageStart(timeline, stage: .screenContext)
                let screenContextStartedAt = Date()
                chatScreenContext = try await screenContextForStage(
                    provider: screenContextProvider(),
                    stage: "working_agent",
                    attachments: requestAttachments,
                    requestId: requestId,
                    threadId: threadId,
                    surface: surface,
                    inputSource: inputSource,
                    config: config,
                    myElsonMarkdown: currentMyElsonMarkdown,
                    lazy: false
                )
                let screenContextDurationMS = Int(Date().timeIntervalSince(screenContextStartedAt) * 1000)
                DebugLog.requestStageEnd(timeline, stage: .screenContext, durationMS: screenContextDurationMS)
                timeline = timeline.addingStage(.screenContext, durationMS: screenContextDurationMS, countTowardProvider: true)
            }

            let localTimeline = timeline
                .addingAnnotation("routing_source", value: RoutingSource.explicitThreadMode.rawValue)
                .addingAnnotation("thread_continuation", value: "local_current_thread")
            DebugLog.routingDecision(
                "thread_id=\(threadId) surface=\(surface) input_source=\(inputSource) route=full_agent routing_source=\(RoutingSource.explicitThreadMode.rawValue) thread_decision=continue_current_thread reply_relation=none"
            )
            return try await processTranscript(
                requestId: requestId,
                rawTranscript: trimmedRawTranscript,
                enhancedTranscript: trimmedRawTranscript,
                snippetCount: snippetCount,
                inputSource: inputSource,
                mode: .agent,
                surface: surface,
                threadId: threadId,
                config: config,
                clipboardText: clipboardText,
                requestAttachments: requestAttachments,
                screenContext: chatScreenContext,
                conversationHistory: conversationHistory,
                appContext: appContext,
                continuationContext: nil,
                threadDecision: .continueCurrentThread,
                replyRelation: AudioDeciderReplyRelation.none,
                initialTimeline: localTimeline,
                audioLatencyContext: audioLatencyContext,
                visibleOutputSource: .explicitAgentPath,
                routingSource: .explicitThreadMode
            )
        }

        let fallbackScreenContext: LocalScreenContext
        if let prefetchedDeciderScreenContext {
            fallbackScreenContext = prefetchedDeciderScreenContext
        } else {
            DebugLog.requestStageStart(timeline, stage: .screenContext)
            let screenContextStartedAt = Date()
            fallbackScreenContext = try await screenContextForStage(
                provider: screenContextProvider(),
                stage: mode == .agent ? "working_agent" : "transcript_agent",
                attachments: requestAttachments,
                requestId: requestId,
                threadId: threadId,
                surface: surface,
                inputSource: inputSource,
                config: config,
                myElsonMarkdown: currentMyElsonMarkdown,
                lazy: false
            )
            let screenContextDurationMS = Int(Date().timeIntervalSince(screenContextStartedAt) * 1000)
            DebugLog.requestStageEnd(timeline, stage: .screenContext, durationMS: screenContextDurationMS)
            timeline = timeline.addingStage(.screenContext, durationMS: screenContextDurationMS, countTowardProvider: true)
        }

        let localTimeline = timeline.addingAnnotation("routing_source", value: RoutingSource.explicitMode.rawValue)
        DebugLog.routingDecision(
            "thread_id=\(threadId) surface=\(surface) input_source=\(inputSource) route=\(mode == .agent ? "full_agent" : "direct_transcript") routing_source=\(RoutingSource.explicitMode.rawValue) thread_decision=start_new_thread reply_relation=none"
        )
        return try await processTranscript(
            requestId: requestId,
            rawTranscript: trimmedRawTranscript,
            enhancedTranscript: trimmedRawTranscript,
            snippetCount: snippetCount,
            inputSource: inputSource,
            mode: mode,
            surface: surface,
            threadId: threadId,
            config: config,
            clipboardText: clipboardText,
            requestAttachments: requestAttachments,
            screenContext: fallbackScreenContext,
            conversationHistory: conversationHistory,
            appContext: appContext,
            continuationContext: nil,
            threadDecision: .startNewThread,
            replyRelation: AudioDeciderReplyRelation.none,
            initialTimeline: localTimeline,
            audioLatencyContext: audioLatencyContext,
            visibleOutputSource: mode == .agent ? .explicitAgentPath : .explicitTranscriptPath,
            routingSource: .explicitMode
        )
    }

    private func processTranscript(
        requestId: String,
        rawTranscript: String?,
        enhancedTranscript: String,
        snippetCount: Int?,
        inputSource: String,
        mode: InteractionMode,
        surface: String,
        threadId: String,
        config: ElsonLocalConfig,
        clipboardText: String?,
        requestAttachments: [ElsonAttachmentPayload],
        screenContext: LocalScreenContext,
        conversationHistory: [ElsonConversationTurnPayload],
        audioDirectDebugReason: String? = nil,
        appContext: ElsonAppContextPayload? = nil,
        continuationContext: ElsonContinuationContextPayload? = nil,
        threadDecision: AudioDeciderThreadDecision? = nil,
        replyRelation: AudioDeciderReplyRelation? = nil,
        replyConfidence: Double? = nil,
        initialTimeline: RequestTimelineSnapshot,
        precomputedTranscript: PrecomputedTranscriptResult? = nil,
        audioLatencyContext: AudioLatencyContext? = nil,
        visibleOutputSource: VisibleOutputSource,
        routingSource: RoutingSource,
        forcedRouteReason: String? = nil
    ) async throws -> RuntimeExecutionResult {
        let effectiveMode = mode
        let currentMyElsonMarkdown = currentMyElsonMarkdown(from: config)
        var timeline = initialTimeline
        let provider = effectiveMode == .agent ? agentProvider() : transcriptProvider()
        let selectedSkill: SelectedSkillPayload?

        if effectiveMode == .agent, config.skillsEnabled {
            let skillSnapshot = await SkillCatalogStore.shared.refresh(force: true)
            switch await SkillCatalogStore.shared.selectSkill(for: enhancedTranscript) {
            case .clearMatch(let skill):
                if let bundle = await SkillCatalogStore.shared.promptBundle(for: skill.id) {
                    selectedSkill = SelectedSkillPayload(
                        id: skill.id,
                        name: skill.name,
                        description: skill.description,
                        sourceFamily: skill.sourceFamily.rawValue,
                        promptContext: bundle.renderedContext
                    )
                } else {
                    selectedSkill = nil
                }
            case .ambiguous(let candidates):
                let suggestionText = candidates.map { "\($0.name) (\($0.sourceFamily.rawValue))" }.joined(separator: ", ")
                let response = ElsonResponseEnvelope(
                    replyMode: AgentOutcomeType.reply.rawValue,
                    displayText: "I found multiple matching skills: \(suggestionText). Tell me which skill to use, or continue without one.",
                    clipboardText: "",
                    actions: [],
                    requiresConfirmation: false,
                    threadReset: false,
                    debugReason: "Skills enabled, but the request matched multiple skills.",
                    threadId: threadId,
                    messageId: nil,
                    sessionKey: nil,
                    updatedMyElsonMarkdown: nil
                )

                return RuntimeExecutionResult(
                    requestId: requestId,
                    rawTranscript: rawTranscript,
                    transcript: enhancedTranscript,
                    replyText: response.displayText,
                    clipboardText: response.clipboardText,
                    replyMode: response.replyMode,
                    actualRoute: AudioDeciderRoute.fullAgent.rawValue,
                    routingSource: routingSource.rawValue,
                    forcedRouteReason: forcedRouteReason,
                    debugReason: response.debugReason,
                    actions: response.actions,
                    responseThreadId: response.threadId,
                    threadDecision: threadDecision,
                    replyRelation: replyRelation,
                    replyConfidence: replyConfidence,
                    responseMessageId: response.messageId,
                    sessionKey: response.sessionKey,
                    updatedMyElsonMarkdown: response.updatedMyElsonMarkdown,
                    postResponseCorrectionSeed: nil,
                    timeline: timeline
                        .addingAnnotation("skills_enabled", value: "true")
                        .addingAnnotation("skills_catalog_count", value: String(skillSnapshot.skills.count))
                        .addingAnnotation("skill_selection", value: "ambiguous")
                        .withThreadId(threadId),
                    visibleOutputSource: visibleOutputSource.rawValue,
                    sourceSurface: surface,
                    hasScreenContext: screenContext.hasScreenContext
                )
            case .none:
                selectedSkill = nil
            }
        } else {
            selectedSkill = nil
        }

        let request = makeRequestEnvelope(
            requestId: requestId,
            rawTranscript: rawTranscript,
            enhancedTranscript: enhancedTranscript,
            snippetCount: snippetCount,
            inputSource: inputSource,
            mode: effectiveMode,
            surface: surface,
            threadId: threadId,
            myElsonMarkdown: currentMyElsonMarkdown,
            transcriptAgentPrompt: config.transcriptAgentPrompt,
            workingAgentPrompt: config.workingAgentPrompt,
            clipboardText: clipboardText,
            attachments: requestAttachments,
            screenContext: screenContext,
            conversationHistory: conversationHistory,
            appContext: appContext,
            continuationContext: continuationContext,
            selectedSkill: selectedSkill
        )
        DebugLog.runtime(
            "request_envelope_created request_id=\(requestId) thread_id=\(threadId) surface=\(surface) input_source=\(inputSource) mode_hint=\(request.modeHint) attachments=\(requestAttachments.count) has_screen_context=\(screenContext.hasScreenContext) provider=\(provider.rawValue) selected_skill=\(selectedSkill?.name ?? "none") thread_decision=\(threadDecision?.rawValue ?? "none") reply_relation=\(replyRelation?.rawValue ?? "none")"
        )
        let response: ElsonResponseEnvelope

        if effectiveMode == .agent {
            DebugLog.routingDecision(
                "thread_id=\(threadId) surface=\(surface) input_source=\(inputSource) mode=working_agent provider=\(provider.rawValue) transcript_chars=\(enhancedTranscript.count) clipboard_present=\(((clipboardText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) == false)) attachments=\(requestAttachments.count) has_screen_context=\(screenContext.hasScreenContext) route=working_agent"
            )
            do {
                DebugLog.requestStageStart(timeline, stage: .workingAgent)
                let workingAgentStartedAt = Date()
                response = try await WorkingAgentTransport().send(request, config: config)
                let workingAgentDurationMS = Int(Date().timeIntervalSince(workingAgentStartedAt) * 1000)
                DebugLog.requestStageEnd(timeline, stage: .workingAgent, durationMS: workingAgentDurationMS)
                timeline = timeline.addingStage(.workingAgent, durationMS: workingAgentDurationMS, countTowardProvider: true)
            } catch {
                DebugLog.routingDecision(
                    "thread_id=\(threadId) mode=working_agent provider=\(provider.rawValue) route=working_agent_failed error=\(error.localizedDescription)"
                )
                throw error
            }
        } else if inputSource == "audio", let precomputedTranscript {
            timeline = timeline
                .addingStage(.speculativeTranscript, durationMS: precomputedTranscript.durationMS, countTowardProvider: true)
                .addingMetric(
                    "latency_recording_stop_to_transcript_ms",
                    valueMS: durationMS(from: audioLatencyContext?.recordingStoppedAt, to: Date())
                )
            DebugLog.requestMilestone(
                timeline,
                name: "final_transcript_accepted",
                metadata: "source=\(VisibleOutputSource.speculativeTranscriptReuse.rawValue)"
            )
            response = ElsonResponseEnvelope(
                replyMode: "transcript",
                displayText: precomputedTranscript.text,
                clipboardText: precomputedTranscript.text,
                actions: [],
                requiresConfirmation: false,
                threadReset: false,
                debugReason: "Transcript Agent speculative transcript reuse.",
                threadId: request.threadId,
                messageId: nil,
                sessionKey: nil,
                updatedMyElsonMarkdown: nil
            )
        } else if inputSource == "audio" {
            let trimmedAudioReason = audioDirectDebugReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DebugLog.routingDecision(
                "thread_id=\(threadId) surface=\(surface) input_source=\(inputSource) mode=transcript provider=\(provider.rawValue) transcript_chars=\(enhancedTranscript.count) clipboard_present=\(((clipboardText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) == false)) attachments=\(requestAttachments.count) has_screen_context=\(screenContext.hasScreenContext) route=transcript_agent reason=\(trimmedAudioReason.isEmpty ? "none" : trimmedAudioReason)"
            )
            DebugLog.requestStageStart(timeline, stage: .localTranscript)
            let transcriptAgentStartedAt = Date()
            response = try await LocalDirectTransport().send(request, config: config)
            let transcriptAgentDurationMS = Int(Date().timeIntervalSince(transcriptAgentStartedAt) * 1000)
            DebugLog.requestStageEnd(timeline, stage: .localTranscript, durationMS: transcriptAgentDurationMS)
            timeline = timeline.addingStage(.localTranscript, durationMS: transcriptAgentDurationMS, countTowardProvider: true)
            timeline = timeline.addingMetric(
                "latency_recording_stop_to_transcript_ms",
                valueMS: durationMS(from: audioLatencyContext?.recordingStoppedAt, to: Date())
            )
            DebugLog.requestMilestone(
                timeline,
                name: "final_transcript_accepted",
                metadata: "source=\(VisibleOutputSource.transcriptRerunAfterIntent.rawValue)"
            )
        } else {
            DebugLog.routingDecision(
                "thread_id=\(threadId) surface=\(surface) input_source=\(inputSource) mode=transcript provider=\(provider.rawValue) transcript_chars=\(enhancedTranscript.count) clipboard_present=\(((clipboardText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) == false)) attachments=\(requestAttachments.count) has_screen_context=\(screenContext.hasScreenContext) route=transcript_agent"
            )
            DebugLog.requestStageStart(timeline, stage: .localTranscript)
            let localTranscriptStartedAt = Date()
            response = try await LocalDirectTransport().send(request, config: config)
            let localTranscriptDurationMS = Int(Date().timeIntervalSince(localTranscriptStartedAt) * 1000)
            DebugLog.requestStageEnd(timeline, stage: .localTranscript, durationMS: localTranscriptDurationMS)
            timeline = timeline.addingStage(.localTranscript, durationMS: localTranscriptDurationMS, countTowardProvider: true)
        }

        timeline = timeline.addingAnnotation("visible_output_source", value: visibleOutputSource.rawValue)

        return RuntimeExecutionResult(
            requestId: requestId,
            rawTranscript: rawTranscript,
            transcript: enhancedTranscript,
            replyText: response.displayText,
            clipboardText: response.clipboardText,
            replyMode: response.replyMode,
            actualRoute: effectiveMode == .agent ? AudioDeciderRoute.fullAgent.rawValue : AudioDeciderRoute.directTranscript.rawValue,
            routingSource: routingSource.rawValue,
            forcedRouteReason: forcedRouteReason,
            debugReason: response.debugReason,
            actions: response.actions,
            responseThreadId: response.threadId,
            threadDecision: threadDecision,
            replyRelation: replyRelation,
            replyConfidence: replyConfidence,
            responseMessageId: response.messageId,
            sessionKey: response.sessionKey,
            updatedMyElsonMarkdown: response.updatedMyElsonMarkdown,
            postResponseCorrectionSeed: PostResponseCorrectionSeed(
                request: request,
                assistantReplyText: response.displayText
            ),
            timeline: timeline.withThreadId(threadId),
            visibleOutputSource: visibleOutputSource.rawValue,
            sourceSurface: surface,
            hasScreenContext: screenContext.hasScreenContext
        )
    }

    private func makeRequestEnvelope(
        requestId: String,
        rawTranscript: String?,
        enhancedTranscript: String,
        snippetCount: Int?,
        inputSource: String,
        mode: InteractionMode,
        surface: String,
        threadId: String,
        myElsonMarkdown: String,
        transcriptAgentPrompt: String,
        workingAgentPrompt: String,
        clipboardText: String?,
        attachments: [ElsonAttachmentPayload],
        screenContext: LocalScreenContext,
        conversationHistory: [ElsonConversationTurnPayload],
        appContext: ElsonAppContextPayload? = nil,
        continuationContext: ElsonContinuationContextPayload? = nil,
        selectedSkill: SelectedSkillPayload? = nil
    ) -> ElsonRequestEnvelope {
        let now = Date()
        let capturedAt = ISO8601DateFormatter().string(from: now)
        let systemContext = makeSystemContextPayload(now: now)
        let resolvedAppContext = appContext ?? makeAppContextPayload()

        return ElsonRequestEnvelope(
            requestId: requestId,
            threadId: threadId,
            surface: surface,
            inputSource: inputSource,
            modeHint: mode == .agent ? "agent" : "transcript",
            rawTranscript: rawTranscript,
            enhancedTranscript: enhancedTranscript,
            transcriptSnippetCount: snippetCount,
            myElsonMarkdown: myElsonMarkdown,
            transcriptAgentPrompt: transcriptAgentPrompt,
            workingAgentPrompt: workingAgentPrompt,
            selectionNote: nil,
            clipboardText: clipboardText,
            attachments: attachments,
            conversationHistory: conversationHistory,
            screenContext: ElsonScreenContextPayload(
                hasScreenContext: screenContext.hasScreenContext,
                screenText: screenContext.screenText,
                screenDescription: screenContext.screenDescription
            ),
            timestamps: ElsonTimestampsPayload(
                capturedAt: capturedAt,
                selectionNoteAt: nil,
                clipboardAt: clipboardText == nil ? nil : capturedAt,
                attachmentsAt: attachments.isEmpty ? nil : capturedAt
            ),
            appContext: resolvedAppContext,
            continuationContext: continuationContext,
            systemContext: systemContext,
            selectedSkill: selectedSkill
        )
    }

    private func makeAttachmentsPayload(
        attachments: [AgentAttachment],
        screenshotJPEGData: [Data]
    ) -> [ElsonAttachmentPayload] {
        attachments.map {
            ElsonAttachmentPayload(
                kind: "file",
                name: $0.fileName,
                mime: $0.mimeType,
                source: "user",
                dataRef: "data:\($0.mimeType);base64,\($0.data.base64EncodedString())"
            )
        } + screenshotJPEGData.enumerated().map { index, data in
            ElsonAttachmentPayload(
                kind: "image",
                name: "screenshot-\(index + 1).jpg",
                mime: "image/jpeg",
                source: "auto",
                dataRef: "data:image/jpeg;base64,\(data.base64EncodedString())"
            )
        }
    }

    private func screenContextForStage(
        provider: LocalModelProvider,
        stage: String,
        attachments: [ElsonAttachmentPayload],
        requestId: String,
        threadId: String,
        surface: String,
        inputSource: String,
        config: ElsonLocalConfig,
        myElsonMarkdown: String,
        lazy: Bool
    ) async throws -> LocalScreenContext {
        if stage == "transcript_agent", !config.transcriptScreenOCR {
            DebugLog.runtime(
                "screen_context_stage request_id=\(requestId) thread_id=\(threadId) stage=\(stage) provider=\(provider.rawValue) ocr=disabled_by_setting"
            )
            return .none
        }

        let images = attachments.compactMap { attachment -> LocalImageInput? in
            guard attachment.kind == "image" || attachment.mime.lowercased().hasPrefix("image/") else {
                return nil
            }
            guard let data = decodeDataRef(attachment.dataRef) else {
                return nil
            }
            return LocalImageInput(name: attachment.name, mime: attachment.mime, data: data)
        }

        guard !images.isEmpty else {
            DebugLog.runtime(
                "screen_context_stage request_id=\(requestId) thread_id=\(threadId) stage=\(stage) provider=\(provider.rawValue) ocr=none images=0"
            )
            return .none
        }

        guard provider == .cerebras else {
            DebugLog.runtime(
                "screen_context_stage request_id=\(requestId) thread_id=\(threadId) stage=\(stage) provider=\(provider.rawValue) ocr=skipped images=\(images.count)"
            )
            return .none
        }

        let maxAttempts = 3
        var attempt = 0
        while true {
            do {
                let context = try await extractScreenContext(
                    from: attachments,
                    groqAPIKey: config.groqAPIKey,
                    myElsonMarkdown: myElsonMarkdown,
                    logContext: LocalRequestLogContext(
                        requestId: requestId,
                        threadId: threadId,
                        surface: surface,
                        inputSource: inputSource
                    )
                )
                DebugLog.runtime(
                    "screen_context_stage request_id=\(requestId) thread_id=\(threadId) stage=\(stage) provider=\(provider.rawValue) ocr=\(lazy ? "lazy" : "performed") images=\(images.count) has_screen_context=\(context.hasScreenContext)"
                )
                return context
            } catch {
                attempt += 1
                let retryable = shouldRetryAudioSend(after: error)
                if retryable && attempt < maxAttempts {
                    DebugLog.runtime(
                        "screen_context_retry_scheduled request_id=\(requestId) thread_id=\(threadId) stage=\(stage) provider=\(provider.rawValue) attempt=\(attempt + 1) max_attempts=\(maxAttempts) error=\(error.localizedDescription)"
                    )
                    let delaySeconds = min(Double(attempt), 2)
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    continue
                }

                DebugLog.runtimeError(
                    "screen_context_failed_continuing_without_context request_id=\(requestId) thread_id=\(threadId) stage=\(stage) provider=\(provider.rawValue) attempts=\(attempt) images=\(images.count) error=\(error.localizedDescription)"
                )
                return .none
            }
        }
    }

    private func extractScreenContext(
        from attachments: [ElsonAttachmentPayload],
        groqAPIKey: String,
        myElsonMarkdown: String,
        logContext: LocalRequestLogContext
    ) async throws -> LocalScreenContext {
        let images = attachments.compactMap { attachment -> LocalImageInput? in
            guard attachment.kind == "image" || attachment.mime.lowercased().hasPrefix("image/") else {
                return nil
            }
            guard let data = decodeDataRef(attachment.dataRef) else {
                return nil
            }
            return LocalImageInput(name: attachment.name, mime: attachment.mime, data: data)
        }

        guard !images.isEmpty else {
            return .none
        }

        return try await LocalAIService().extractScreenContext(
            images: images,
            groqAPIKey: groqAPIKey,
            myElsonMarkdown: myElsonMarkdown,
            logContext: logContext
        )
    }

    private func decodeDataRef(_ dataRef: String) -> Data? {
        guard let separator = dataRef.range(of: "base64,") else {
            return nil
        }
        let encoded = String(dataRef[separator.upperBound...])
        return Data(base64Encoded: encoded)
    }

    private func currentMyElsonMarkdown(from config: ElsonLocalConfig) -> String {
        if let workspaceMarkdown = ElsonLocalConfigStore.shared.loadWorkspaceMyElsonMarkdown(),
           !workspaceMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MyElsonDocument.normalizedMarkdown(from: workspaceMarkdown)
        }

        return MyElsonDocument.normalizedMarkdown(from: config.myElsonMarkdown)
    }

    private func makeAppContextPayload() -> ElsonAppContextPayload {
        let snapshot = FrontmostAppContextResolver.snapshot()
        return ElsonAppContextPayload(
            frontmostAppName: snapshot.appName,
            frontmostAppBundleId: snapshot.bundleId,
            frontmostWindowTitle: snapshot.windowTitle
        )
    }

    private func makeSpeculativeTranscriptRequest(from request: ElsonRequestEnvelope) -> ElsonRequestEnvelope {
        ElsonRequestEnvelope(
            requestId: request.requestId,
            threadId: request.threadId,
            surface: request.surface,
            inputSource: request.inputSource,
            modeHint: InteractionMode.transcription.rawValue,
            rawTranscript: request.rawTranscript,
            enhancedTranscript: request.enhancedTranscript,
            transcriptSnippetCount: request.transcriptSnippetCount,
            myElsonMarkdown: MyElsonDocument.wordsGlossaryMarkdown(from: request.myElsonMarkdown),
            transcriptAgentPrompt: request.transcriptAgentPrompt,
            workingAgentPrompt: request.workingAgentPrompt,
            selectionNote: request.selectionNote,
            clipboardText: request.clipboardText,
            attachments: request.attachments,
            conversationHistory: [],
            screenContext: request.screenContext,
            timestamps: request.timestamps,
            appContext: request.appContext,
            continuationContext: nil,
            systemContext: request.systemContext,
            selectedSkill: request.selectedSkill
        )
    }

    private func durationMS(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return Int(end.timeIntervalSince(start) * 1000)
    }

    private func makeSystemContextPayload(now: Date) -> ElsonSystemContextPayload {
        let timezone = TimeZone.current

        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateTimeFormatter.timeZone = timezone
        dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timezone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = timezone
        timeFormatter.dateFormat = "HH:mm:ss"

        return ElsonSystemContextPayload(
            localDateTime: dateTimeFormatter.string(from: now),
            localDate: dateFormatter.string(from: now),
            localTime: timeFormatter.string(from: now),
            timezone: timezone.identifier
        )
    }

    private func shouldRetryAudioSend(after error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let localError = error as? LocalAIServiceError {
            switch localError {
            case .missingGroqKey, .missingCerebrasKey, .missingGeminiKey:
                return false
            case let .serviceFailure(_, code, _):
                return code == 429 || code >= 500
            case .invalidResponse:
                return true
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return true
        }

        return false
    }
}
