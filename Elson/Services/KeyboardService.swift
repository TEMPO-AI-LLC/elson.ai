import AppKit
import Carbon
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class KeyboardService {
    private struct ShortcutLatencyState {
        let requestId: String
        let shortcutDetectedAt: Date
        let microphonePermissionStartedAt: Date
        let microphonePermissionGrantedAt: Date
        let recordingStartedAt: Date?
    }

    private enum ShortcutDestination {
        case runtime(mode: InteractionMode, threadId: String)
        case threadComposer(threadId: String)

        var threadId: String {
            switch self {
            case let .runtime(_, threadId), let .threadComposer(threadId):
                return threadId
            }
        }
    }

    @ObservationIgnored private let minimumShortcutRecordingDuration: TimeInterval = 1
    @ObservationIgnored private var appSettings: AppSettings?
    @ObservationIgnored private var recordingService: AudioRecordingService?
    @ObservationIgnored private var chatStore: ChatStore?
    @ObservationIgnored private var keyMonitorTimer: Timer?
    @ObservationIgnored private var localKeyDownMonitor: Any?
    @ObservationIgnored private var globalKeyDownMonitor: Any?

    @ObservationIgnored private var lastTranscriptShortcutActive = false
    @ObservationIgnored private var lastAgentShortcutActive = false
    @ObservationIgnored private var armedToggleStop = false
    @ObservationIgnored private var activeRecordingShortcut: RecordingShortcut? = nil
    @ObservationIgnored private var activeShortcutDestination: ShortcutDestination? = nil
    @ObservationIgnored private var activeChunkedSession: LocalChunkedAudioSession? = nil
    @ObservationIgnored private var activeShortcutThreadId: String? = nil
    @ObservationIgnored private var activeShortcutPreviousThreadId: String? = nil
    @ObservationIgnored private var activeShortcutLatencyState: ShortcutLatencyState? = nil
    @ObservationIgnored private var shortcutRunScreenshotJPEGData: [Data] = []
    @ObservationIgnored private var shortcutDeliveryInFlight = false
    @ObservationIgnored private var shortcutScreenContextPrefetchTask: Task<(context: LocalScreenContext, durationMS: Int)?, Never>?

    func setup(with appSettings: AppSettings, recordingService: AudioRecordingService, chatStore: ChatStore) {
        self.appSettings = appSettings
        self.recordingService = recordingService
        self.chatStore = chatStore
        startModifierKeyMonitoring()
        installKeyDownMonitors()
    }

    private func startModifierKeyMonitoring() {
        keyMonitorTimer?.invalidate()
        keyMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollShortcutState()
            }
        }
    }

    private func pollShortcutState() {
        guard let appSettings, let recordingService, let chatStore else { return }
        guard !appSettings.needsInstallOnboarding else {
            lastTranscriptShortcutActive = false
            lastAgentShortcutActive = false
            armedToggleStop = false
            return
        }
        guard !appSettings.hasShortcutConflict else {
            lastTranscriptShortcutActive = false
            lastAgentShortcutActive = false
            armedToggleStop = false
            return
        }

        let transcriptShortcutActive = isShortcutActive(appSettings.transcriptShortcut)
        let agentShortcutActive = isShortcutActive(appSettings.agentShortcut)
        let triggeredMode: InteractionMode? = {
            if transcriptShortcutActive, !agentShortcutActive { return .transcription }
            if agentShortcutActive, !transcriptShortcutActive { return .agent }
            return nil
        }()
        let triggeredShortcut: RecordingShortcut? = {
            if transcriptShortcutActive, !agentShortcutActive { return appSettings.transcriptShortcut }
            if agentShortcutActive, !transcriptShortcutActive { return appSettings.agentShortcut }
            return nil
        }()

        switch appSettings.listeningMode {
        case .hold:
            handleHoldMode(
                transcriptShortcutActive: transcriptShortcutActive,
                agentShortcutActive: agentShortcutActive,
                mode: triggeredMode,
                shortcut: triggeredShortcut,
                appSettings: appSettings,
                recordingService: recordingService,
                chatStore: chatStore
            )
        case .toggle:
            handleToggleMode(
                transcriptShortcutActive: transcriptShortcutActive,
                agentShortcutActive: agentShortcutActive,
                mode: triggeredMode,
                shortcut: triggeredShortcut,
                appSettings: appSettings,
                recordingService: recordingService,
                chatStore: chatStore
            )
        }

        lastTranscriptShortcutActive = transcriptShortcutActive
        lastAgentShortcutActive = agentShortcutActive
    }

    private func installKeyDownMonitors() {
        guard localKeyDownMonitor == nil, globalKeyDownMonitor == nil else { return }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleGlobalEscape(event) {
                return nil
            }
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            _ = self.handleGlobalEscape(event)
        }
    }

    private func handleGlobalEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        guard activeChunkedSession != nil else { return false }

        Task { @MainActor [weak self] in
            await self?.cancelActiveShortcutRecording(reason: "escape")
        }
        return true
    }

    private func isShortcutActive(_ shortcut: RecordingShortcut) -> Bool {
        let modifiers = GetCurrentKeyModifiers()
        guard shortcut.matches(carbonModifiers: modifiers) else { return false }

        // Some keyboards set the fn modifier bit for navigation keys.
        // Treat fn shortcuts as active only when the physical fn key is actually down.
        if shortcut.modifiers.contains(.function), !isFunctionKeyPhysicallyPressed() {
            return false
        }

        // On some Apple keyboards the cursor/navigation cluster can surface the fn modifier bit
        // while arrow keys are pressed. That should never trigger Elson's default fn shortcut.
        if shortcut == .default, isNavigationClusterActive() {
            return false
        }

        return true
    }

    private func isActiveRecordingShortcutStillPressed(appSettings: AppSettings) -> Bool {
        guard let activeRecordingShortcut else { return false }
        if activeRecordingShortcut == appSettings.transcriptShortcut {
            return isShortcutActive(appSettings.transcriptShortcut)
        }
        if activeRecordingShortcut == appSettings.agentShortcut {
            return isShortcutActive(appSettings.agentShortcut)
        }
        return isShortcutActive(activeRecordingShortcut)
    }

    private func isNavigationClusterActive() -> Bool {
        let navigationKeyCodes: [CGKeyCode] = [
            CGKeyCode(kVK_LeftArrow),
            CGKeyCode(kVK_RightArrow),
            CGKeyCode(kVK_UpArrow),
            CGKeyCode(kVK_DownArrow),
            CGKeyCode(kVK_Home),
            CGKeyCode(kVK_End),
            CGKeyCode(kVK_PageUp),
            CGKeyCode(kVK_PageDown),
            CGKeyCode(kVK_ForwardDelete)
        ]

        return navigationKeyCodes.contains { keyCode in
            CGEventSource.keyState(.combinedSessionState, key: keyCode)
        }
    }

    private func isFunctionKeyPhysicallyPressed() -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Function))
    }

    private func handleHoldMode(
        transcriptShortcutActive: Bool,
        agentShortcutActive: Bool,
        mode: InteractionMode?,
        shortcut: RecordingShortcut?,
        appSettings: AppSettings,
        recordingService: AudioRecordingService,
        chatStore: ChatStore
    ) {
        let anyShortcutJustActivated =
            (transcriptShortcutActive && !lastTranscriptShortcutActive)
            || (agentShortcutActive && !lastAgentShortcutActive)

        if anyShortcutJustActivated, let mode, let shortcut {
            beginShortcutRecording(
                mode: mode,
                shortcut: shortcut,
                triggeredAt: Date(),
                appSettings: appSettings,
                recordingService: recordingService,
                chatStore: chatStore
            )
        } else if recordingService.isRecording, !isActiveRecordingShortcutStillPressed(appSettings: appSettings) {
            finishShortcutRecording(appSettings: appSettings, recordingService: recordingService, chatStore: chatStore)
        }
    }

    private func handleToggleMode(
        transcriptShortcutActive: Bool,
        agentShortcutActive: Bool,
        mode: InteractionMode?,
        shortcut: RecordingShortcut?,
        appSettings: AppSettings,
        recordingService: AudioRecordingService,
        chatStore: ChatStore
    ) {
        let anyShortcutJustActivated =
            (transcriptShortcutActive && !lastTranscriptShortcutActive)
            || (agentShortcutActive && !lastAgentShortcutActive)

        guard anyShortcutJustActivated, let mode, let shortcut else {
            if !transcriptShortcutActive, !agentShortcutActive {
                armedToggleStop = false
            }
            return
        }

        if recordingService.isRecording {
            armedToggleStop = true
            finishShortcutRecording(appSettings: appSettings, recordingService: recordingService, chatStore: chatStore)
            return
        }

        beginShortcutRecording(
            mode: mode,
            shortcut: shortcut,
            triggeredAt: Date(),
            appSettings: appSettings,
            recordingService: recordingService,
            chatStore: chatStore
        )
    }

    private func beginShortcutRecording(
        mode: InteractionMode,
        shortcut: RecordingShortcut,
        triggeredAt: Date,
        appSettings: AppSettings,
        recordingService: AudioRecordingService,
        chatStore: ChatStore
    ) {
        guard !recordingService.isRecording else { return }
        guard !shortcutDeliveryInFlight else {
            DebugLog.runtime("shortcut_recording_start_ignored reason=delivery_in_flight")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.shortcutDeliveryInFlight else {
                DebugLog.runtime("shortcut_recording_start_ignored reason=delivery_in_flight_after_permission")
                return
            }

            let requestId = UUID().uuidString
            let destination = self.shortcutDestination(mode: mode, chatStore: chatStore)
            let targetThreadId = destination.threadId
            let milestoneSnapshot = RequestTimelineSnapshot(
                requestId: requestId,
                threadId: targetThreadId,
                surface: "shortcut",
                inputSource: "audio"
            )
            let microphonePermissionStartedAt = Date()
            DebugLog.requestMilestone(milestoneSnapshot, name: "shortcut_detected")
            DebugLog.requestMilestone(milestoneSnapshot, name: "microphone_permission_started")

            do {
                try await PermissionCoordinator.ensureMicrophonePermission()
            } catch {
                self.presentShortcutStartFailure(
                    error.localizedDescription,
                    appSettings: appSettings,
                    chatStore: chatStore
                )
                return
            }
            let microphonePermissionGrantedAt = Date()
            DebugLog.requestMilestone(milestoneSnapshot, name: "microphone_permission_granted")

            if appSettings.listeningMode == .hold, !self.isShortcutActive(shortcut) {
                return
            }

            self.activeChunkedSession = nil
            self.shortcutScreenContextPrefetchTask?.cancel()
            self.shortcutScreenContextPrefetchTask = nil
            let session = LocalChunkedAudioSession(
                recordingService: recordingService,
                groqAPIKey: appSettings.makeLocalConfig().groqAPIKey,
                requestLogContext: LocalRequestLogContext(
                    requestId: requestId,
                    threadId: targetThreadId,
                    surface: "shortcut",
                    inputSource: "audio"
                )
            )
            guard session.start() else {
                self.presentShortcutStartFailure(
                    "Failed to start microphone recording. Check System Settings > Privacy & Security > Microphone.",
                    appSettings: appSettings,
                    chatStore: chatStore
                )
                return
            }

            self.activeShortcutDestination = destination
            self.activeRecordingShortcut = shortcut
            self.activeChunkedSession = session
            self.shortcutRunScreenshotJPEGData = []
            appSettings.isRecording = true
            appSettings.indicatorState = .listening
            NotificationCenter.default.post(name: .bringBubbleToFront, object: nil)

            self.activeShortcutThreadId = targetThreadId
            self.activeShortcutLatencyState = ShortcutLatencyState(
                requestId: requestId,
                shortcutDetectedAt: triggeredAt,
                microphonePermissionStartedAt: microphonePermissionStartedAt,
                microphonePermissionGrantedAt: microphonePermissionGrantedAt,
                recordingStartedAt: recordingService.activeRecordingStartedAt ?? Date()
            )
            if case .runtime(let runtimeMode, let threadId) = destination {
                self.activeShortcutPreviousThreadId = chatStore.thread.id
                chatStore.setThread(id: threadId, messages: [])
                ThreadModeStore.set(threadId: threadId, target: runtimeMode == .agent ? .agent : .transcript)
            } else {
                self.activeShortcutPreviousThreadId = nil
            }
            DebugLog.requestMilestone(milestoneSnapshot, name: "recording_started")

            if case .runtime = destination, ScreenSnapshotService.shared.hasPermission() {
                Task { [weak self] in
                    guard let self else { return }
                    guard let captured = try? await self.captureScreenshotDataIfPossible() else { return }
                    await MainActor.run {
                        guard self.activeChunkedSession === session else { return }
                        self.shortcutRunScreenshotJPEGData = [captured]
                        self.startShortcutScreenContextPrefetch(
                            requestId: session.requestId ?? UUID().uuidString,
                            threadId: targetThreadId,
                            config: appSettings.makeLocalConfig(),
                            attachments: appSettings.pendingAttachments,
                            screenshotData: [captured]
                        )
                    }
                }
            }
        }
    }

    private func presentShortcutStartFailure(_ message: String, appSettings: AppSettings, chatStore: ChatStore) {
        let friendlyMessage = userFacingShortcutErrorMessage(message)
        appSettings.indicatorState = .error
        chatStore.append(ChatMessage(role: .assistant, content: friendlyMessage))
        NotificationHelper.showNotification(
            title: "Elson.ai",
            body: friendlyMessage,
            sound: .default
        )
    }

    private func finishShortcutRecording(appSettings: AppSettings, recordingService: AudioRecordingService, chatStore: ChatStore) {
        guard let destination = activeShortcutDestination else { return }
        guard let session = activeChunkedSession else {
            appSettings.isRecording = false
            activeShortcutDestination = nil
            activeRecordingShortcut = nil
            activeShortcutLatencyState = nil
            shortcutRunScreenshotJPEGData = []
            appSettings.indicatorState = .error
            NotificationHelper.showNotification(
                title: "Elson.ai",
                body: "Error: missing audio session.",
                sound: .default
            )
            return
        }
        appSettings.isRecording = false
        activeShortcutDestination = nil
        activeRecordingShortcut = nil
        shortcutDeliveryInFlight = true

        let threadId = destination.threadId
        let optimisticMessageId = UUID()
        let config = appSettings.makeLocalConfig()
        let pendingAttachments = appSettings.pendingAttachments
        let clipboardText = ClipboardHelper.getClipboardContent()
        let latencyState = activeShortcutLatencyState
        let runtimeMode: InteractionMode? = {
            guard case let .runtime(mode, _) = destination else { return nil }
            return mode
        }()
        let optimisticTarget: ThreadReplyTarget = {
            switch destination {
            case let .runtime(mode, _):
                return mode == .agent ? .agent : .transcript
            case .threadComposer:
                return .transcript
            }
        }()
        let processingState: IndicatorState = {
            switch destination {
            case let .runtime(mode, _):
                return mode == .agent ? .agentProcessing : .processing
            case .threadComposer:
                return .processing
            }
        }()
        appSettings.indicatorState = processingState

        Task {
            do {
                let requestId = session.requestId ?? UUID().uuidString
                let requestStartedAt = Date()
                var timeline = RequestTimelineSnapshot(
                    requestId: requestId,
                    threadId: threadId,
                    surface: "shortcut",
                    inputSource: "audio",
                    startedAt: requestStartedAt
                )

                let audioCaptureStartedAt = Date()
                let kept = try await session.stopRecordingDiscardingIfShorterThan(minimumShortcutRecordingDuration)
                let audioCaptureDurationMS = Int(Date().timeIntervalSince(audioCaptureStartedAt) * 1000)
                timeline = timeline.addingStage(.audioCaptureFinalize, durationMS: audioCaptureDurationMS)
                guard kept else {
                    await MainActor.run {
                        self.activeChunkedSession = nil
                        self.activeShortcutThreadId = nil
                        self.restorePriorThreadIfNeeded(chatStore: chatStore)
                        self.activeRecordingShortcut = nil
                        self.activeShortcutLatencyState = nil
                        self.shortcutRunScreenshotJPEGData = []
                        self.shortcutScreenContextPrefetchTask?.cancel()
                        self.shortcutScreenContextPrefetchTask = nil
                        self.shortcutDeliveryInFlight = false
                        appSettings.indicatorState = .idle
                        NotificationHelper.showNotification(
                            title: "Elson.ai",
                            body: "Recording too short.",
                            sound: nil
                        )
                    }
                    return
                }

                if case let .threadComposer(targetThreadId) = destination {
                    let audioDraft = try await session.finalize()
                    let formattedText = try await ElsonRuntime.shared.formatRawTranscriptForChatComposer(
                        requestId: requestId,
                        rawTranscript: audioDraft.rawTranscript,
                        threadId: targetThreadId,
                        config: config,
                        conversationHistory: conversationHistoryPayload(from: chatStore.thread.messages)
                    )
                    await MainActor.run {
                        session.markDeliveryCompleted()
                        self.activeChunkedSession = nil
                        self.activeShortcutThreadId = nil
                        self.activeShortcutPreviousThreadId = nil
                        self.activeRecordingShortcut = nil
                        self.activeShortcutLatencyState = nil
                        self.shortcutRunScreenshotJPEGData = []
                        self.shortcutScreenContextPrefetchTask = nil
                        self.shortcutDeliveryInFlight = false
                        appSettings.indicatorState = .success
                        NotificationCenter.default.post(name: .insertTextIntoThreadComposer, object: formattedText)
                    }
                    return
                }

                let screenContextTask = Task<([Data], (context: LocalScreenContext, durationMS: Int)?), Error> {
                    var screenshotData = shortcutRunScreenshotJPEGData
                    if screenshotData.isEmpty, let captured = try? await captureScreenshotDataIfPossible() {
                        screenshotData = [captured]
                    }
                    if let prefetched = await shortcutScreenContextPrefetchTask?.value {
                        return (screenshotData, prefetched)
                    }
                    let prefetched = try await ElsonRuntime.shared.prefetchAudioDeciderScreenContext(
                        requestId: requestId,
                        surface: "shortcut",
                        threadId: threadId,
                        config: config,
                        attachments: pendingAttachments,
                        screenshotJPEGData: screenshotData
                    )
                    return (screenshotData, prefetched)
                }

                let groqStartedAt = Date()
                let audioDraft = try await session.finalize()
                let groqDurationMS = Int(Date().timeIntervalSince(groqStartedAt) * 1000)
                timeline = timeline.addingStage(.groqTranscription, durationMS: groqDurationMS, countTowardProvider: true)
                DebugLog.requestMilestone(timeline, name: "recording_stopped")
                if audioDraft.firstChunkTranscriptionCompletedAt != nil {
                    DebugLog.requestMilestone(timeline, name: "first_chunk_transcription_completed")
                }
                await MainActor.run {
                    chatStore.append(
                        ChatMessage(
                            id: optimisticMessageId,
                            role: .user,
                            content: "Voice message...",
                            style: .voiceTranscript,
                            rawTranscript: audioDraft.rawTranscript
                        )
                    )
                    chatStore.beginRun(threadId: threadId, mode: optimisticTarget, optimisticUserMessageId: optimisticMessageId)
                }
                let prefetchedScreenContextResult = try await screenContextTask.value
                let screenshotData = prefetchedScreenContextResult.0
                let prefetchedScreenContext = prefetchedScreenContextResult.1
                if let prefetchedScreenContext {
                    timeline = timeline.addingStage(
                        .screenContext,
                        durationMS: prefetchedScreenContext.durationMS,
                        countTowardProvider: true
                    )
                }
                let result = try await ElsonRuntime.shared.processAudioTranscriptWithRetry(
                    requestId: requestId,
                    rawTranscript: audioDraft.rawTranscript,
                    snippetCount: audioDraft.snippetCount,
                    mode: runtimeMode ?? .transcription,
                    surface: "shortcut",
                    threadId: threadId,
                    config: config,
                    clipboardText: clipboardText,
                    attachments: pendingAttachments,
                    screenshotJPEGData: screenshotData,
                    prefetchedDeciderScreenContext: prefetchedScreenContext?.context,
                    audioLatencyContext: AudioLatencyContext(
                        shortcutDetectedAt: latencyState?.shortcutDetectedAt,
                        microphonePermissionStartedAt: latencyState?.microphonePermissionStartedAt,
                        microphonePermissionGrantedAt: latencyState?.microphonePermissionGrantedAt,
                        recordingStartedAt: latencyState?.recordingStartedAt,
                        recordingStoppedAt: audioDraft.recordingStoppedAt,
                        firstChunkTranscriptionCompletedAt: audioDraft.firstChunkTranscriptionCompletedAt
                    )
                )
                let desktopActionsStartedAt = Date()
                let actionNotes = await DesktopActionExecutor.execute(result.actions, appSettings: appSettings)
                let desktopActionsDurationMS = Int(Date().timeIntervalSince(desktopActionsStartedAt) * 1000)
                timeline = result.timeline
                    .withThreadId(result.responseThreadId ?? threadId)
                    .addingStage(.audioCaptureFinalize, durationMS: timeline.stageDurationsMS[RequestTimelineStage.audioCaptureFinalize.rawValue] ?? 0)
                    .addingStage(.groqTranscription, durationMS: timeline.stageDurationsMS[RequestTimelineStage.groqTranscription.rawValue] ?? 0, countTowardProvider: true)
                    .addingStage(.screenContext, durationMS: timeline.stageDurationsMS[RequestTimelineStage.screenContext.rawValue] ?? 0, countTowardProvider: true)
                    .addingStage(.desktopActions, durationMS: desktopActionsDurationMS)
                let capturedNewScreenshot = result.actions.contains { $0.type == "capture_screenshot" }
                let correctionSeed = result.postResponseCorrectionSeed

                let uiCommitStartedAt = Date()
                var clipboardResult = ClipboardOperationResult.empty
                var visibleOutputCommittedAt: Date?
                await MainActor.run {
                    session.markDeliveryCompleted()
                    self.activeChunkedSession = nil
                    self.activeRecordingShortcut = nil
                    let effectiveThreadId = result.responseThreadId ?? threadId
                    let assistantMessageId = UUID()
                    let userAttachments = self.persistUserAttachmentsIfNeeded(
                        result: result,
                        screenshotJPEGData: screenshotData,
                        threadId: effectiveThreadId,
                        messageId: optimisticMessageId
                    )
                    if effectiveThreadId != threadId {
                        chatStore.adoptThreadIdPreservingMessages(newId: effectiveThreadId)
                    }
                    if !actionNotes.isEmpty {
                        print(actionNotes.joined(separator: " "))
                    }
                    chatStore.replaceMessage(
                        id: optimisticMessageId,
                        role: .user,
                        style: .voiceTranscript,
                        rawTranscript: result.rawTranscript,
                        overrideRawTranscript: true,
                        attachments: userAttachments,
                        showsAttachmentChip: !userAttachments.isEmpty,
                        with: result.transcript.isEmpty ? "Voice message..." : result.transcript
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
                    appSettings.recordLastOutput(from: result)
                    if runtimeMode == .agent {
                        chatStore.noteConversationActivity(
                            threadId: effectiveThreadId,
                            lastMessage: result.replyText,
                            lastRole: "assistant",
                            lastReplyTarget: result.replyMode,
                            sessionKey: result.sessionKey,
                            markUnread: false
                        )
                    }
                    if !result.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        appSettings.appendTranscriptHistory(
                            text: result.replyText,
                            rawTranscript: result.rawTranscript,
                            source: "shortcut",
                            threadId: effectiveThreadId,
                            replyMode: result.replyMode,
                            actualRoute: result.actualRoute,
                            routingSource: result.routingSource,
                            forcedRouteReason: result.forcedRouteReason,
                            requestId: result.requestId
                        )
                    }
                    visibleOutputCommittedAt = Date()
                    clipboardResult = ClipboardHelper.deliverTranscriptDetailed(
                        result.clipboardText,
                        behavior: appSettings.transcriptClipboardBehavior()
                    )
                    self.activeShortcutThreadId = nil
                    self.activeShortcutPreviousThreadId = nil
                    self.activeShortcutLatencyState = nil
                    self.shortcutScreenContextPrefetchTask = nil
                    self.shortcutDeliveryInFlight = false
                    appSettings.indicatorState = runtimeMode == .agent ? .agentSuccess : .success
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
                    .addingMetric(
                        "latency_hotkey_to_recording_start_ms",
                        valueMS: durationMS(from: latencyState?.shortcutDetectedAt, to: latencyState?.recordingStartedAt)
                    )
                    .addingMetric(
                        "latency_recording_stop_to_first_stt_ms",
                        valueMS: nonNegativeDurationMS(from: audioDraft.recordingStoppedAt, to: audioDraft.firstChunkTranscriptionCompletedAt)
                    )
                    .addingMetric(
                        "latency_recording_stop_to_visible_ms",
                        valueMS: durationMS(from: audioDraft.recordingStoppedAt, to: visibleOutputCommittedAt)
                    )
                    .addingMetric(
                        "latency_visible_to_clipboard_ms",
                        valueMS: durationMS(from: visibleOutputCommittedAt, to: clipboardResult.copyCompletedAt)
                    )
                    .addingMetric(
                        "latency_visible_to_autopaste_ms",
                        valueMS: durationMS(from: visibleOutputCommittedAt, to: clipboardResult.pasteCompletedAt)
                    )
                    .addingMetric(
                        "latency_hotkey_to_autopaste_ms",
                        valueMS: durationMS(from: latencyState?.shortcutDetectedAt, to: clipboardResult.pasteCompletedAt)
                    )
                    .withVisibleLatencyMS(Int(Date().timeIntervalSince(requestStartedAt) * 1000))
                if visibleOutputCommittedAt != nil {
                    DebugLog.requestMilestone(timeline, name: "visible_output_committed")
                }
                if clipboardResult.copied {
                    DebugLog.requestMilestone(timeline, name: "clipboard_copy_completed")
                }
                if clipboardResult.autoPasted {
                    DebugLog.requestMilestone(timeline, name: "autopaste_completed")
                }
                DebugLog.requestTimeline(timeline)
                await MainActor.run {
                    PostResponseCorrectionCoordinator.shared.schedule(
                        seed: correctionSeed,
                        config: config,
                        appSettings: appSettings
                    )
                }
            } catch {
                DebugLog.runtimeError(
                    "shortcut_run_failed thread_id=\(threadId) mode=\(optimisticTarget.rawValue) error=\(error.localizedDescription)"
                )
                await MainActor.run {
                    self.activeChunkedSession = session.isStopped ? session : nil
                    self.activeShortcutThreadId = nil
                    self.activeShortcutPreviousThreadId = nil
                    self.activeRecordingShortcut = nil
                    self.activeShortcutLatencyState = nil
                    self.shortcutScreenContextPrefetchTask = nil
                    self.shortcutDeliveryInFlight = false
                    let friendlyMessage = self.userFacingShortcutErrorMessage(error.localizedDescription)
                    if case .runtime = destination {
                        chatStore.replaceMessage(
                            id: optimisticMessageId,
                            role: .user,
                            style: .voiceTranscript,
                            with: "Voice message"
                        )
                        chatStore.append(ChatMessage(role: .assistant, content: friendlyMessage))
                        chatStore.endRun(threadId: threadId)
                        chatStore.noteConversationActivity(
                            threadId: threadId,
                            lastMessage: friendlyMessage,
                            lastRole: "assistant",
                            lastReplyTarget: optimisticTarget.rawValue,
                            markUnread: false
                        )
                    }
                    appSettings.indicatorState = .error
                    NotificationHelper.showNotification(
                        title: "Elson.ai",
                        body: friendlyMessage,
                        sound: .default
                    )
                }
            }
        }
    }

    private func userFacingShortcutErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if lowercased.contains("invalid api key") || lowercased.contains("invalid_api_key") {
            return "Groq API key is invalid. Update it in Settings > API Keys."
        }
        if lowercased.contains("missing groq api key") {
            return "Groq API key is missing. Add it in Settings > API Keys."
        }
        if lowercased.contains("missing cerebras api key") {
            return "Cerebras API key is missing. Add it in Settings > API Keys."
        }
        if lowercased.contains("missing gemini api key") {
            return "Gemini API key is missing. Add it in Settings > API Keys."
        }
        if trimmed.hasPrefix("Error:") {
            return trimmed
        }
        return "Error: \(trimmed)"
    }

    private func captureScreenshotDataIfPossible() async throws -> Data {
        try await ScreenSnapshotService.shared.captureJPEGDataIfPermitted(maxPixelSize: 1280, quality: 0.7)
    }

    private func startShortcutScreenContextPrefetch(
        requestId: String,
        threadId: String,
        config: ElsonLocalConfig,
        attachments: [AgentAttachment],
        screenshotData: [Data]
    ) {
        shortcutScreenContextPrefetchTask?.cancel()
        _ = config
        guard !screenshotData.isEmpty else {
            shortcutScreenContextPrefetchTask = nil
            return
        }

        shortcutScreenContextPrefetchTask = Task {
            do {
                return try await ElsonRuntime.shared.prefetchAudioDeciderScreenContext(
                    requestId: requestId,
                    surface: "shortcut",
                    threadId: threadId,
                    config: config,
                    attachments: attachments,
                    screenshotJPEGData: screenshotData
                )
            } catch {
                DebugLog.runtimeError(
                    "shortcut_screen_context_prefetch_failed request_id=\(requestId) thread_id=\(threadId) error=\(error.localizedDescription)"
                )
                return nil
            }
        }
    }

    private func shortcutDestination(mode: InteractionMode, chatStore: ChatStore) -> ShortcutDestination {
        if isThreadComposerFocused() {
            if mode == .transcription {
                return .threadComposer(threadId: chatStore.thread.id)
            }
            return .runtime(mode: .agent, threadId: chatStore.thread.id)
        }
        return .runtime(mode: mode, threadId: provisionalShortcutThreadId(currentThreadId: chatStore.thread.id))
    }

    private func isThreadComposerFocused() -> Bool {
        guard NSApp.isActive else { return false }
        guard let keyWindow = NSApp.keyWindow, keyWindow.title == "Elson.ai" else { return false }
        guard let textView = keyWindow.firstResponder as? NSTextView else { return false }
        return textView.isEditable
    }

    private func conversationHistoryPayload(from messages: [ChatMessage], limit: Int = 12) -> [ElsonConversationTurnPayload] {
        let turns = messages.compactMap { message -> ElsonConversationTurnPayload? in
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

    private func cancelActiveShortcutRecording(reason: String) async {
        guard let appSettings, let chatStore else { return }
        guard let session = activeChunkedSession else { return }
        let activeThreadId = activeShortcutThreadId ?? chatStore.thread.id

        session.cancel()
        activeChunkedSession = nil
        activeShortcutDestination = nil
        activeRecordingShortcut = nil
        activeShortcutThreadId = nil
        activeShortcutLatencyState = nil
        shortcutRunScreenshotJPEGData = []
        shortcutScreenContextPrefetchTask?.cancel()
        shortcutScreenContextPrefetchTask = nil
        shortcutDeliveryInFlight = false
        appSettings.isRecording = false
        appSettings.indicatorState = .idle
        chatStore.endRun(threadId: activeThreadId)
        restorePriorThreadIfNeeded(chatStore: chatStore)
        DebugLog.runtime("shortcut_recording_cancelled reason=\(reason)")
    }

    private func restorePriorThreadIfNeeded(chatStore: ChatStore) {
        defer { activeShortcutPreviousThreadId = nil }
        guard let previousThreadId = activeShortcutPreviousThreadId,
              !previousThreadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }
        chatStore.openPersistedThread(id: previousThreadId)
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

    private func provisionalShortcutThreadId(currentThreadId _: String) -> String {
        return UUID().uuidString
    }

    private func durationMS(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return Int(end.timeIntervalSince(start) * 1000)
    }

    private func nonNegativeDurationMS(from start: Date?, to end: Date?) -> Int? {
        guard let duration = durationMS(from: start, to: end) else { return nil }
        return max(0, duration)
    }
}
