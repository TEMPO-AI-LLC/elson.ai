import Foundation

struct LocalVoiceLatencyContext: Sendable {
    let shortcutDetectedAt: Date?
    let microphonePermissionStartedAt: Date?
    let microphonePermissionGrantedAt: Date?
    let recordingStartedAt: Date?
}

struct LocalVoiceCapturedRun: Sendable {
    let sessionId: String
    let requestId: String
    let threadId: String
    let mode: InteractionMode
    let transcriptAudio: LocalVoiceRecordedFile
    let agentIntentAudio: LocalVoiceRecordedFile?
    let startedAt: Date
    let stoppedAt: Date
    let audioCaptureDurationMS: Int
    let latencyContext: LocalVoiceLatencyContext?

    var isAgentRun: Bool {
        mode == .agent
    }
}

@MainActor
final class LocalVoiceCaptureSession {
    private let store: LocalCapturedAudioSessionStore
    private let recorder: LocalVoiceRecorder
    private(set) var sessionId: String
    private(set) var requestId: String
    private(set) var threadId: String
    private(set) var mode: InteractionMode
    private(set) var startedAt: Date
    private let sourceSurface: String
    private var transcriptAudio: LocalVoiceRecordedFile?
    private var agentIntentAudio: LocalVoiceRecordedFile?

    init(
        sessionId: String = UUID().uuidString,
        requestId: String,
        threadId: String,
        mode: InteractionMode = .transcription,
        sourceSurface: String = "shortcut",
        store: LocalCapturedAudioSessionStore = LocalCapturedAudioSessionStore(),
        recorder: LocalVoiceRecorder = LocalVoiceRecorder()
    ) {
        self.sessionId = sessionId
        self.requestId = requestId
        self.threadId = threadId
        self.mode = mode
        self.startedAt = Date()
        self.sourceSurface = sourceSurface
        self.store = store
        self.recorder = recorder
    }

    var isRecording: Bool {
        recorder.isRecording
    }

    var activeRecordingStartedAt: Date? {
        recorder.activeRecordingStartedAt
    }

    func start() throws {
        try store.createSession(
            sessionId: sessionId,
            createdAt: startedAt,
            requestId: requestId,
            threadId: threadId,
            sourceSurface: sourceSurface,
            mode: mode.rawValue
        )
        _ = try recorder.start(phase: .transcript)
        DebugLog.runtime(
            "local_voice_recording_started request_id=\(requestId) thread_id=\(threadId) session_id=\(sessionId) phase=transcript"
        )
    }

    func activateAgentIntentPhase() throws {
        guard mode != .agent else { return }
        let transcriptFile = try recorder.stop()
        transcriptAudio = try archive(file: transcriptFile)
        mode = .agent
        store.updateContext(sessionId: sessionId, threadId: threadId, mode: InteractionMode.agent.rawValue)
        _ = try recorder.start(phase: .agentIntent)
        DebugLog.runtime(
            "local_voice_agent_phase_started request_id=\(requestId) thread_id=\(threadId) session_id=\(sessionId) transcript_duration_ms=\(durationMS(transcriptFile.duration))"
        )
    }

    func stop(minimumDuration: TimeInterval, latencyContext: LocalVoiceLatencyContext?) throws -> LocalVoiceCapturedRun {
        let stoppedAt = Date()
        if recorder.isRecording {
            let file = try recorder.stop()
            switch file.phase {
            case .transcript:
                transcriptAudio = try archive(file: file)
            case .agentIntent:
                agentIntentAudio = try archive(file: file)
            }
        }

        guard let transcriptAudio else {
            throw LocalVoiceRecorderError.missingAudioFile
        }

        let capturedFiles = [transcriptAudio, agentIntentAudio].compactMap { $0 }
        let totalDuration = capturedFiles.reduce(0) { $0 + $1.duration }
        guard totalDuration >= minimumDuration else {
            store.markStatus(sessionId: sessionId, status: .cancelled, errorMessage: "Recording too short.")
            throw NSError(
                domain: "ai.elson.desktop.local_voice",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Recording too short."]
            )
        }

        _ = try? store.writeAudioWAV(sessionId: sessionId, sourceURLs: capturedFiles.map(\.url))
        store.markStatus(sessionId: sessionId, status: .stopped)
        DebugLog.runtime(
            "local_voice_recording_stopped request_id=\(requestId) thread_id=\(threadId) session_id=\(sessionId) mode=\(mode.rawValue) duration_ms=\(durationMS(totalDuration))"
        )

        return LocalVoiceCapturedRun(
            sessionId: sessionId,
            requestId: requestId,
            threadId: threadId,
            mode: mode,
            transcriptAudio: transcriptAudio,
            agentIntentAudio: agentIntentAudio,
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            audioCaptureDurationMS: durationMS(totalDuration),
            latencyContext: latencyContext
        )
    }

    func cancel(reason: String) {
        recorder.cancel()
        store.markStatus(sessionId: sessionId, status: .cancelled, errorMessage: reason)
        DebugLog.runtime(
            "local_voice_recording_cancelled request_id=\(requestId) thread_id=\(threadId) session_id=\(sessionId) reason=\(reason)"
        )
    }

    private func archive(file: LocalVoiceRecordedFile) throws -> LocalVoiceRecordedFile {
        let archivedURL = try store.stagePhaseAudio(
            sessionId: sessionId,
            phase: file.phase,
            sourceURL: file.url
        )
        return LocalVoiceRecordedFile(
            phase: file.phase,
            url: archivedURL,
            startedAt: file.startedAt,
            stoppedAt: file.stoppedAt
        )
    }

    private func durationMS(_ seconds: TimeInterval) -> Int {
        Int(max(0, seconds) * 1000)
    }
}

private struct LocalVoiceASRDraft {
    let rawTranscript: String
    let transcriptRawText: String
    let agentIntentRawText: String?
    let snippetCount: Int
    let timings: [ElsonTranscriptChunkTimingPayload]
    let firstASRCompletedAt: Date?
}

@MainActor
final class LocalVoiceRunCoordinator {
    static let shared = LocalVoiceRunCoordinator()

    private let store: LocalCapturedAudioSessionStore

    init(store: LocalCapturedAudioSessionStore = LocalCapturedAudioSessionStore()) {
        self.store = store
    }

    func processCapturedRun(
        _ run: LocalVoiceCapturedRun,
        appSettings: AppSettings,
        chatStore: ChatStore,
        config: ElsonLocalConfig,
        pendingAttachments: [AgentAttachment],
        clipboardText: String?,
        screenshotJPEGData: [Data],
        screenshotJPEGDataTask: Task<[Data], Never>? = nil,
        source: String = "shortcut"
    ) {
        Task { @MainActor in
            await process(
                run,
                appSettings: appSettings,
                chatStore: chatStore,
                config: config,
                pendingAttachments: pendingAttachments,
                clipboardText: clipboardText,
                screenshotJPEGData: screenshotJPEGData,
                screenshotJPEGDataTask: screenshotJPEGDataTask,
                source: source
            )
        }
    }

    @discardableResult
    func reprocessCapturedSession(
        sessionId: String,
        appSettings: AppSettings,
        chatStore: ChatStore,
        source: String = "replay"
    ) -> Bool {
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionId.isEmpty else { return false }
        guard let snapshot = store.load(sessionId: trimmedSessionId) else { return false }

        let mode = replayMode(for: snapshot, chatStore: chatStore)
        let threadId = snapshot.threadId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? chatStore.thread.id
        let requestId = UUID().uuidString

        guard let transcriptAudioURL = store.phaseAudioURL(sessionId: trimmedSessionId, phase: .transcript)
            ?? store.audioURL(sessionId: trimmedSessionId)
        else {
            return false
        }

        let now = Date()
        let transcriptFile = LocalVoiceRecordedFile(
            phase: .transcript,
            url: transcriptAudioURL,
            startedAt: snapshot.createdAt,
            stoppedAt: snapshot.createdAt
        )
        let agentIntentFile = store.phaseAudioURL(sessionId: trimmedSessionId, phase: .agentIntent).map {
            LocalVoiceRecordedFile(phase: .agentIntent, url: $0, startedAt: snapshot.createdAt, stoppedAt: snapshot.createdAt)
        }
        let run = LocalVoiceCapturedRun(
            sessionId: trimmedSessionId,
            requestId: requestId,
            threadId: threadId,
            mode: mode,
            transcriptAudio: transcriptFile,
            agentIntentAudio: agentIntentFile,
            startedAt: snapshot.createdAt,
            stoppedAt: now,
            audioCaptureDurationMS: 0,
            latencyContext: nil
        )

        processCapturedRun(
            run,
            appSettings: appSettings,
            chatStore: chatStore,
            config: appSettings.makeLocalConfig(),
            pendingAttachments: [],
            clipboardText: ClipboardHelper.getClipboardContent(),
            screenshotJPEGData: [],
            source: source
        )
        return true
    }

    private func process(
        _ run: LocalVoiceCapturedRun,
        appSettings: AppSettings,
        chatStore: ChatStore,
        config: ElsonLocalConfig,
        pendingAttachments: [AgentAttachment],
        clipboardText: String?,
        screenshotJPEGData: [Data],
        screenshotJPEGDataTask: Task<[Data], Never>?,
        source: String
    ) async {
        let optimisticMessageId = UUID()
        let target: ThreadReplyTarget = run.isAgentRun ? .agent : .transcript
        let processingState: IndicatorState = run.isAgentRun ? .agentProcessing : .processing
        appSettings.indicatorState = processingState
        openThreadIfNeeded(chatStore: chatStore, threadId: run.threadId)
        chatStore.append(
            ChatMessage(
                id: optimisticMessageId,
                role: .user,
                content: "Voice message...",
                style: .voiceTranscript,
                rawTranscript: nil,
                captureSessionId: run.sessionId
            )
        )
        chatStore.beginRun(threadId: run.threadId, mode: target, optimisticUserMessageId: optimisticMessageId)
        NotificationCenter.default.post(name: .openThreadWindow, object: nil)

        DebugLog.runtime(
            "local_voice_processing_started request_id=\(run.requestId) thread_id=\(run.threadId) session_id=\(run.sessionId) mode=\(run.mode.rawValue) source=\(source)"
        )

        var timeline = RequestTimelineSnapshot(
            requestId: run.requestId,
            threadId: run.threadId,
            surface: source,
            inputSource: "audio",
            startedAt: run.stoppedAt
        )
        .addingStage(.audioCaptureFinalize, durationMS: run.audioCaptureDurationMS)

        do {
            store.markStatus(sessionId: run.sessionId, status: .transcribing)
            let asrStartedAt = Date()
            DebugLog.requestStageStart(timeline, stage: .audioTranscription)
            let draft = try await transcribe(run: run, config: config, source: source)
            let asrDurationMS = durationMS(since: asrStartedAt)
            DebugLog.requestStageEnd(timeline, stage: .audioTranscription, durationMS: asrDurationMS)
            timeline = timeline.addingStage(.audioTranscription, durationMS: asrDurationMS, countTowardProvider: true)

            try? store.writeRawTranscript(
                sessionId: run.sessionId,
                rawTranscript: draft.rawTranscript,
                snippetCount: draft.snippetCount,
                transcriptRawText: draft.transcriptRawText,
                agentIntentRawText: draft.agentIntentRawText,
                transcriptChunkTimings: draft.timings,
                status: .ready
            )
            chatStore.replaceMessage(
                id: optimisticMessageId,
                role: .user,
                style: .voiceTranscript,
                rawTranscript: draft.rawTranscript,
                overrideRawTranscript: true,
                captureSessionId: run.sessionId,
                overrideCaptureSessionId: true,
                with: draft.rawTranscript
            )
            DebugLog.requestMilestone(timeline, name: "raw_transcript_visible", metadata: "chars=\(draft.rawTranscript.count)")

            let resolvedScreenshotJPEGData: [Data]
            if run.isAgentRun, let screenshotJPEGDataTask {
                resolvedScreenshotJPEGData = await screenshotJPEGDataTask.value
            } else {
                resolvedScreenshotJPEGData = run.isAgentRun ? screenshotJPEGData : []
            }
            let result = try await ElsonRuntime.shared.processAudioTranscriptWithRetry(
                requestId: run.requestId,
                rawTranscript: draft.rawTranscript,
                transcriptContext: run.isAgentRun ? draft.transcriptRawText : nil,
                agentIntentTranscript: run.isAgentRun ? draft.agentIntentRawText : nil,
                snippetCount: draft.snippetCount,
                transcriptChunkTimings: draft.timings,
                mode: run.mode,
                surface: "shortcut",
                threadId: run.threadId,
                config: config,
                clipboardText: run.isAgentRun ? clipboardText : nil,
                attachments: run.isAgentRun ? pendingAttachments : [],
                screenshotJPEGData: resolvedScreenshotJPEGData,
                prefetchedDeciderScreenContext: run.isAgentRun && !resolvedScreenshotJPEGData.isEmpty
                    ? LocalScreenContext(hasScreenContext: true, screenText: nil, screenDescription: nil)
                    : .none,
                audioLatencyContext: AudioLatencyContext(
                    shortcutDetectedAt: run.latencyContext?.shortcutDetectedAt,
                    microphonePermissionStartedAt: run.latencyContext?.microphonePermissionStartedAt,
                    microphonePermissionGrantedAt: run.latencyContext?.microphonePermissionGrantedAt,
                    recordingStartedAt: run.latencyContext?.recordingStartedAt,
                    recordingStoppedAt: run.stoppedAt,
                    firstChunkTranscriptionCompletedAt: draft.firstASRCompletedAt
                )
            )

            let desktopActionsStartedAt = Date()
            let actionNotes = await DesktopActionExecutor.execute(result.actions, appSettings: appSettings)
            let desktopActionsDurationMS = durationMS(since: desktopActionsStartedAt)
            if !actionNotes.isEmpty {
                print(actionNotes.joined(separator: " "))
            }
            timeline = result.timeline
                .withThreadId(result.responseThreadId ?? run.threadId)
                .addingStage(.audioCaptureFinalize, durationMS: run.audioCaptureDurationMS)
                .addingStage(.audioTranscription, durationMS: asrDurationMS, countTowardProvider: true)
                .addingStage(.desktopActions, durationMS: desktopActionsDurationMS)

            commitSuccess(
                run: run,
                optimisticMessageId: optimisticMessageId,
                draft: draft,
                result: result,
                screenshotJPEGData: resolvedScreenshotJPEGData,
                timeline: timeline,
                appSettings: appSettings,
                chatStore: chatStore,
                source: source
            )
        } catch {
            handleFailure(
                error: error,
                run: run,
                optimisticMessageId: optimisticMessageId,
                appSettings: appSettings,
                chatStore: chatStore
            )
        }
    }

    private func transcribe(
        run: LocalVoiceCapturedRun,
        config: ElsonLocalConfig,
        source: String
    ) async throws -> LocalVoiceASRDraft {
        let transcript = try await transcribePhase(
            file: run.transcriptAudio,
            run: run,
            config: config,
            source: source
        )
        let intent: LocalTranscriptionResult?
        if let agentIntentAudio = run.agentIntentAudio {
            do {
                intent = try await transcribePhase(file: agentIntentAudio, run: run, config: config, source: source)
            } catch {
                if isNoSpeechDetectedMessage(error.localizedDescription) {
                    intent = nil
                } else {
                    throw error
                }
            }
        } else {
            intent = nil
        }

        let transcriptText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let intentText = intent?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTranscript: String = if let intentText, !intentText.isEmpty {
            [transcriptText, intentText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        } else {
            transcriptText
        }
        guard !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.noSpeechDetected
        }

        let timings = makeTimings(run: run, transcriptText: transcriptText, intentText: intentText)
        return LocalVoiceASRDraft(
            rawTranscript: rawTranscript,
            transcriptRawText: transcriptText,
            agentIntentRawText: intentText,
            snippetCount: [transcriptText, intentText].filter { ($0 ?? "").isEmpty == false }.count,
            timings: timings,
            firstASRCompletedAt: Date()
        )
    }

    private func transcribePhase(
        file: LocalVoiceRecordedFile,
        run: LocalVoiceCapturedRun,
        config: ElsonLocalConfig,
        source: String
    ) async throws -> LocalTranscriptionResult {
        try await LocalProcessingRouter.transcribeDetailed(
            audioURL: file.url,
            config: config,
            logContext: LocalRequestLogContext(
                requestId: run.requestId,
                threadId: run.threadId,
                surface: source,
                inputSource: "audio"
            ),
            extraMetadata: "local_voice_session_id=\(run.sessionId) phase=\(file.phase.rawValue)"
        )
    }

    private func makeTimings(
        run: LocalVoiceCapturedRun,
        transcriptText: String,
        intentText: String?
    ) -> [ElsonTranscriptChunkTimingPayload] {
        var items: [ElsonTranscriptChunkTimingPayload] = []
        var audioStart = 0.0
        var transcriptSnippetIndex = 0

        func append(file: LocalVoiceRecordedFile, text: String?) {
            let duration = max(0, file.duration)
            let hasText = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            items.append(
                ElsonTranscriptChunkTimingPayload(
                    index: items.count,
                    phase: file.phase.rawValue,
                    transcriptSnippetIndex: hasText ? transcriptSnippetIndex : nil,
                    audioStartSeconds: audioStart,
                    audioEndSeconds: audioStart + duration,
                    asrPayloadStartSeconds: audioStart,
                    asrPayloadEndSeconds: audioStart + duration,
                    overlapStartSeconds: nil,
                    overlapEndSeconds: nil,
                    overlapDurationSeconds: 0,
                    keptTranscriptStartSeconds: audioStart,
                    keptTranscriptEndSeconds: audioStart + duration
                )
            )
            if hasText {
                transcriptSnippetIndex += 1
            }
            audioStart += duration
        }

        append(file: run.transcriptAudio, text: transcriptText)
        if let agentIntentAudio = run.agentIntentAudio {
            append(file: agentIntentAudio, text: intentText)
        }
        return items
    }

    private func commitSuccess(
        run: LocalVoiceCapturedRun,
        optimisticMessageId: UUID,
        draft: LocalVoiceASRDraft,
        result: RuntimeExecutionResult,
        screenshotJPEGData: [Data],
        timeline: RequestTimelineSnapshot,
        appSettings: AppSettings,
        chatStore: ChatStore,
        source: String
    ) {
        let effectiveThreadId = result.responseThreadId ?? run.threadId
        let assistantMessageId = UUID()
        if effectiveThreadId != run.threadId {
            chatStore.adoptThreadIdPreservingMessages(newId: effectiveThreadId)
        }
        let userAttachments = persistUserAttachmentsIfNeeded(
            result: result,
            screenshotJPEGData: screenshotJPEGData,
            threadId: effectiveThreadId,
            messageId: optimisticMessageId
        )
        chatStore.replaceMessage(
            id: optimisticMessageId,
            role: .user,
            style: .voiceTranscript,
            rawTranscript: result.rawTranscript ?? draft.rawTranscript,
            overrideRawTranscript: true,
            captureSessionId: run.sessionId,
            overrideCaptureSessionId: true,
            attachments: userAttachments,
            showsAttachmentChip: !userAttachments.isEmpty,
            with: result.transcript.isEmpty ? draft.rawTranscript : result.transcript
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
        chatStore.endRun(threadId: run.threadId)
        if run.isAgentRun {
            chatStore.noteConversationActivity(
                threadId: effectiveThreadId,
                lastMessage: result.replyText,
                lastRole: "assistant",
                lastReplyTarget: result.replyMode,
                sessionKey: result.sessionKey,
                markUnread: false
            )
        }

        appSettings.recordLastOutput(from: result, captureSessionId: run.sessionId)
        if !result.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appSettings.appendTranscriptHistory(
                text: result.replyText,
                rawTranscript: result.rawTranscript,
                source: source,
                threadId: effectiveThreadId,
                replyMode: result.replyMode,
                actualRoute: result.actualRoute,
                routingSource: result.routingSource,
                forcedRouteReason: result.forcedRouteReason,
                requestId: result.requestId,
                captureSessionId: run.sessionId
            )
        }
        _ = ClipboardHelper.deliverTranscriptDetailed(
            result.clipboardText,
            behavior: appSettings.transcriptClipboardBehavior()
        )
        appSettings.indicatorState = run.isAgentRun ? .agentSuccess : .success
        appSettings.clearAgentAttachments()
        appSettings.pendingScreenshotJPEGData = []
        if let updatedMyElsonMarkdown = result.updatedMyElsonMarkdown {
            appSettings.applyAgentMyElsonMarkdownUpdate(updatedMyElsonMarkdown)
        }
        store.markStatus(sessionId: run.sessionId, status: .delivered)
        appSettings.refreshCapturedAudioSessions()
        DebugLog.requestTimeline(timeline)
        DebugLog.runtime(
            "local_voice_processing_completed request_id=\(run.requestId) thread_id=\(effectiveThreadId) session_id=\(run.sessionId) mode=\(run.mode.rawValue)"
        )
        PostResponseCorrectionCoordinator.shared.schedule(
            seed: result.postResponseCorrectionSeed,
            config: appSettings.makeLocalConfig(),
            appSettings: appSettings
        )
    }

    private func handleFailure(
        error: Error,
        run: LocalVoiceCapturedRun,
        optimisticMessageId: UUID,
        appSettings: AppSettings,
        chatStore: ChatStore
    ) {
        let friendlyMessage = userFacingErrorMessage(error.localizedDescription)
        let noSpeechDetected = isNoSpeechDetectedMessage(friendlyMessage)
        let archivedRawTranscript = store.rawTranscript(sessionId: run.sessionId)
        if noSpeechDetected {
            chatStore.removeMessage(id: optimisticMessageId)
            store.markStatus(sessionId: run.sessionId, status: .cancelled, errorMessage: friendlyMessage)
            appSettings.indicatorState = .idle
        } else {
            chatStore.replaceMessage(
                id: optimisticMessageId,
                role: .user,
                style: .voiceTranscript,
                rawTranscript: archivedRawTranscript,
                overrideRawTranscript: true,
                captureSessionId: run.sessionId,
                overrideCaptureSessionId: true,
                with: archivedRawTranscript ?? "Voice message..."
            )
            chatStore.append(ChatMessage(role: .assistant, content: friendlyMessage))
            _ = appSettings.recordCaptureFailure(sessionId: run.sessionId, errorMessage: friendlyMessage)
            appSettings.indicatorState = .error
        }
        chatStore.endRun(threadId: run.threadId)
        NotificationHelper.showNotification(
            title: "Elson.ai",
            body: friendlyMessage,
            sound: noSpeechDetected ? nil : .default
        )
        DebugLog.runtimeError(
            "local_voice_processing_failed request_id=\(run.requestId) thread_id=\(run.threadId) session_id=\(run.sessionId) mode=\(run.mode.rawValue) error=\(error.localizedDescription)"
        )
    }

    private func openThreadIfNeeded(chatStore: ChatStore, threadId: String) {
        guard chatStore.thread.id != threadId else { return }
        chatStore.openPersistedThread(id: threadId)
    }

    private func replayMode(for snapshot: LocalCapturedAudioSessionSnapshot, chatStore: ChatStore) -> InteractionMode {
        let rawMode = snapshot.mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if rawMode == InteractionMode.agent.rawValue {
            return .agent
        }
        if rawMode == InteractionMode.transcription.rawValue || rawMode == "transcript" {
            return .transcription
        }
        let threadId = snapshot.threadId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? chatStore.thread.id
        return ThreadModeStore.get(threadId: threadId) == .agent ? .agent : .transcription
    }

    private func persistUserAttachmentsIfNeeded(
        result: RuntimeExecutionResult,
        screenshotJPEGData: [Data],
        threadId: String,
        messageId: UUID
    ) -> [ChatMessageAttachment] {
        guard result.sourceSurface == "shortcut",
              result.hasScreenContext,
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

    private func userFacingErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if isNoSpeechDetectedMessage(trimmed) || lowercased.contains("no usable transcript") {
            return "No speech detected."
        }
        if trimmed.hasPrefix("Error:") {
            return trimmed
        }
        return "Error: \(trimmed)"
    }

    private func isNoSpeechDetectedMessage(_ message: String) -> Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .contains("no speech detected")
    }

    private func durationMS(since startedAt: Date) -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1000)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
