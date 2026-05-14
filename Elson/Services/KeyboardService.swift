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

    private struct ShortcutProcessingJob {
        let requestId: String
        let requestStartedAt: Date
        let audioCaptureDurationMS: Int
        let session: LocalChunkedAudioSession
        let destination: ShortcutDestination
        let threadId: String
        let optimisticMessageId: UUID
        let config: ElsonLocalConfig
        let pendingAttachments: [AgentAttachment]
        let clipboardText: String?
        let latencyState: ShortcutLatencyState?
        let runtimeMode: InteractionMode?
        let optimisticTarget: ThreadReplyTarget
        let processingState: IndicatorState
        let screenshotData: [Data]
        let screenContextPrefetchTask: Task<(context: LocalScreenContext, durationMS: Int)?, Never>?
    }

    @ObservationIgnored private let minimumShortcutRecordingDuration: TimeInterval = 1
    @ObservationIgnored private let shortcutLiveFinalizationDeadline: TimeInterval = 8
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
    @ObservationIgnored private var shortcutCaptureInFlight = false
    @ObservationIgnored private var shortcutProcessingQueue: [ShortcutProcessingJob] = []
    @ObservationIgnored private var isShortcutProcessingQueueRunning = false
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
        guard !recordingService.isRecording, !shortcutCaptureInFlight else {
            DebugLog.runtime("shortcut_recording_start_ignored reason=capture_active")
            NotificationHelper.showNotification(
                title: "Elson.ai",
                body: "Recording is already active.",
                sound: nil
            )
            return
        }
        shortcutCaptureInFlight = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !recordingService.isRecording else {
                self.shortcutCaptureInFlight = false
                DebugLog.runtime("shortcut_recording_start_ignored reason=recording_active_after_schedule")
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
                self.shortcutCaptureInFlight = false
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
                self.shortcutCaptureInFlight = false
                return
            }

            self.activeChunkedSession = nil
            self.shortcutScreenContextPrefetchTask?.cancel()
            self.shortcutScreenContextPrefetchTask = nil
            let session = LocalChunkedAudioSession(
                recordingService: recordingService,
                groqAPIKey: appSettings.makeLocalConfig().groqAPIKey,
                modeHint: mode,
                requestLogContext: LocalRequestLogContext(
                    requestId: requestId,
                    threadId: targetThreadId,
                    surface: "shortcut",
                    inputSource: "audio"
                )
            )
            guard session.start() else {
                self.shortcutCaptureInFlight = false
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
            shortcutCaptureInFlight = false
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

        let threadId = destination.threadId
        let optimisticMessageId = UUID()
        let config = appSettings.makeLocalConfig()
        let pendingAttachments = appSettings.pendingAttachments
        let clipboardText = ClipboardHelper.getClipboardContent()
        let latencyState = activeShortcutLatencyState
        let screenshotData = shortcutRunScreenshotJPEGData
        let screenContextPrefetchTask = shortcutScreenContextPrefetchTask
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let requestId = session.requestId ?? UUID().uuidString
                let requestStartedAt = Date()

                let audioCaptureStartedAt = Date()
                let kept = try await session.stopRecordingDiscardingIfShorterThan(minimumShortcutRecordingDuration)
                let audioCaptureDurationMS = Int(Date().timeIntervalSince(audioCaptureStartedAt) * 1000)
                guard kept else {
                    self.activeChunkedSession = nil
                    self.activeShortcutThreadId = nil
                    self.restorePriorThreadIfNeeded(chatStore: chatStore)
                    self.activeRecordingShortcut = nil
                    self.activeShortcutLatencyState = nil
                    self.shortcutRunScreenshotJPEGData = []
                    self.shortcutScreenContextPrefetchTask?.cancel()
                    self.shortcutScreenContextPrefetchTask = nil
                    self.shortcutCaptureInFlight = false
                    appSettings.indicatorState = .idle
                    NotificationHelper.showNotification(
                        title: "Elson.ai",
                        body: "Recording too short.",
                        sound: nil
                    )
                    return
                }
                session.updateReplayContext(mode: runtimeMode ?? .transcription, threadId: threadId)

                let job = ShortcutProcessingJob(
                    requestId: requestId,
                    requestStartedAt: requestStartedAt,
                    audioCaptureDurationMS: audioCaptureDurationMS,
                    session: session,
                    destination: destination,
                    threadId: threadId,
                    optimisticMessageId: optimisticMessageId,
                    config: config,
                    pendingAttachments: pendingAttachments,
                    clipboardText: clipboardText,
                    latencyState: latencyState,
                    runtimeMode: runtimeMode,
                    optimisticTarget: optimisticTarget,
                    processingState: processingState,
                    screenshotData: screenshotData,
                    screenContextPrefetchTask: screenContextPrefetchTask
                )
                self.activeChunkedSession = nil
                self.activeShortcutThreadId = nil
                self.activeShortcutPreviousThreadId = nil
                self.activeRecordingShortcut = nil
                self.activeShortcutLatencyState = nil
                self.shortcutRunScreenshotJPEGData = []
                self.shortcutScreenContextPrefetchTask = nil
                self.shortcutCaptureInFlight = false
                self.enqueueShortcutProcessing(job)
            } catch {
                DebugLog.runtimeError(
                    "shortcut_run_failed thread_id=\(threadId) mode=\(optimisticTarget.rawValue) error=\(error.localizedDescription)"
                )
                self.activeChunkedSession = nil
                self.activeShortcutThreadId = nil
                self.activeShortcutPreviousThreadId = nil
                self.activeRecordingShortcut = nil
                self.activeShortcutLatencyState = nil
                self.shortcutRunScreenshotJPEGData = []
                self.shortcutScreenContextPrefetchTask = nil
                self.shortcutCaptureInFlight = false
                let captureSessionId = session.persistedSessionId
                let friendlyMessage = self.userFacingShortcutErrorMessage(error.localizedDescription)
                appSettings.recordCaptureFailure(sessionId: captureSessionId, errorMessage: friendlyMessage)
                appSettings.indicatorState = .error
                NotificationHelper.showNotification(
                    title: "Elson.ai",
                    body: friendlyMessage,
                    sound: .default
                )
            }
        }
    }

    private func enqueueShortcutProcessing(_ job: ShortcutProcessingJob) {
        shortcutProcessingQueue.append(job)
        DebugLog.runtime(
            "shortcut_capture_enqueued request_id=\(job.requestId) thread_id=\(job.threadId) audio_session_id=\(job.session.persistedSessionId) queue_depth=\(shortcutProcessingQueue.count)"
        )
        processNextShortcutProcessingJobIfNeeded()
    }

    private func processNextShortcutProcessingJobIfNeeded() {
        guard !isShortcutProcessingQueueRunning else { return }
        guard !shortcutProcessingQueue.isEmpty else { return }
        isShortcutProcessingQueueRunning = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.shortcutProcessingQueue.isEmpty {
                let job = self.shortcutProcessingQueue.removeFirst()
                await self.processShortcutProcessingJob(job)
            }
            self.isShortcutProcessingQueueRunning = false
        }
    }

    private func processShortcutProcessingJob(_ job: ShortcutProcessingJob) async {
        guard let appSettings, let chatStore else { return }
        appSettings.indicatorState = job.processingState
        DebugLog.runtime(
            "shortcut_processing_started request_id=\(job.requestId) thread_id=\(job.threadId) audio_session_id=\(job.session.persistedSessionId)"
        )

        do {
            if case let .threadComposer(targetThreadId) = job.destination {
                openJobThreadIfNeeded(chatStore: chatStore, threadId: targetThreadId)
                let audioDraft = try await job.session.finalize(allowPartialAfter: shortcutLiveFinalizationDeadline)
                if audioDraft.isPartial {
                    DebugLog.runtime(
                        "shortcut_processing_partial request_id=\(job.requestId) thread_id=\(targetThreadId) audio_session_id=\(job.session.persistedSessionId) failed_chunks=\(audioDraft.failedChunkIndices.map(String.init).joined(separator: ","))"
                    )
                }
                let formattedText = try await ElsonRuntime.shared.formatRawTranscriptForChatComposer(
                    requestId: job.requestId,
                    rawTranscript: audioDraft.rawTranscript,
                    threadId: targetThreadId,
                    config: job.config,
                    conversationHistory: conversationHistoryPayload(from: chatStore.thread.messages)
                )
                if audioDraft.isPartial {
                    job.session.markPartialDeliveryAvailable(reason: audioDraft.partialReason)
                    appSettings.recordReplayableCaptureSession(
                        sessionId: job.session.persistedSessionId,
                        errorMessage: "Partial transcript delivered. Replay available."
                    )
                    NotificationHelper.showNotification(
                        title: "Elson.ai",
                        body: "Partial transcript delivered. Replay available.",
                        sound: nil
                    )
                } else {
                    job.session.markDeliveryCompleted()
                }
                appSettings.indicatorState = .success
                NotificationCenter.default.post(name: .insertTextIntoThreadComposer, object: formattedText)
                DebugLog.runtime(
                    "shortcut_processing_completed request_id=\(job.requestId) thread_id=\(targetThreadId) audio_session_id=\(job.session.persistedSessionId) partial=\(audioDraft.isPartial)"
                )
                return
            }

            let screenContextTask = Task<([Data], (context: LocalScreenContext, durationMS: Int)?), Error> { @MainActor [weak self] in
                guard let self else { return (job.screenshotData, nil) }
                var screenshotData = job.screenshotData
                if screenshotData.isEmpty, let captured = try? await self.captureScreenshotDataIfPossible() {
                    screenshotData = [captured]
                }
                if let prefetched = await job.screenContextPrefetchTask?.value {
                    return (screenshotData, prefetched)
                }
                let prefetched = try await ElsonRuntime.shared.prefetchShortcutScreenContext(
                    requestId: job.requestId,
                    surface: "shortcut",
                    threadId: job.threadId,
                    config: job.config,
                    attachments: job.pendingAttachments,
                    screenshotJPEGData: screenshotData
                )
                return (screenshotData, prefetched)
            }

            var timeline = RequestTimelineSnapshot(
                requestId: job.requestId,
                threadId: job.threadId,
                surface: "shortcut",
                inputSource: "audio",
                startedAt: job.requestStartedAt
            )
            .addingStage(.audioCaptureFinalize, durationMS: job.audioCaptureDurationMS)

            let groqStartedAt = Date()
            let audioDraft = try await job.session.finalize(allowPartialAfter: shortcutLiveFinalizationDeadline)
            let groqDurationMS = Int(Date().timeIntervalSince(groqStartedAt) * 1000)
            timeline = timeline.addingStage(.groqTranscription, durationMS: groqDurationMS, countTowardProvider: true)
            DebugLog.requestMilestone(timeline, name: "recording_stopped")
            if audioDraft.firstChunkTranscriptionCompletedAt != nil {
                DebugLog.requestMilestone(timeline, name: "first_chunk_transcription_completed")
            }
            if audioDraft.isPartial {
                DebugLog.runtime(
                    "shortcut_processing_partial request_id=\(job.requestId) thread_id=\(job.threadId) audio_session_id=\(job.session.persistedSessionId) failed_chunks=\(audioDraft.failedChunkIndices.map(String.init).joined(separator: ","))"
                )
            }

            openJobThreadIfNeeded(chatStore: chatStore, threadId: job.threadId)
            chatStore.append(
                ChatMessage(
                    id: job.optimisticMessageId,
                    role: .user,
                    content: "Voice message...",
                    style: .voiceTranscript,
                    rawTranscript: audioDraft.rawTranscript,
                    captureSessionId: job.session.persistedSessionId
                )
            )
            chatStore.beginRun(threadId: job.threadId, mode: job.optimisticTarget, optimisticUserMessageId: job.optimisticMessageId)

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
                requestId: job.requestId,
                rawTranscript: audioDraft.rawTranscript,
                snippetCount: audioDraft.snippetCount,
                transcriptChunkTimings: audioDraft.transcriptChunkTimings,
                mode: job.runtimeMode ?? .transcription,
                surface: "shortcut",
                threadId: job.threadId,
                config: job.config,
                clipboardText: job.clipboardText,
                attachments: job.pendingAttachments,
                screenshotJPEGData: screenshotData,
                prefetchedDeciderScreenContext: prefetchedScreenContext?.context,
                audioLatencyContext: AudioLatencyContext(
                    shortcutDetectedAt: job.latencyState?.shortcutDetectedAt,
                    microphonePermissionStartedAt: job.latencyState?.microphonePermissionStartedAt,
                    microphonePermissionGrantedAt: job.latencyState?.microphonePermissionGrantedAt,
                    recordingStartedAt: job.latencyState?.recordingStartedAt,
                    recordingStoppedAt: audioDraft.recordingStoppedAt,
                    firstChunkTranscriptionCompletedAt: audioDraft.firstChunkTranscriptionCompletedAt
                )
            )
            let desktopActionsStartedAt = Date()
            let actionNotes = await DesktopActionExecutor.execute(result.actions, appSettings: appSettings)
            let desktopActionsDurationMS = Int(Date().timeIntervalSince(desktopActionsStartedAt) * 1000)
            timeline = result.timeline
                .withThreadId(result.responseThreadId ?? job.threadId)
                .addingStage(.audioCaptureFinalize, durationMS: timeline.stageDurationsMS[RequestTimelineStage.audioCaptureFinalize.rawValue] ?? 0)
                .addingStage(.groqTranscription, durationMS: timeline.stageDurationsMS[RequestTimelineStage.groqTranscription.rawValue] ?? 0, countTowardProvider: true)
                .addingStage(.screenContext, durationMS: timeline.stageDurationsMS[RequestTimelineStage.screenContext.rawValue] ?? 0, countTowardProvider: true)
                .addingStage(.desktopActions, durationMS: desktopActionsDurationMS)
            let capturedNewScreenshot = result.actions.contains { $0.type == "capture_screenshot" }
            let correctionSeed = result.postResponseCorrectionSeed

            let uiCommitStartedAt = Date()
            var clipboardResult = ClipboardOperationResult.empty
            var visibleOutputCommittedAt: Date?
            let captureSessionId = job.session.persistedSessionId
            let effectiveThreadId = result.responseThreadId ?? job.threadId
            let assistantMessageId = UUID()
            let userAttachments = persistUserAttachmentsIfNeeded(
                result: result,
                screenshotJPEGData: screenshotData,
                threadId: effectiveThreadId,
                messageId: job.optimisticMessageId
            )
            if audioDraft.isPartial {
                job.session.markPartialDeliveryAvailable(reason: audioDraft.partialReason)
            } else {
                job.session.markDeliveryCompleted()
            }
            openJobThreadIfNeeded(chatStore: chatStore, threadId: job.threadId)
            if effectiveThreadId != job.threadId {
                chatStore.adoptThreadIdPreservingMessages(newId: effectiveThreadId)
            }
            if !actionNotes.isEmpty {
                print(actionNotes.joined(separator: " "))
            }
            chatStore.replaceMessage(
                id: job.optimisticMessageId,
                role: .user,
                style: .voiceTranscript,
                rawTranscript: result.rawTranscript,
                overrideRawTranscript: true,
                captureSessionId: captureSessionId,
                overrideCaptureSessionId: true,
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
            chatStore.endRun(threadId: job.threadId)
            appSettings.recordLastOutput(from: result, captureSessionId: captureSessionId)
            if audioDraft.isPartial {
                appSettings.recordReplayableCaptureSession(
                    sessionId: captureSessionId,
                    errorMessage: "Partial transcript delivered. Replay available."
                )
                NotificationHelper.showNotification(
                    title: "Elson.ai",
                    body: "Partial transcript delivered. Replay available.",
                    sound: nil
                )
            }
            if job.runtimeMode == .agent {
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
                    requestId: result.requestId,
                    captureSessionId: captureSessionId
                )
            }
            visibleOutputCommittedAt = Date()
            clipboardResult = ClipboardHelper.deliverTranscriptDetailed(
                result.clipboardText,
                behavior: appSettings.transcriptClipboardBehavior()
            )
            appSettings.indicatorState = job.runtimeMode == .agent ? .agentSuccess : .success
            appSettings.clearAgentAttachments()
            if !capturedNewScreenshot {
                appSettings.pendingScreenshotJPEGData = []
            }
            if let updatedMyElsonMarkdown = result.updatedMyElsonMarkdown {
                appSettings.applyAgentMyElsonMarkdownUpdate(updatedMyElsonMarkdown)
            }

            let uiCommitDurationMS = Int(Date().timeIntervalSince(uiCommitStartedAt) * 1000)
            timeline = timeline
                .withThreadId(result.responseThreadId ?? job.threadId)
                .addingStage(.uiCommit, durationMS: uiCommitDurationMS)
                .addingMetric(
                    "latency_hotkey_to_recording_start_ms",
                    valueMS: durationMS(from: job.latencyState?.shortcutDetectedAt, to: job.latencyState?.recordingStartedAt)
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
                    valueMS: durationMS(from: job.latencyState?.shortcutDetectedAt, to: clipboardResult.pasteCompletedAt)
                )
                .withVisibleLatencyMS(Int(Date().timeIntervalSince(job.requestStartedAt) * 1000))
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
            PostResponseCorrectionCoordinator.shared.schedule(
                seed: correctionSeed,
                config: job.config,
                appSettings: appSettings
            )
            DebugLog.runtime(
                "shortcut_processing_completed request_id=\(job.requestId) thread_id=\(effectiveThreadId) audio_session_id=\(captureSessionId) partial=\(audioDraft.isPartial)"
            )
        } catch {
            handleShortcutProcessingFailure(job: job, error: error, appSettings: appSettings, chatStore: chatStore)
        }
    }

    private func handleShortcutProcessingFailure(
        job: ShortcutProcessingJob,
        error: Error,
        appSettings: AppSettings,
        chatStore: ChatStore
    ) {
        DebugLog.runtimeError(
            "shortcut_processing_failed request_id=\(job.requestId) thread_id=\(job.threadId) audio_session_id=\(job.session.persistedSessionId) error=\(error.localizedDescription)"
        )
        let captureSessionId = job.session.persistedSessionId
        let archivedRawTranscript = LocalCapturedAudioSessionStore().rawTranscript(sessionId: captureSessionId)
        let friendlyMessage = userFacingShortcutErrorMessage(error.localizedDescription)
        let noSpeechDetected = isNoSpeechDetectedMessage(friendlyMessage)
        if !noSpeechDetected {
            appSettings.recordCaptureFailure(sessionId: captureSessionId, errorMessage: friendlyMessage)
        }
        if case .runtime = job.destination, !noSpeechDetected {
            openJobThreadIfNeeded(chatStore: chatStore, threadId: job.threadId)
            let userContent = archivedRawTranscript ?? "Voice message"
            if chatStore.containsMessage(id: job.optimisticMessageId) {
                chatStore.replaceMessage(
                    id: job.optimisticMessageId,
                    role: .user,
                    style: .voiceTranscript,
                    rawTranscript: archivedRawTranscript,
                    overrideRawTranscript: true,
                    captureSessionId: captureSessionId,
                    overrideCaptureSessionId: true,
                    with: userContent
                )
            } else {
                chatStore.append(
                    ChatMessage(
                        id: job.optimisticMessageId,
                        role: .user,
                        content: userContent,
                        style: .voiceTranscript,
                        rawTranscript: archivedRawTranscript,
                        captureSessionId: captureSessionId
                    )
                )
            }
            chatStore.append(ChatMessage(role: .assistant, content: friendlyMessage))
            chatStore.endRun(threadId: job.threadId)
            chatStore.noteConversationActivity(
                threadId: job.threadId,
                lastMessage: friendlyMessage,
                lastRole: "assistant",
                lastReplyTarget: job.optimisticTarget.rawValue,
                markUnread: false
            )
        } else if noSpeechDetected {
            openJobThreadIfNeeded(chatStore: chatStore, threadId: job.threadId)
            if chatStore.containsMessage(id: job.optimisticMessageId) {
                chatStore.removeMessage(id: job.optimisticMessageId)
            }
            chatStore.endRun(threadId: job.threadId)
        }
        appSettings.indicatorState = noSpeechDetected ? .idle : .error
        NotificationHelper.showNotification(
            title: "Elson.ai",
            body: friendlyMessage,
            sound: .default
        )
    }

    private func openJobThreadIfNeeded(chatStore: ChatStore, threadId: String) {
        guard chatStore.thread.id != threadId else { return }
        chatStore.openPersistedThread(id: threadId)
    }

    private func userFacingShortcutErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if lowercased == "transcription failed. replay available." {
            return "Transcription failed. Replay available."
        }
        if lowercased == "partial transcript delivered. replay available." {
            return "Partial transcript delivered. Replay available."
        }
        if lowercased == "recording is already active." {
            return "Recording is already active."
        }
        if lowercased.contains("invalid api key") || lowercased.contains("invalid_api_key") {
            return "Groq API key is invalid. Update it in Settings > Processing > Cloud."
        }
        if lowercased.contains("missing groq api key") {
            return "Groq API key is missing. Add it in Settings > Processing > Cloud."
        }
        if lowercased.contains("missing cerebras api key") {
            return "Cerebras API key is missing. Add it in Settings > Processing > Cloud."
        }
        if lowercased.contains("missing gemini api key") {
            return "Gemini API key is missing. Add it in Settings > Processing > Cloud."
        }
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

    private func captureScreenshotDataIfPossible() async throws -> Data {
        let maxPixelSize = appSettings?.screenshotCaptureMaxPixelSize ?? 300
        let cropRadius = appSettings?.screenshotCaptureCropAroundMousePixelRadius ?? 150
        return try await ScreenSnapshotService.shared.captureJPEGDataIfPermitted(
            maxPixelSize: maxPixelSize,
            quality: 0.7,
            cropAroundMousePixelRadius: cropRadius
        )
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
                return try await ElsonRuntime.shared.prefetchShortcutScreenContext(
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
        shortcutCaptureInFlight = false
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
