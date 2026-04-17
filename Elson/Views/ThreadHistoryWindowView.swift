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
    @State private var capturedVoiceSession: LocalChunkedAudioSession? = nil
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
        let canSend = !isSending
            && selectedThreadTarget != nil
            && (!trimmedDraft.isEmpty || recordingService.isRecording || capturedVoiceSession != nil)
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
            onNewChat: startNewChat
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
            capturedVoiceSession: capturedVoiceSession,
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
            onSubmitFeedback: { message, rating, routeOverride, note in
                guard let subject = message.feedbackSubject else { return }
                Task { @MainActor in
                    _ = await appSettings.submitFeedback(
                        subject: subject,
                        rating: rating,
                        note: note,
                        routeOverride: routeOverride
                    )
                }
            }
        )
    }

    private func toggleVoiceCapture() {
        if recordingService.isRecording {
            guard let session = capturedVoiceSession else {
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
                        capturedVoiceSession = nil
                        errorMessage = "Recording too short."
                    }
                } catch {
                    capturedVoiceSession = nil
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

            capturedVoiceSession = nil
            let session = LocalChunkedAudioSession(
                recordingService: recordingService,
                groqAPIKey: appSettings.makeLocalConfig().groqAPIKey,
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

            capturedVoiceSession = session
            appSettings.pendingScreenshotJPEGData = []
            appSettings.indicatorState = .listening
            appSettings.isRecording = true
            errorMessage = nil

            Task {
                guard let captured = try? await captureScreenshotDataIfPossible() else { return }
                await MainActor.run {
                    guard capturedVoiceSession === session else { return }
                    appSettings.pendingScreenshotJPEGData = [captured]
                }
            }
        }
    }

    private func sendMessage() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadId = chatStore.thread.id
        guard !isSending else { return }
        guard !trimmed.isEmpty || capturedVoiceSession != nil || recordingService.isRecording else { return }

        let isVoiceMessage = recordingService.isRecording || capturedVoiceSession != nil

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
        let requestId = capturedVoiceSession?.requestId ?? UUID().uuidString
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
            finalizedVoiceSession: LocalChunkedAudioSession?,
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
                finalizedVoiceSession?.markDeliveryCompleted()
                chatStore.replaceMessage(
                    id: optimisticMessageId,
                    role: .user,
                    style: useVoiceMessageStyle ? .voiceTranscript : .text,
                    rawTranscript: useVoiceMessageStyle ? result.rawTranscript : nil,
                    overrideRawTranscript: useVoiceMessageStyle,
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
                capturedVoiceSession = nil
                isSending = false
                appSettings.recordLastOutput(from: result)
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
                        requestId: result.requestId
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
                var finalizedVoiceSession: LocalChunkedAudioSession?
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
                if let voiceSession = capturedVoiceSession {
                    finalizedVoiceSession = voiceSession
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
                                    capturedVoiceSession = nil
                                    isSending = false
                                    chatStore.endRun(threadId: threadId)
                                    appSettings.indicatorState = .idle
                                    errorMessage = "Recording too short."
                                }
                                return
                            }

                            await MainActor.run {
                                capturedVoiceSession = nil
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

                    let screenContextTask = Task {
                        try await ElsonRuntime.shared.prefetchShortcutScreenContext(
                            requestId: requestId,
                            surface: "chat",
                            threadId: threadId,
                            config: config,
                            attachments: pendingAttachments,
                            screenshotJPEGData: pendingScreenshotJPEGData
                        )
                    }
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
                                content: placeholder,
                                style: .voiceTranscript,
                                rawTranscript: audioDraft.rawTranscript
                            )
                        )
                        chatStore.beginRun(
                            threadId: threadId,
                            mode: mode == .agent ? .agent : .transcript,
                            optimisticUserMessageId: optimisticMessageId
                        )
                    }
                    let prefetchedScreenContext = try await screenContextTask.value
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
                    errorMessage = error.localizedDescription
                    if capturedVoiceSession?.isStopped != true {
                        capturedVoiceSession = nil
                    } else {
                        draftText = trimmed
                    }
                    isSending = false
                    chatStore.endRun(threadId: threadId)
                    appSettings.indicatorState = .error
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

    private func captureScreenshotDataIfPossible() async throws -> Data {
        try await ScreenSnapshotService.shared.captureJPEGDataIfPermitted(maxPixelSize: 1280, quality: 0.7)
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
                feedbackSubject: msg.feedbackSubject
            )
        }
    }

    private func voiceTranscriptText(for message: ConversationThreadMessage) -> String {
        let rawTranscript = message.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawTranscript.isEmpty {
            return rawTranscript
        }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard recordingService.isRecording || capturedVoiceSession != nil else { return }
        capturedVoiceSession?.cancel()
        capturedVoiceSession = nil
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
