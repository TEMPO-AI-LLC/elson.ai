import AVFoundation
import SwiftUI

struct ThreadHistoryWindowView: View {
    private let minimumVoiceMessageDuration: TimeInterval = 1
    @Environment(ChatStore.self) private var chatStore
    @Environment(AppSettings.self) private var appSettings
    let recordingService: AudioRecordingService

    @State private var draftText: String = ""
    @State private var isComposerFocused: Bool = false
    @State private var composerHeight: CGFloat = 22
    @State private var capturedHostedVoiceSession: HostedChunkedAudioSession? = nil
    @State private var capturedLocalVoiceSession: LocalVoiceCaptureSession? = nil
    @State private var capturedLocalVoiceRun: LocalVoiceCapturedRun? = nil
    @State private var isSending = false
    @State private var errorMessage: String? = nil
    @State private var expandedVoiceMessageID: String? = nil
    @State private var hoveredAssistantMessageID: String? = nil
    @State private var previewAttachment: ChatMessageAttachment? = nil
    @State private var pendingThreadTarget: ThreadReplyTarget = .transcript
    private let topChromeHeight: CGFloat = 24

    var body: some View {
        let threadId = chatStore.thread.id
        let trimmedDraft = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedThreadTarget = ThreadModeStore.get(threadId: threadId)
        let hasCapturedVoiceSession = capturedHostedVoiceSession != nil
            || capturedLocalVoiceSession != nil
            || capturedLocalVoiceRun != nil
        let isVoiceRecording = recordingService.isRecording
            || (capturedLocalVoiceSession?.isRecording ?? false)
        let canSend = !isSending
            && selectedThreadTarget != nil
            && (!trimmedDraft.isEmpty || isVoiceRecording || hasCapturedVoiceSession)
        let renderedMessages = mapLocalTailMessages(threadId: threadId)

        ZStack {
            Color.clear
                .elsonGlassCard(cornerRadius: 24)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topChrome

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }

                ScrollView {
                    LazyVStack(spacing: 12) {
                        if renderedMessages.isEmpty {
                            Text("No messages in this thread yet.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(renderedMessages) { message in
                                messageRow(message)
                            }
                        }

                        if chatStore.inFlight?.threadId == threadId {
                            ThreadHistoryInFlightRow(
                                title: chatStore.inFlight?.mode == .agent ? "Agent working..." : "Processing..."
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }

                composer(canSend: canSend)
                    .padding(16)
            }
        }
        .frame(minWidth: 520, minHeight: 640)
        .sheet(item: $previewAttachment) { attachment in
            ThreadAttachmentPreviewSheet(attachment: attachment)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openThreadWindow)) { _ in
            chatStore.markThreadRead(chatStore.thread.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .insertTextIntoThreadComposer)) { notification in
            guard let insertedText = notification.object as? String else { return }
            appendToDraft(insertedText)
        }
    }

    @ViewBuilder
    private var topChrome: some View {
        ThreadHistoryTopChrome(
            topChromeHeight: topChromeHeight,
            replaySessionId: appSettings.lastReplayableCaptureSessionId,
            isReprocessing: appSettings.reprocessingCapturedSessionId != nil,
            onNewChat: startNewChat,
            onReplay: { sessionId in
                appSettings.reprocessCapturedSession(sessionId: sessionId, chatStore: chatStore, source: "chat_replay")
            }
        )
    }

    @ViewBuilder
    private func composer(canSend: Bool) -> some View {
        ThreadHistoryComposer(
            recordingService: recordingService,
            selectedThreadTarget: Binding(
                get: { ThreadModeStore.get(threadId: chatStore.thread.id) },
                set: { newValue in
                    guard let newValue else { return }
                    ThreadModeStore.set(threadId: chatStore.thread.id, target: newValue)
                }
            ),
            pendingThreadTarget: $pendingThreadTarget,
            draftText: $draftText,
            isComposerFocused: $isComposerFocused,
            composerHeight: $composerHeight,
            isVoiceRecording: recordingService.isRecording || (capturedLocalVoiceSession?.isRecording ?? false),
            hasCapturedVoiceSession: capturedHostedVoiceSession != nil || capturedLocalVoiceSession != nil || capturedLocalVoiceRun != nil,
            isSending: isSending,
            canSend: canSend,
            onToggleVoiceCapture: toggleVoiceCapture,
            onEscape: cancelVoiceCaptureIfNeeded,
            onSend: sendMessage
        )
    }

    @ViewBuilder
    private func messageRow(_ message: ConversationThreadMessage) -> some View {
        ThreadHistoryMessageRow(
            message: message,
            transcriptText: voiceTranscriptText(for: message),
            isVoiceExpanded: expandedVoiceMessageID == message.id,
            assistantHoverVisible: hoveredAssistantMessageID == message.id,
            onToggleVoiceExpansion: {
                expandedVoiceMessageID = expandedVoiceMessageID == message.id ? nil : message.id
            },
            onOpenAttachment: { attachment in
                previewAttachment = attachment
            },
            onHoverAssistant: { hovering in
                hoveredAssistantMessageID = hovering ? message.id : (hoveredAssistantMessageID == message.id ? nil : hoveredAssistantMessageID)
            },
            onReplayVoiceMessage: { sessionId in
                appSettings.reprocessCapturedSession(sessionId: sessionId, chatStore: chatStore, source: "chat_replay")
            }
        )
    }

    private func toggleVoiceCapture() {
        if appSettings.runtimeMode == .local {
            toggleLocalVoiceCapture()
            return
        }

        if recordingService.isRecording {
            guard let session = capturedHostedVoiceSession else {
                appSettings.isRecording = false
                appSettings.indicatorState = .error
                errorMessage = "Missing audio session."
                return
            }

            Task { @MainActor in
                do {
                    let kept = try await session.stopRecordingDiscardingIfShorterThan(minimumVoiceMessageDuration)
                    appSettings.isRecording = false
                    appSettings.indicatorState = .idle
                    if !kept {
                        capturedHostedVoiceSession = nil
                        errorMessage = "Recording too short."
                    }
                } catch {
                    capturedHostedVoiceSession = nil
                    appSettings.isRecording = false
                    appSettings.indicatorState = .error
                    errorMessage = error.localizedDescription
                }
            }
            return
        }

        Task { @MainActor in
            do {
                try await PermissionCoordinator.ensureMicrophonePermission()
            } catch {
                errorMessage = error.localizedDescription
                return
            }

            capturedHostedVoiceSession = nil
            let session = HostedChunkedAudioSession(
                recordingService: recordingService,
                groqAPIKey: appSettings.makeLocalConfig().groqAPIKey,
                modeHint: (ThreadModeStore.get(threadId: chatStore.thread.id) ?? pendingThreadTarget) == .agent ? .agent : .transcription,
                requestLogContext: LocalRequestLogContext(
                    requestId: UUID().uuidString,
                    threadId: chatStore.thread.id,
                    surface: "chat",
                    inputSource: "audio"
                )
            )
            guard session.start() else {
                errorMessage = "Failed to start microphone recording. Check System Settings > Privacy & Security > Microphone."
                return
            }

            capturedHostedVoiceSession = session
            appSettings.pendingScreenshotJPEGData = []
            appSettings.indicatorState = .listening
            appSettings.isRecording = true
            errorMessage = nil

            Task {
                guard let captured = try? await captureScreenshotDataIfPossible() else { return }
                await MainActor.run {
                    guard capturedHostedVoiceSession === session else { return }
                    appSettings.pendingScreenshotJPEGData = [captured]
                }
            }
        }
    }

    private func toggleLocalVoiceCapture() {
        if let session = capturedLocalVoiceSession, session.isRecording {
            stopLocalComposerVoiceCapture(session)
            return
        }

        capturedLocalVoiceRun = nil
        Task { @MainActor in
            if !PermissionCoordinator.hasMicrophonePermission() {
                do {
                    try await PermissionCoordinator.ensureMicrophonePermission()
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }

            let threadId = chatStore.thread.id
            let selectedThreadTarget = ThreadModeStore.get(threadId: threadId) ?? pendingThreadTarget
            let mode: InteractionMode = selectedThreadTarget == .agent ? .agent : .transcription
            let session = LocalVoiceCaptureSession(
                requestId: UUID().uuidString,
                threadId: threadId,
                mode: mode,
                sourceSurface: "chat"
            )
            do {
                try session.start()
            } catch {
                errorMessage = error.localizedDescription
                appSettings.indicatorState = .error
                return
            }

            capturedHostedVoiceSession = nil
            capturedLocalVoiceSession = session
            capturedLocalVoiceRun = nil
            appSettings.pendingScreenshotJPEGData = []
            appSettings.indicatorState = .listening
            appSettings.isRecording = true
            errorMessage = nil
            appSettings.startLocalProcessorCommandWarmup(mode: mode, reason: "chat_voice_recording_started")
        }
    }

    private func stopLocalComposerVoiceCapture(_ session: LocalVoiceCaptureSession) {
        do {
            let run = try session.stop(minimumDuration: minimumVoiceMessageDuration, latencyContext: nil)
            capturedLocalVoiceSession = nil
            capturedLocalVoiceRun = run
            appSettings.isRecording = false
            appSettings.indicatorState = .idle
            errorMessage = nil
        } catch {
            capturedLocalVoiceSession = nil
            capturedLocalVoiceRun = nil
            appSettings.isRecording = false
            appSettings.indicatorState = .error
            errorMessage = error.localizedDescription
        }
    }

    private func sendLocalVoiceMessage(
        config: ElsonLocalConfig,
        pendingAttachments: [AgentAttachment],
        clipboardText: String?
    ) {
        guard !isSending else { return }
        let run: LocalVoiceCapturedRun
        if let capturedLocalVoiceRun {
            run = capturedLocalVoiceRun
        } else if let session = capturedLocalVoiceSession {
            do {
                run = try session.stop(minimumDuration: minimumVoiceMessageDuration, latencyContext: nil)
            } catch {
                capturedLocalVoiceSession = nil
                capturedLocalVoiceRun = nil
                appSettings.isRecording = false
                appSettings.indicatorState = .error
                errorMessage = error.localizedDescription
                return
            }
        } else {
            return
        }

        isSending = true
        errorMessage = nil
        draftText = ""
        capturedLocalVoiceSession = nil
        capturedLocalVoiceRun = nil
        appSettings.isRecording = false
        appSettings.indicatorState = run.isAgentRun ? .agentProcessing : .processing

        let screenshotTask: Task<[Data], Never>? = if run.isAgentRun {
            Task { @MainActor in
                guard let captured = try? await captureScreenshotDataIfPossible(fullScreen: true) else {
                    return []
                }
                return [captured]
            }
        } else {
            nil
        }
        LocalVoiceRunCoordinator.shared.processCapturedRun(
            run,
            appSettings: appSettings,
            chatStore: chatStore,
            config: config,
            pendingAttachments: run.isAgentRun ? pendingAttachments : [],
            clipboardText: run.isAgentRun ? clipboardText : nil,
            screenshotJPEGData: [],
            screenshotJPEGDataTask: screenshotTask,
            source: "chat"
        )
        isSending = false
    }

    private func sendMessage() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadId = chatStore.thread.id
        guard !isSending else { return }
        let hasLocalVoice = capturedLocalVoiceSession != nil || capturedLocalVoiceRun != nil
        let hasHostedVoice = capturedHostedVoiceSession != nil || recordingService.isRecording
        guard !trimmed.isEmpty || hasLocalVoice || hasHostedVoice else { return }

        let isVoiceMessage = hasLocalVoice || hasHostedVoice

        let optimisticMessageId = UUID()
        let placeholder = trimmed.isEmpty ? "Voice message..." : trimmed
        let config = appSettings.makeLocalConfig()
        let pendingAttachments = appSettings.pendingAttachments
        var pendingScreenshotJPEGData = appSettings.pendingScreenshotJPEGData
        let reusableContextAttachments = latestContextAttachments()
        let reusableContextScreenshotData = latestContextScreenshotData(from: reusableContextAttachments)
        let clipboardText = ClipboardHelper.getClipboardContent()
        let conversationHistory = outgoingConversationHistory()
        let selectedThreadTarget = ThreadModeStore.get(threadId: threadId) ?? pendingThreadTarget
        let mode: InteractionMode = selectedThreadTarget == .agent ? .agent : .transcription
        let requestId = capturedLocalVoiceRun?.requestId
            ?? capturedLocalVoiceSession?.requestId
            ?? capturedHostedVoiceSession?.requestId
            ?? UUID().uuidString
        if config.runtimeMode == .local, hasLocalVoice {
            sendLocalVoiceMessage(
                config: config,
                pendingAttachments: pendingAttachments,
                clipboardText: clipboardText
            )
            return
        }
        isSending = true
        errorMessage = nil
        draftText = ""
        appSettings.indicatorState = mode == .agent ? .agentProcessing : .processing
        if ThreadModeStore.get(threadId: threadId) == nil {
            ThreadModeStore.set(threadId: threadId, target: selectedThreadTarget)
        }
        if !isVoiceMessage {
            chatStore.append(
                ChatMessage(
                    id: optimisticMessageId,
                    role: .user,
                    content: placeholder,
                    style: .text
                )
            )
            chatStore.beginRun(
                threadId: threadId,
                mode: mode == .agent ? .agent : .transcript,
                optimisticUserMessageId: optimisticMessageId
            )
        }

        func finalizeRequest(
            result: RuntimeExecutionResult,
            finalizedVoiceSession: HostedChunkedAudioSession?,
            timelineBase: RequestTimelineSnapshot,
            requestStartedAt: Date,
            useVoiceMessageStyle: Bool
        ) async {
            let desktopActionsStartedAt = Date()
            let actionNotes = await DesktopActionExecutor.execute(result.actions, appSettings: appSettings)
            var timeline = timelineBase.addingStage(
                .desktopActions,
                durationMS: Int(Date().timeIntervalSince(desktopActionsStartedAt) * 1000)
            )
            let capturedNewScreenshot = result.actions.contains { $0.type == "capture_screenshot" }
            let correctionSeed = result.postResponseCorrectionSeed

            let uiCommitStartedAt = Date()
            await MainActor.run {
                let effectiveThreadId = result.responseThreadId ?? threadId
                let assistantMessageId = UUID()
                let userAttachments = persistUserAttachmentsIfNeeded(
                    result: result,
                    screenshotJPEGData: pendingScreenshotJPEGData,
                    reusableAttachments: reusableContextAttachments,
                    threadId: effectiveThreadId,
                    messageId: optimisticMessageId
                )
                if !actionNotes.isEmpty {
                    print(actionNotes.joined(separator: " "))
                }
                if effectiveThreadId != threadId {
                    chatStore.adoptThreadIdPreservingMessages(newId: effectiveThreadId)
                }
                let captureSessionId = finalizedVoiceSession?.persistedSessionId
                finalizedVoiceSession?.markDeliveryCompleted()
                chatStore.replaceMessage(
                    id: optimisticMessageId,
                    role: .user,
                    style: useVoiceMessageStyle ? .voiceTranscript : .text,
                    rawTranscript: useVoiceMessageStyle ? result.rawTranscript : nil,
                    overrideRawTranscript: useVoiceMessageStyle,
                    captureSessionId: captureSessionId,
                    overrideCaptureSessionId: useVoiceMessageStyle && captureSessionId != nil,
                    attachments: userAttachments,
                    showsAttachmentChip: !userAttachments.isEmpty,
                    with: result.transcript.isEmpty ? placeholder : result.transcript
                )
                chatStore.append(
                    ChatMessage(
                        id: assistantMessageId,
                        role: .assistant,
                        content: result.replyText,
                        insertedText: result.clipboardText,
                        feedbackSubject: result.feedbackSubject
                    )
                )
                chatStore.endRun(threadId: threadId)
                chatStore.noteConversationActivity(
                    threadId: effectiveThreadId,
                    lastMessage: result.replyText,
                    lastRole: "assistant",
                    lastReplyTarget: result.replyMode,
                    sessionKey: result.sessionKey,
                    markUnread: false
                )
                capturedHostedVoiceSession = nil
                isSending = false
                appSettings.recordLastOutput(from: result, captureSessionId: captureSessionId)
                if !result.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appSettings.appendTranscriptHistory(
                        text: result.replyText,
                        rawTranscript: result.rawTranscript,
                        source: "chat",
                        threadId: effectiveThreadId,
                        replyMode: result.replyMode,
                        actualRoute: result.actualRoute,
                        routingSource: result.routingSource,
                        forcedRouteReason: result.forcedRouteReason,
                        requestId: result.requestId,
                        captureSessionId: captureSessionId
                    )
                }
                _ = ClipboardHelper.deliverTranscript(
                    result.clipboardText,
                    behavior: appSettings.transcriptClipboardBehavior(autoPasteOverride: false)
                )
                appSettings.indicatorState = mode == .agent ? .agentSuccess : .success
                appSettings.clearAgentAttachments()
                if !capturedNewScreenshot {
                    appSettings.pendingScreenshotJPEGData = []
                }
                if let updatedMyElsonMarkdown = result.updatedMyElsonMarkdown {
                    appSettings.applyAgentMyElsonMarkdownUpdate(updatedMyElsonMarkdown)
                }
            }

            let uiCommitDurationMS = Int(Date().timeIntervalSince(uiCommitStartedAt) * 1000)
            timeline = timeline
                .withThreadId(result.responseThreadId ?? threadId)
                .addingStage(.uiCommit, durationMS: uiCommitDurationMS)
                .withVisibleLatencyMS(Int(Date().timeIntervalSince(requestStartedAt) * 1000))
            DebugLog.requestTimeline(timeline)

            await MainActor.run {
                PostResponseCorrectionCoordinator.shared.schedule(
                    seed: correctionSeed,
                    config: config,
                    appSettings: appSettings
                )
            }
        }

        Task {
            do {
                let requestStartedAt = Date()
                let result: RuntimeExecutionResult
                var timeline = RequestTimelineSnapshot(
                    requestId: requestId,
                    threadId: threadId,
                    surface: "chat",
                    inputSource: isVoiceMessage ? "audio" : "text",
                    startedAt: requestStartedAt
                )
                var finalizedVoiceSession: HostedChunkedAudioSession?
                if isVoiceMessage {
                    pendingScreenshotJPEGData = if !reusableContextScreenshotData.isEmpty {
                        reusableContextScreenshotData
                    } else {
                        await screenshotDataForCurrentTurn(
                            existing: pendingScreenshotJPEGData,
                            requireFresh: false
                        )
                    }
                } else if !conversationHistory.isEmpty {
                    pendingScreenshotJPEGData = if !reusableContextScreenshotData.isEmpty {
                        reusableContextScreenshotData
                    } else {
                        await screenshotDataForCurrentTurn(
                            existing: pendingScreenshotJPEGData,
                            requireFresh: true
                        )
                    }
                }
                if let voiceSession = capturedHostedVoiceSession {
                    finalizedVoiceSession = voiceSession
                    voiceSession.updateReplayContext(mode: mode, threadId: threadId)
                    if recordingService.isRecording {
                        let audioCaptureStartedAt = Date()
                        let kept = try await voiceSession.stopRecordingDiscardingIfShorterThan(minimumVoiceMessageDuration)
                        timeline = timeline.addingStage(
                            .audioCaptureFinalize,
                            durationMS: Int(Date().timeIntervalSince(audioCaptureStartedAt) * 1000)
                        )
                        await MainActor.run {
                            appSettings.isRecording = false
                        }
                        if !kept {
                            if trimmed.isEmpty {
                                await MainActor.run {
                                    capturedHostedVoiceSession = nil
                                    isSending = false
                                    chatStore.endRun(threadId: threadId)
                                    appSettings.indicatorState = .idle
                                    errorMessage = "Recording too short."
                                }
                                return
                            }

                            await MainActor.run {
                                capturedHostedVoiceSession = nil
                                chatStore.append(
                                    ChatMessage(
                                        id: optimisticMessageId,
                                        role: .user,
                                        content: placeholder,
                                        style: .text
                                    )
                                )
                                chatStore.beginRun(
                                    threadId: threadId,
                                    mode: mode == .agent ? .agent : .transcript,
                                    optimisticUserMessageId: optimisticMessageId
                                )
                            }
                            let textResult = try await ElsonRuntime.shared.processText(
                                trimmed,
                                requestId: requestId,
                                mode: mode,
                                surface: "chat",
                                threadId: threadId,
                                config: config,
                                clipboardText: clipboardText,
                                attachments: pendingAttachments,
                                screenshotJPEGData: pendingScreenshotJPEGData,
                                conversationHistory: conversationHistory
                            )
                            await finalizeRequest(
                                result: textResult,
                                finalizedVoiceSession: nil,
                                timelineBase: textResult.timeline,
                                requestStartedAt: requestStartedAt,
                                useVoiceMessageStyle: false
                            )
                            return
                        }
                    }

                    let processingProfile = LocalProcessingRouter.contextProfile(for: config, mode: mode)
                    let screenContextTask: Task<(context: LocalScreenContext, durationMS: Int)?, Error>? = processingProfile.shouldPrefetchScreenContext
                        ? Task {
                            try await ElsonRuntime.shared.prefetchShortcutScreenContext(
                                requestId: requestId,
                                surface: "chat",
                                threadId: threadId,
                                mode: mode,
                                config: config,
                                attachments: pendingAttachments,
                                screenshotJPEGData: pendingScreenshotJPEGData
                            )
                        }
                        : nil
                    let groqStartedAt = Date()
                    let audioDraft = try await voiceSession.finalize()
                    timeline = timeline.addingStage(
                        .groqTranscription,
                        durationMS: Int(Date().timeIntervalSince(groqStartedAt) * 1000),
                        countTowardProvider: true
                    )
                    await MainActor.run {
                        chatStore.append(
                            ChatMessage(
                                id: optimisticMessageId,
                                role: .user,
                                content: audioDraft.rawTranscript,
                                style: .voiceTranscript,
                                rawTranscript: audioDraft.rawTranscript,
                                captureSessionId: voiceSession.persistedSessionId
                            )
                        )
                        chatStore.beginRun(
                            threadId: threadId,
                            mode: mode == .agent ? .agent : .transcript,
                            optimisticUserMessageId: optimisticMessageId
                        )
                    }
                    let prefetchedScreenContext = try await screenContextTask?.value
                    if let prefetchedScreenContext {
                        timeline = timeline.addingStage(
                            .screenContext,
                            durationMS: prefetchedScreenContext.durationMS,
                            countTowardProvider: true
                        )
                    }
                    result = try await ElsonRuntime.shared.processAudioTranscriptWithRetry(
                        requestId: requestId,
                        rawTranscript: audioDraft.rawTranscript,
                        snippetCount: audioDraft.snippetCount,
                        transcriptChunkTimings: audioDraft.transcriptChunkTimings,
                        mode: mode,
                        surface: "chat",
                        threadId: threadId,
                        config: config,
                        clipboardText: clipboardText,
                        attachments: pendingAttachments,
                        screenshotJPEGData: pendingScreenshotJPEGData,
                        conversationHistory: conversationHistory,
                        prefetchedDeciderScreenContext: prefetchedScreenContext?.context
                    )
                } else {
                    result = try await ElsonRuntime.shared.processText(
                        trimmed,
                        requestId: requestId,
                        mode: mode,
                        surface: "chat",
                        threadId: threadId,
                        config: config,
                        clipboardText: clipboardText,
                        attachments: pendingAttachments,
                        screenshotJPEGData: pendingScreenshotJPEGData,
                        conversationHistory: conversationHistory
                    )
                }
                await finalizeRequest(
                    result: result,
                    finalizedVoiceSession: finalizedVoiceSession,
                    timelineBase: (isVoiceMessage
                        ? result.timeline
                            .withThreadId(result.responseThreadId ?? threadId)
                            .addingStage(.audioCaptureFinalize, durationMS: timeline.stageDurationsMS[RequestTimelineStage.audioCaptureFinalize.rawValue] ?? 0)
                            .addingStage(.groqTranscription, durationMS: timeline.stageDurationsMS[RequestTimelineStage.groqTranscription.rawValue] ?? 0, countTowardProvider: true)
                            .addingStage(.screenContext, durationMS: timeline.stageDurationsMS[RequestTimelineStage.screenContext.rawValue] ?? 0, countTowardProvider: true)
                        : result.timeline)
                        .withThreadId(result.responseThreadId ?? threadId),
                    requestStartedAt: requestStartedAt,
                    useVoiceMessageStyle: isVoiceMessage
                )
            } catch {
                DebugLog.runtimeError(
                    "thread_window_send_failed thread_id=\(threadId) thread_mode=\(selectedThreadTarget.rawValue) error=\(error.localizedDescription)"
                )
                await MainActor.run {
                    let friendlyErrorMessage = userFacingSendErrorMessage(error.localizedDescription)
                    let noSpeechDetected = isNoSpeechDetectedMessage(friendlyErrorMessage)
                    let failedSessionId = isVoiceMessage ? capturedHostedVoiceSession?.persistedSessionId : nil
                    let archivedRawTranscript = failedSessionId.flatMap {
                        LocalCapturedAudioSessionStore().rawTranscript(sessionId: $0)
                    }
                    if let failedSessionId, !noSpeechDetected {
                        appSettings.recordCaptureFailure(sessionId: failedSessionId, errorMessage: friendlyErrorMessage)
                        let userContent = archivedRawTranscript ?? "Voice message"
                        if chatStore.containsMessage(id: optimisticMessageId) {
                            chatStore.replaceMessage(
                                id: optimisticMessageId,
                                role: .user,
                                style: .voiceTranscript,
                                rawTranscript: archivedRawTranscript,
                                overrideRawTranscript: true,
                                captureSessionId: failedSessionId,
                                overrideCaptureSessionId: true,
                                with: userContent
                            )
                        } else {
                            chatStore.append(
                                ChatMessage(
                                    id: optimisticMessageId,
                                    role: .user,
                                    content: userContent,
                                    style: .voiceTranscript,
                                    rawTranscript: archivedRawTranscript,
                                    captureSessionId: failedSessionId
                                )
                            )
                        }
                    }
                    if noSpeechDetected, chatStore.containsMessage(id: optimisticMessageId) {
                        chatStore.removeMessage(id: optimisticMessageId)
                    }
                    errorMessage = friendlyErrorMessage
                    if capturedHostedVoiceSession?.isStopped != true {
                        capturedHostedVoiceSession = nil
                    } else {
                        draftText = trimmed
                    }
                    isSending = false
                    chatStore.endRun(threadId: threadId)
                    appSettings.indicatorState = noSpeechDetected ? .idle : .error
                    if noSpeechDetected {
                        NotificationHelper.showNotification(
                            title: "Elson.ai",
                            body: friendlyErrorMessage,
                            sound: nil
                        )
                    }
                }
            }
        }
    }

    private func outgoingConversationHistory(limit: Int = 12) -> [ElsonConversationTurnPayload] {
        let turns = chatStore.thread.messages.compactMap { message -> ElsonConversationTurnPayload? in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }

            switch message.role {
            case .user:
                return ElsonConversationTurnPayload(role: .user, content: content)
            case .assistant:
                return ElsonConversationTurnPayload(role: .assistant, content: content)
            case .system:
                return nil
            }
        }

        return Array(turns.suffix(limit))
    }

    private func screenshotDataForCurrentTurn(existing: [Data], requireFresh: Bool) async -> [Data] {
        if !requireFresh, !existing.isEmpty {
            return existing
        }

        guard let captured = try? await captureScreenshotDataIfPossible() else {
            return requireFresh ? [] : existing
        }
        return [captured]
    }

    private func captureScreenshotDataIfPossible(fullScreen: Bool = false) async throws -> Data {
        let maxPixelSize = fullScreen ? 1280 : appSettings.screenshotCaptureMaxPixelSize
        let cropRadius = fullScreen ? nil : appSettings.screenshotCaptureCropAroundMousePixelRadius
        return try await ScreenSnapshotService.shared.captureJPEGDataIfPermitted(
            maxPixelSize: maxPixelSize,
            quality: 0.7,
            cropAroundMousePixelRadius: cropRadius
        )
    }

    private func mapLocalTailMessages(threadId: String) -> [ConversationThreadMessage] {
        guard chatStore.thread.id == threadId else { return [] }
        return chatStore.thread.messages.compactMap { msg in
            let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let insertedText = msg.insertedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty || !insertedText.isEmpty || msg.style == .voiceTranscript else { return nil }
            let role: ConversationThreadMessage.Role
            switch msg.role {
            case .assistant:
                role = .assistant
            case .user:
                role = .user
            case .system:
                return nil
            }
            return ConversationThreadMessage(
                id: msg.id.uuidString,
                role: role,
                content: text,
                createdAt: Date(),
                style: msg.style,
                rawTranscript: msg.rawTranscript,
                insertedText: msg.insertedText,
                attachments: msg.attachments,
                showsAttachmentChip: msg.showsAttachmentChip,
                feedbackSubject: msg.feedbackSubject,
                captureSessionId: msg.captureSessionId
            )
        }
    }

    private func voiceTranscriptText(for message: ConversationThreadMessage) -> String {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty, content != "Voice message...", content != "Voice message" {
            return content
        }
        let rawTranscript = message.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawTranscript.isEmpty {
            return rawTranscript
        }
        return content
    }

    private func userFacingSendErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNoSpeechDetectedMessage(trimmed) || trimmed.lowercased().contains("no usable transcript") {
            return "No speech detected."
        }
        return trimmed
    }

    private func isNoSpeechDetectedMessage(_ message: String) -> Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .contains("no speech detected")
    }

    private func appendToDraft(_ insertedText: String) {
        let trimmed = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftText = trimmed
        } else if draftText.hasSuffix(" ") || draftText.hasSuffix("\n") {
            draftText += trimmed
        } else {
            draftText += " " + trimmed
        }
        isComposerFocused = true
    }

    private func cancelVoiceCaptureIfNeeded() {
        guard recordingService.isRecording || capturedHostedVoiceSession != nil || capturedLocalVoiceSession != nil else { return }
        capturedHostedVoiceSession?.cancel()
        capturedHostedVoiceSession = nil
        capturedLocalVoiceSession?.cancel(reason: "cancelled")
        capturedLocalVoiceSession = nil
        capturedLocalVoiceRun = nil
        appSettings.isRecording = false
        appSettings.indicatorState = .idle
        errorMessage = nil
    }

    private func persistUserAttachmentsIfNeeded(
        result: RuntimeExecutionResult,
        screenshotJPEGData: [Data],
        reusableAttachments: [ChatMessageAttachment],
        threadId: String,
        messageId: UUID
    ) -> [ChatMessageAttachment] {
        if result.actualRoute == AudioDeciderRoute.fullAgent.rawValue, !reusableAttachments.isEmpty {
            return reusableAttachments
        }

        guard result.hasScreenContext,
              !screenshotJPEGData.isEmpty
        else {
            return []
        }

        return screenshotJPEGData.enumerated().compactMap { index, data in
            ThreadAttachmentStore.storeScreenshotJPEG(
                data,
                threadId: threadId,
                messageId: messageId,
                index: index + 1
            )
        }
    }

    private func latestContextAttachments() -> [ChatMessageAttachment] {
        chatStore.thread.messages.reversed().first(where: { !$0.attachments.isEmpty })?.attachments ?? []
    }

    private func latestContextScreenshotData(from attachments: [ChatMessageAttachment]) -> [Data] {
        attachments.compactMap { attachment in
            guard attachment.isImage else { return nil }
            return try? Data(contentsOf: ThreadAttachmentStore.fileURL(for: attachment))
        }
    }

    private func startNewChat() {
        cancelVoiceCaptureIfNeeded()
        draftText = ""
        errorMessage = nil
        expandedVoiceMessageID = nil
        hoveredAssistantMessageID = nil
        previewAttachment = nil
        isSending = false
        chatStore.resetThreadID()
        ThreadModeStore.clear(threadId: chatStore.thread.id)
        pendingThreadTarget = .transcript
        appSettings.pendingScreenshotJPEGData = []
        appSettings.clearAgentAttachments()
        appSettings.indicatorState = .idle
    }
}

private struct ThreadAttachmentPreviewSheet: View {
    let attachment: ChatMessageAttachment

    var body: some View {
        VStack(spacing: 16) {
            Text(attachment.displayName)
                .font(.headline)

            if let image = ThreadAttachmentStore.image(for: attachment) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 760, maxHeight: 520)
            } else {
                Text("Preview unavailable.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
    }
}
