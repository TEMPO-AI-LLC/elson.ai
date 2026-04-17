import AppKit
import CryptoKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI

struct AgentAttachment: Identifiable, Hashable {
    let id: UUID
    let fileName: String
    let mimeType: String
    let data: Data

    init(id: UUID = UUID(), fileName: String, mimeType: String, data: Data) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }
}

enum InteractionMode: String, Codable, CaseIterable {
    case transcription
    case agent
}

enum IndicatorState: String, Codable {
    case hidden
    case idle
    case listening
    case processing
    case agentProcessing
    case success
    case agentSuccess
    case error
}

enum InstallOnboardingStep: Int, CaseIterable, Hashable {
    case interactionModel
    case apiKeys
    case microphone
    case screen
    case accessibility
    case fullDiskAccess
    case folder
    case transcriptShortcut
    case agentShortcut
    case celebration
}

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let didCompleteOnboarding = "did_complete_onboarding"
        static let completedOnboardingAppVersion = "completed_onboarding_app_version"
        static let didCompleteInteractionModelOnboarding = "did_complete_interaction_model_onboarding"
        static let didCompleteFolderOnboarding = "did_complete_folder_onboarding"
        static let didCompleteTranscriptShortcutOnboarding = "did_complete_transcript_shortcut_onboarding"
        static let didCompleteAgentShortcutOnboarding = "did_complete_agent_shortcut_onboarding"
        static let didCompleteShortcutOnboarding = "did_complete_shortcut_onboarding"
        static let muteSystemAudioDuringRecording = "muteSystemAudioDuringRecording"
        static let launchAtLogin = "launch_at_login"
        static let bubbleOnlyWhileRecording = "bubble_only_while_recording"
        static let listeningMode = "listening_mode"
        static let transcriptShortcut = "transcript_shortcut"
        static let agentShortcut = "agent_shortcut"
        static let recordingShortcut = "recording_shortcut"
        static let feedbackShortcutEnabled = "feedback_shortcut_enabled"
        static let feedbackShortcut = "feedback_shortcut"
        static let autoPasteEnabled = "auto_paste_enabled"
        static let copyTranscriptToClipboardEnabled = "copy_transcript_to_clipboard_enabled"
        static let restoreOriginalClipboardAfterPasteEnabled = "restore_original_clipboard_after_paste_enabled"
        static let transcriptScreenOCREnabled = "transcript_screen_ocr_enabled"
        static let agentModeEnabled = "agent_mode_enabled"
        static let skillsEnabled = "skills_enabled"
        static let skillSelectionScope = "skill_selection_scope"
        static let selectedSkillIDs = "selected_skill_ids"
        static let myElsonMarkdown = "my_elson_markdown"
        static let intentAgentPrompt = "intent_agent_prompt"
        static let transcriptAgentPrompt = "transcript_agent_prompt"
        static let workingAgentPrompt = "working_agent_prompt"
        static let masterSystemPrompt = "master_system_prompt"
        static let legacyAgentSystemPrompt = "agent_system_prompt"
        static let legacyOpenClawBaseURL = "openclaw_base_url"
        static let runtimeMode = "runtime_mode"
        static let audioDeciderProvider = "audio_decider_provider"
        static let agentProvider = "agent_provider"
    }

    private static let fixedTranscriptProvider: LocalModelProvider = .cerebras
    private static let fixedAgentProvider: LocalModelProvider = .google

    var didCompleteOnboarding: Bool = false {
        didSet {
            guard !isHydratingMyElsonState else { return }
            UserDefaults.standard.set(didCompleteOnboarding, forKey: Keys.didCompleteOnboarding)
            if didCompleteOnboarding {
                UserDefaults.standard.set(Self.currentAppVersion, forKey: Keys.completedOnboardingAppVersion)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.completedOnboardingAppVersion)
            }
        }
    }

    var didCompleteInteractionModelOnboarding: Bool = false {
        didSet {
            UserDefaults.standard.set(didCompleteInteractionModelOnboarding, forKey: Keys.didCompleteInteractionModelOnboarding)
            if !isHydratingMyElsonState {
                refreshOnboardingStoredFlag()
            }
        }
    }

    var didCompleteFolderOnboarding: Bool = false {
        didSet {
            UserDefaults.standard.set(didCompleteFolderOnboarding, forKey: Keys.didCompleteFolderOnboarding)
            if !isHydratingMyElsonState {
                refreshOnboardingStoredFlag()
            }
        }
    }

    var didCompleteTranscriptShortcutOnboarding: Bool = false {
        didSet {
            UserDefaults.standard.set(didCompleteTranscriptShortcutOnboarding, forKey: Keys.didCompleteTranscriptShortcutOnboarding)
            if !isHydratingMyElsonState {
                refreshOnboardingStoredFlag()
            }
        }
    }

    var didCompleteAgentShortcutOnboarding: Bool = false {
        didSet {
            UserDefaults.standard.set(didCompleteAgentShortcutOnboarding, forKey: Keys.didCompleteAgentShortcutOnboarding)
            if !isHydratingMyElsonState {
                refreshOnboardingStoredFlag()
            }
        }
    }

    var muteSystemAudioDuringRecording: Bool = true {
        didSet {
            UserDefaults.standard.set(muteSystemAudioDuringRecording, forKey: Keys.muteSystemAudioDuringRecording)
            persistLocalConfig()
        }
    }

    var launchAtLogin: Bool = true {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLaunchAtLoginRegistration()
        }
    }

    var bubbleOnlyWhileRecording: Bool = false {
        didSet { UserDefaults.standard.set(bubbleOnlyWhileRecording, forKey: Keys.bubbleOnlyWhileRecording) }
    }

    var listeningMode: ListeningMode = .hold {
        didSet {
            UserDefaults.standard.set(listeningMode.rawValue, forKey: Keys.listeningMode)
            persistLocalConfig()
        }
    }

    var transcriptShortcut: RecordingShortcut = .default {
        didSet {
            UserDefaults.standard.set(transcriptShortcut.storageValue, forKey: Keys.transcriptShortcut)
            persistLocalConfig()
        }
    }

    var agentShortcut: RecordingShortcut = .feedbackDefault {
        didSet {
            UserDefaults.standard.set(agentShortcut.storageValue, forKey: Keys.agentShortcut)
            persistLocalConfig()
        }
    }

    var recordingShortcut: RecordingShortcut = .default {
        didSet {
            UserDefaults.standard.set(recordingShortcut.storageValue, forKey: Keys.recordingShortcut)
            persistLocalConfig()
        }
    }

    var feedbackShortcutEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(feedbackShortcutEnabled, forKey: Keys.feedbackShortcutEnabled)
            persistLocalConfig()
        }
    }

    var feedbackShortcut: RecordingShortcut = .feedbackDefault {
        didSet {
            UserDefaults.standard.set(feedbackShortcut.storageValue, forKey: Keys.feedbackShortcut)
            persistLocalConfig()
        }
    }

    var runtimeMode: RuntimeMode = .local {
        didSet {
            UserDefaults.standard.set(runtimeMode.rawValue, forKey: Keys.runtimeMode)
            persistLocalConfig()
        }
    }

    var autoPasteEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(autoPasteEnabled, forKey: Keys.autoPasteEnabled)
            persistLocalConfig()
        }
    }

    var copyTranscriptToClipboardEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(copyTranscriptToClipboardEnabled, forKey: Keys.copyTranscriptToClipboardEnabled)
            persistLocalConfig()
        }
    }

    var restoreOriginalClipboardAfterPasteEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(
                restoreOriginalClipboardAfterPasteEnabled,
                forKey: Keys.restoreOriginalClipboardAfterPasteEnabled
            )
            persistLocalConfig()
        }
    }

    var transcriptScreenOCREnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(
                transcriptScreenOCREnabled,
                forKey: Keys.transcriptScreenOCREnabled
            )
            persistLocalConfig()
        }
    }

    var agentModeEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(agentModeEnabled, forKey: Keys.agentModeEnabled)
            persistLocalConfig()
        }
    }

    var skillsEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(skillsEnabled, forKey: Keys.skillsEnabled)
            persistLocalConfig()
        }
    }

    var skillSelectionScope: SkillSelectionScope = .all {
        didSet {
            UserDefaults.standard.set(skillSelectionScope.rawValue, forKey: Keys.skillSelectionScope)
            persistLocalConfig()
        }
    }

    var selectedSkillIDs: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(selectedSkillIDs).sorted(), forKey: Keys.selectedSkillIDs)
            persistLocalConfig()
        }
    }

    var myElsonMarkdown: String = "" {
        didSet {
            guard !deferImmediateMyElsonPersistence, !isHydratingMyElsonState else { return }
            UserDefaults.standard.set(myElsonMarkdown, forKey: Keys.myElsonMarkdown)
            syncWorkspaceMyElsonMarkdownIfPossible()
            persistLocalConfig()
        }
    }

    var intentAgentPrompt: String = ElsonPromptCatalog.defaultIntentAgentPrompt {
        didSet {
            UserDefaults.standard.set(intentAgentPrompt, forKey: Keys.intentAgentPrompt)
            persistLocalConfig()
        }
    }

    var transcriptAgentPrompt: String = ElsonPromptCatalog.defaultTranscriptAgentPrompt {
        didSet {
            UserDefaults.standard.set(transcriptAgentPrompt, forKey: Keys.transcriptAgentPrompt)
            persistLocalConfig()
        }
    }

    var workingAgentPrompt: String = ElsonPromptCatalog.defaultWorkingAgentPrompt {
        didSet {
            UserDefaults.standard.set(workingAgentPrompt, forKey: Keys.workingAgentPrompt)
            persistLocalConfig()
        }
    }

    var groqAPIKey: String = "" {
        didSet {
            guard !isHydratingMyElsonState else { return }
            persistLocalConfig()
        }
    }

    var cerebrasAPIKey: String = "" {
        didSet {
            guard !isHydratingMyElsonState else { return }
            persistLocalConfig()
        }
    }

    var geminiAPIKey: String = "" {
        didSet {
            guard !isHydratingMyElsonState else { return }
            persistLocalConfig()
        }
    }

    var audioDeciderProvider: LocalModelProvider = .cerebras {
        didSet {
            UserDefaults.standard.set(audioDeciderProvider.rawValue, forKey: Keys.audioDeciderProvider)
            persistLocalConfig()
        }
    }

    var agentProvider: LocalModelProvider = .google {
        didSet {
            UserDefaults.standard.set(agentProvider.rawValue, forKey: Keys.agentProvider)
            persistLocalConfig()
        }
    }

    var pendingScreenshotJPEGData: [Data] = []
    var pendingAttachments: [AgentAttachment] = []
    var isRecording: Bool = false
    var lastOutputSnapshot: LastOutputSnapshot? = nil
    var activeFeedbackContext: ActiveFeedbackContext? = nil
    private(set) var transcriptHistory: [TranscriptHistoryEntry] = []
    private(set) var microphonePermissionGranted: Bool = PermissionCoordinator.hasMicrophonePermission()
    private(set) var screenRecordingPermissionGranted: Bool = PermissionCoordinator.hasScreenRecordingPermission()
    private(set) var accessibilityPermissionGranted: Bool = PermissionCoordinator.hasAccessibilityPermission()
    private(set) var fullDiskAccessPermissionGranted: Bool = PermissionCoordinator.hasFullDiskAccessPermission()
    private(set) var lastPromptLearningStatus: String? = nil
    private(set) var lastPromptLearningAt: Date? = nil
    private(set) var discoveredSkills: [RegisteredSkill] = []
    private(set) var skillsLastScanAt: Date? = nil
    private(set) var skillsLastScanError: String? = nil
    var indicatorState: IndicatorState = .idle {
        didSet { handleIndicatorStateDidChange(to: indicatorState) }
    }

    private var indicatorResetTask: Task<Void, Never>?
    private var deferredMyElsonPersistenceTask: Task<Void, Never>?
    private var deferImmediateMyElsonPersistence = false
    private var isHydratingMyElsonState = false
    private var didImportWorkingDirectorySourcesThisLaunch = false

    private static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    }

    var lastTranscription: String {
        lastOutputSnapshot?.processedText ?? ""
    }

    var activeSkills: [RegisteredSkill] {
        switch skillSelectionScope {
        case .all:
            return discoveredSkills
        case .selectedOnly:
            return discoveredSkills.filter { selectedSkillIDs.contains($0.id) }
        }
    }

    var selectedSkillsCount: Int {
        activeSkills.count
    }

    var hasShortcutConflict: Bool {
        !transcriptShortcut.isEmpty && transcriptShortcut == agentShortcut
    }

    init() {
        loadSettings()
    }

    func appendAgentAttachments(_ attachments: [AgentAttachment], maxCount: Int = 5, maxTotalBytes: Int = 20 * 1024 * 1024) {
        guard !attachments.isEmpty else { return }

        var remainingCount = Swift.max(0, maxCount - pendingAttachments.count)
        guard remainingCount > 0 else { return }

        var remainingBytes = Swift.max(0, maxTotalBytes - pendingAttachments.reduce(0, { $0 + $1.data.count }))
        guard remainingBytes > 0 else { return }

        var accepted: [AgentAttachment] = []
        for attachment in attachments {
            if remainingCount <= 0 { break }
            let size = attachment.data.count
            guard size > 0, size <= remainingBytes else { continue }
            accepted.append(attachment)
            remainingCount -= 1
            remainingBytes -= size
        }

        guard !accepted.isEmpty else { return }
        pendingAttachments.append(contentsOf: accepted)
        pendingScreenshotJPEGData = []
    }

    func clearAgentAttachments() {
        pendingAttachments = []
    }

    func applyLaunchAtLoginPreference() {
        updateLaunchAtLoginRegistration()
    }

    func makeLocalConfig() -> ElsonLocalConfig {
        ElsonLocalConfig(
            groqAPIKey: groqAPIKey,
            cerebrasAPIKey: cerebrasAPIKey,
            geminiAPIKey: geminiAPIKey,
            audioDeciderProvider: Self.fixedTranscriptProvider,
            agentProvider: Self.fixedAgentProvider,
            myElsonMarkdown: myElsonMarkdown,
            intentAgentPrompt: intentAgentPrompt,
            transcriptAgentPrompt: transcriptAgentPrompt,
            workingAgentPrompt: workingAgentPrompt,
            agentModeEnabled: true,
            skillsEnabled: skillsEnabled,
            skillSelectionScope: skillSelectionScope,
            selectedSkillIDs: Array(selectedSkillIDs).sorted(),
            autoPaste: autoPasteEnabled,
            copyTranscriptToClipboard: copyTranscriptToClipboardEnabled,
            restoreOriginalClipboardAfterPaste: restoreOriginalClipboardAfterPasteEnabled,
            transcriptScreenOCR: transcriptScreenOCREnabled,
            listeningMode: listeningMode,
            transcriptShortcut: transcriptShortcut,
            agentShortcut: agentShortcut,
            recordingShortcut: transcriptShortcut,
            runtimeMode: runtimeMode,
            feedbackShortcutEnabled: false,
            feedbackShortcut: feedbackShortcut
        )
    }

    func transcriptClipboardBehavior(autoPasteOverride: Bool? = nil) -> TranscriptClipboardBehavior {
        TranscriptClipboardBehavior(
            autoPasteEnabled: autoPasteOverride ?? autoPasteEnabled,
            copyTranscriptToClipboardEnabled: copyTranscriptToClipboardEnabled,
            restoreOriginalClipboardAfterPasteEnabled: restoreOriginalClipboardAfterPasteEnabled
        )
    }

    func resetIntentAgentPrompt() {
        intentAgentPrompt = ElsonPromptCatalog.defaultIntentAgentPrompt
    }

    func resetTranscriptAgentPrompt() {
        transcriptAgentPrompt = ElsonPromptCatalog.defaultTranscriptAgentPrompt
    }

    func resetWorkingAgentPrompt() {
        workingAgentPrompt = ElsonPromptCatalog.defaultWorkingAgentPrompt
    }

    func resetMasterSystemPrompt() {
        resetIntentAgentPrompt()
        resetTranscriptAgentPrompt()
        resetWorkingAgentPrompt()
    }

    func validateAndSaveAPIKeys(groq: String, cerebras: String, gemini: String) async throws {
        let sanitizedGroq = sanitizeSecret(groq)
        let sanitizedCerebras = sanitizeSecret(cerebras)
        let sanitizedGemini = sanitizeSecret(gemini)

        try await LocalAIService().validateGroqAPIKey(sanitizedGroq)
        try await LocalAIService().validateCerebrasAPIKey(sanitizedCerebras)
        try await LocalAIService().validateGeminiAPIKey(sanitizedGemini)

        groqAPIKey = sanitizedGroq
        cerebrasAPIKey = sanitizedCerebras
        geminiAPIKey = sanitizedGemini
    }

    func validateAndSaveGroqAPIKey(_ value: String) async throws {
        let sanitized = sanitizeSecret(value)
        if sanitized.isEmpty {
            groqAPIKey = ""
            return
        }

        try await LocalAIService().validateGroqAPIKey(sanitized)
        groqAPIKey = sanitized
    }

    func validateAndSaveCerebrasAPIKey(_ value: String) async throws {
        let sanitized = sanitizeSecret(value)
        if sanitized.isEmpty {
            cerebrasAPIKey = ""
            return
        }

        try await LocalAIService().validateCerebrasAPIKey(sanitized)
        cerebrasAPIKey = sanitized
    }

    func validateAndSaveGeminiAPIKey(_ value: String) async throws {
        let sanitized = sanitizeSecret(value)
        if sanitized.isEmpty {
            geminiAPIKey = ""
            return
        }

        try await LocalAIService().validateGeminiAPIKey(sanitized)
        geminiAPIKey = sanitized
    }

    func applyAgentMyElsonMarkdownUpdate(_ markdown: String) {
        let normalized = MyElsonDocument.normalizedMarkdown(from: markdown)
        guard normalized != myElsonMarkdown else { return }

        deferredMyElsonPersistenceTask?.cancel()
        deferImmediateMyElsonPersistence = true
        myElsonMarkdown = normalized
        deferImmediateMyElsonPersistence = false

        deferredMyElsonPersistenceTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard self.myElsonMarkdown == normalized else { return }

            UserDefaults.standard.set(normalized, forKey: Keys.myElsonMarkdown)
            if self.didCompleteFolderOnboarding,
               !ElsonLocalConfigStore.shared.saveWorkspaceMyElsonMarkdown(normalized) {
                DebugLog.runtimeError("agent_myelson_save_failed reason=workspace_write")
            }
            self.persistLocalConfig()
        }
    }

    var workspaceFolderPath: String? {
        ElsonLocalConfigStore.shared.selectedWorkspaceFolderPath()
    }

    var hasStoredWorkspaceFolderSelection: Bool {
        ElsonLocalConfigStore.shared.hasSelectedWorkspaceFolder()
    }

    var hasRequiredAPIKeys: Bool {
        !sanitizeSecret(groqAPIKey).isEmpty
            && !sanitizeSecret(cerebrasAPIKey).isEmpty
            && !sanitizeSecret(geminiAPIKey).isEmpty
    }

    var hasCompletedRequiredInstallSetup: Bool {
        hasRequiredAPIKeys
            && microphonePermissionGranted
            && screenRecordingPermissionGranted
            && accessibilityPermissionGranted
            && fullDiskAccessPermissionGranted
            && hasCompletedFolderOnboarding
            && didCompleteTranscriptShortcutOnboarding
            && didCompleteAgentShortcutOnboarding
    }

    var hasCompletedInstallOnboarding: Bool {
        hasCompletedRequiredInstallSetup && didCompleteOnboarding
    }

    var needsInstallOnboarding: Bool {
        !hasCompletedInstallOnboarding
    }

    var firstIncompleteInstallOnboardingStep: InstallOnboardingStep? {
        let hasCompletedFolderSetup = hasCompletedFolderOnboarding
        if !didCompleteInteractionModelOnboarding { return .interactionModel }
        if !hasRequiredAPIKeys { return .apiKeys }
        if !microphonePermissionGranted { return .microphone }
        if !screenRecordingPermissionGranted { return .screen }
        if !accessibilityPermissionGranted { return .accessibility }
        if !fullDiskAccessPermissionGranted { return .fullDiskAccess }
        if !hasCompletedFolderSetup { return .folder }
        if !didCompleteTranscriptShortcutOnboarding { return .transcriptShortcut }
        if !didCompleteAgentShortcutOnboarding { return .agentShortcut }
        if !didCompleteOnboarding { return .celebration }
        return nil
    }

    func maskedKey(for value: String) -> String {
        let trimmed = sanitizeSecret(value)
        guard !trimmed.isEmpty else { return "" }
        return String(repeating: "•", count: max(4, min(trimmed.count, 12)))
    }

    var hasFeedbackShortcutConflict: Bool {
        feedbackShortcutEnabled && !feedbackShortcut.isEmpty && feedbackShortcut == transcriptShortcut
    }

    @discardableResult
    func setFeedbackShortcutIfValid(_ shortcut: RecordingShortcut) -> Bool {
        guard shortcut != transcriptShortcut, shortcut != agentShortcut else { return false }
        feedbackShortcut = shortcut
        return true
    }

    func recordLastOutput(from result: RuntimeExecutionResult) {
        let snapshot = LastOutputSnapshot(
            processedText: result.replyText,
            rawTranscript: result.rawTranscript,
            replyMode: result.replyMode,
            sourceSurface: result.sourceSurface,
            requestId: result.requestId,
            threadId: result.responseThreadId,
            actualRoute: result.actualRoute,
            routingSource: result.routingSource,
            forcedRouteReason: result.forcedRouteReason,
            debugReason: result.debugReason,
            visibleOutputSource: result.visibleOutputSource,
            hasScreenContext: result.hasScreenContext
        )
        guard snapshot.isUsableForFeedback else { return }
        lastOutputSnapshot = snapshot
    }

    @discardableResult
    func beginFeedbackCapture() -> Bool {
        guard let lastOutputSnapshot, lastOutputSnapshot.isUsableForFeedback else { return false }
        activeFeedbackContext = ActiveFeedbackContext(snapshot: lastOutputSnapshot)
        return true
    }

    func endFeedbackCapture() {
        activeFeedbackContext = nil
    }

    @discardableResult
    func submitFeedback(
        subject: FeedbackSubject,
        rating: FeedbackRating,
        note: String,
        routeOverride: FeedbackRouteOverride
    ) async -> Bool {
        let entry = FeedbackEntry(
            rating: rating,
            note: note,
            expectedRouteOverride: routeOverride == .unchanged ? nil : routeOverride.rawValue,
            actualRoute: subject.actualRoute,
            requestId: subject.requestId,
            threadId: subject.threadId,
            createdAt: Date(),
            rawTranscript: subject.rawTranscript,
            processedText: subject.processedText,
            replyMode: subject.replyMode,
            sourceSurface: subject.sourceSurface
        )

        let saved = FeedbackLogStore.shared.append(entry)
        guard saved else {
            lastPromptLearningStatus = "Could not save feedback."
            lastPromptLearningAt = Date()
            return false
        }

        DebugLog.runtime(
            "feedback_submitted request_id=\(entry.requestId) thread_id=\(entry.threadId ?? "none") rating=\(entry.rating.rawValue) expected_route_override=\(entry.expectedRouteOverride ?? "none") actual_route=\(entry.actualRoute) source_surface=\(entry.sourceSurface) has_note=\(entry.note != nil)"
        )

        await learnFromFeedback(entry: entry, subject: subject)
        return true
    }

    func refreshOnboardingStoredFlag() {
        microphonePermissionGranted = PermissionCoordinator.hasMicrophonePermission()
        screenRecordingPermissionGranted = PermissionCoordinator.hasScreenRecordingPermission()
        accessibilityPermissionGranted = PermissionCoordinator.hasAccessibilityPermission()
        fullDiskAccessPermissionGranted = PermissionCoordinator.hasFullDiskAccessPermission()

        if !hasCompletedRequiredInstallSetup, didCompleteOnboarding {
            didCompleteOnboarding = false
        }
    }

    private func learnFromFeedback(entry: FeedbackEntry, subject: FeedbackSubject) async {
        let config = makeLocalConfig()
        guard !config.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastPromptLearningStatus = "Feedback saved. Prompt learning skipped: missing Gemini key."
            lastPromptLearningAt = Date()
            return
        }

        do {
            let result = try await LocalAIService().runPromptLearning(
                feedbackEntry: entry,
                subject: subject,
                transcriptPrompt: transcriptAgentPrompt,
                workingAgentPrompt: workingAgentPrompt,
                geminiAPIKey: config.geminiAPIKey
            )
            switch result.decision {
            case .noLearning:
                lastPromptLearningStatus = "Feedback saved. No prompt learning applied."
            case .updateTranscriptPrompt:
                guard let updatedPrompt = result.updatedPrompt else {
                    lastPromptLearningStatus = "Feedback saved. Gemini returned no transcript prompt update."
                    lastPromptLearningAt = Date()
                    return
                }
                let beforeHash = promptHash(transcriptAgentPrompt)
                transcriptAgentPrompt = ElsonPromptCatalog.normalizedTranscriptAgentPrompt(updatedPrompt)
                let afterHash = promptHash(transcriptAgentPrompt)
                lastPromptLearningStatus = "Feedback saved. Transcript prompt updated."
                DebugLog.runtime(
                    "prompt_learning_applied target=transcript request_id=\(entry.requestId) before_hash=\(beforeHash) after_hash=\(afterHash) reason=\(result.reason)"
                )
            case .updateWorkingAgentPrompt:
                guard let updatedPrompt = result.updatedPrompt else {
                    lastPromptLearningStatus = "Feedback saved. Gemini returned no working prompt update."
                    lastPromptLearningAt = Date()
                    return
                }
                let beforeHash = promptHash(workingAgentPrompt)
                workingAgentPrompt = ElsonPromptCatalog.normalizedWorkingAgentPrompt(updatedPrompt)
                let afterHash = promptHash(workingAgentPrompt)
                lastPromptLearningStatus = "Feedback saved. Working Agent prompt updated."
                DebugLog.runtime(
                    "prompt_learning_applied target=working_agent request_id=\(entry.requestId) before_hash=\(beforeHash) after_hash=\(afterHash) reason=\(result.reason)"
                )
            }
            lastPromptLearningAt = Date()
        } catch {
            lastPromptLearningStatus = "Feedback saved. Prompt learning failed: \(error.localizedDescription)"
            lastPromptLearningAt = Date()
            DebugLog.runtimeError(
                "prompt_learning_failed request_id=\(entry.requestId) actual_route=\(entry.actualRoute) error=\(error.localizedDescription)"
            )
        }
    }

    func refreshSkillsCatalog(force: Bool = false) async {
        guard skillsEnabled else {
            applySkillCatalogSnapshot(skills: [], lastScanAt: nil, lastError: nil)
            return
        }

        guard fullDiskAccessPermissionGranted else {
            applySkillCatalogSnapshot(
                skills: [],
                lastScanAt: nil,
                lastError: "Grant Full Disk Access first. Skill scanning starts only after that permission is enabled."
            )
            return
        }

        let snapshot = await SkillCatalogStore.shared.refresh(force: force)
        applySkillCatalogSnapshot(
            skills: snapshot.skills,
            lastScanAt: snapshot.lastScanAt,
            lastError: snapshot.lastError
        )
    }

    func selectedSkillPromptBundle(for transcript: String) async -> SkillPromptBundle? {
        guard skillsEnabled, fullDiskAccessPermissionGranted else { return nil }
        let snapshot = await SkillCatalogStore.shared.refresh(force: true)
        applySkillCatalogSnapshot(
            skills: snapshot.skills,
            lastScanAt: snapshot.lastScanAt,
            lastError: snapshot.lastError
        )

        switch await SkillCatalogStore.shared.selectSkill(for: transcript, in: activeSkills) {
        case .clearMatch(let skill):
            return await SkillCatalogStore.shared.promptBundle(for: skill.id)
        case .ambiguous, .none:
            return nil
        }
    }

    func filteredSkills(searchQuery: String) -> [RegisteredSkill] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = discoveredSkills
        guard !query.isEmpty else { return source }

        return source.filter { skill in
            skill.name.localizedCaseInsensitiveContains(query)
                || skill.description.localizedCaseInsensitiveContains(query)
                || skill.sourceFamily.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    func isSkillSelected(_ skill: RegisteredSkill) -> Bool {
        selectedSkillIDs.contains(skill.id)
    }

    func setSkillSelected(_ skill: RegisteredSkill, isSelected: Bool) {
        if isSelected {
            selectedSkillIDs.insert(skill.id)
        } else {
            selectedSkillIDs.remove(skill.id)
        }
    }

    func applySkillCatalogSnapshot(skills: [RegisteredSkill], lastScanAt: Date?, lastError: String?) {
        discoveredSkills = skills
        let validIDs = Set(skills.map(\.id))
        let prunedSelection = selectedSkillIDs.intersection(validIDs)
        if prunedSelection != selectedSkillIDs {
            selectedSkillIDs = prunedSelection
        }
        self.skillsLastScanAt = lastScanAt
        self.skillsLastScanError = lastError
    }

    func importWorkingDirectorySourcesIfNeeded() {
        guard didCompleteFolderOnboarding else { return }
        guard !didImportWorkingDirectorySourcesThisLaunch else { return }
        didImportWorkingDirectorySourcesThisLaunch = true

        guard let imported = ElsonLocalConfigStore.shared.loadWorkingDirectorySources() else { return }

        if groqAPIKey.isEmpty && !imported.groqAPIKey.isEmpty {
            groqAPIKey = imported.groqAPIKey
        }
        if cerebrasAPIKey.isEmpty && !imported.cerebrasAPIKey.isEmpty {
            cerebrasAPIKey = imported.cerebrasAPIKey
        }
        if geminiAPIKey.isEmpty && !imported.geminiAPIKey.isEmpty {
            geminiAPIKey = imported.geminiAPIKey
        }
        if myElsonMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !imported.myElsonMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            myElsonMarkdown = imported.myElsonMarkdown
        }
        if intentAgentPrompt == ElsonPromptCatalog.defaultIntentAgentPrompt,
           imported.intentAgentPrompt != ElsonPromptCatalog.defaultIntentAgentPrompt {
            intentAgentPrompt = imported.intentAgentPrompt
        }
        if transcriptAgentPrompt == ElsonPromptCatalog.defaultTranscriptAgentPrompt,
           imported.transcriptAgentPrompt != ElsonPromptCatalog.defaultTranscriptAgentPrompt {
            transcriptAgentPrompt = imported.transcriptAgentPrompt
        }
        if workingAgentPrompt == ElsonPromptCatalog.defaultWorkingAgentPrompt,
           imported.workingAgentPrompt != ElsonPromptCatalog.defaultWorkingAgentPrompt {
            workingAgentPrompt = imported.workingAgentPrompt
        }
        loadNormalizedMyElsonFromWorkspaceIfAvailable()
    }

    @discardableResult
    func completeFolderOnboardingStep() -> Bool {
        let granted = confirmStoredFolderOnboardingAccess()
        if granted {
            didCompleteFolderOnboarding = true
        }
        refreshOnboardingStoredFlag()
        return granted
    }

    @discardableResult
    func selectWorkspaceFolderForOnboarding() -> Bool {
        ElsonLocalConfigStore.shared.selectWorkspaceFolderForOnboarding()
    }

    @discardableResult
    func confirmStoredFolderOnboardingAccess() -> Bool {
        let csvInit = TranscriptHistoryStore.shared.initializeWorkspaceCSV()
        let ensureMyElson = ElsonLocalConfigStore.shared.ensureWorkspaceMyElsonFile(
            initialContents: MyElsonDocument.normalizedMarkdown(from: myElsonMarkdown)
        )
        let granted = csvInit && ensureMyElson

        if granted {
            didCompleteFolderOnboarding = true
            didImportWorkingDirectorySourcesThisLaunch = false
            importWorkingDirectorySourcesIfNeeded()
            syncWorkspaceMyElsonMarkdownIfPossible()
        }

        refreshOnboardingStoredFlag()
        return granted
    }

    @discardableResult
    func chooseDifferentWorkspaceFolder() -> Bool {
        guard ElsonLocalConfigStore.shared.selectWorkspaceFolderForOnboarding() else {
            refreshOnboardingStoredFlag()
            return false
        }
        didCompleteFolderOnboarding = false
        return completeFolderOnboardingStep()
    }

    @MainActor
    func hardReset() {
        deferredMyElsonPersistenceTask?.cancel()
        didCompleteOnboarding = false
        didCompleteInteractionModelOnboarding = false
        didCompleteFolderOnboarding = false
        didCompleteTranscriptShortcutOnboarding = false
        didCompleteAgentShortcutOnboarding = false
        muteSystemAudioDuringRecording = true
        launchAtLogin = true
        bubbleOnlyWhileRecording = false
        listeningMode = .hold
        transcriptShortcut = .default
        agentShortcut = .feedbackDefault
        recordingShortcut = .default
        feedbackShortcutEnabled = false
        feedbackShortcut = .feedbackDefault
        runtimeMode = .local
        autoPasteEnabled = true
        copyTranscriptToClipboardEnabled = false
        restoreOriginalClipboardAfterPasteEnabled = false
        transcriptScreenOCREnabled = true
        agentModeEnabled = true
        skillsEnabled = false
        skillSelectionScope = .all
        selectedSkillIDs = []
        audioDeciderProvider = Self.fixedTranscriptProvider
        agentProvider = Self.fixedAgentProvider
        myElsonMarkdown = ""
        intentAgentPrompt = ElsonPromptCatalog.defaultIntentAgentPrompt
        transcriptAgentPrompt = ElsonPromptCatalog.defaultTranscriptAgentPrompt
        workingAgentPrompt = ElsonPromptCatalog.defaultWorkingAgentPrompt
        pendingScreenshotJPEGData = []
        pendingAttachments = []
        isRecording = false
        lastOutputSnapshot = nil
        activeFeedbackContext = nil
        indicatorState = .idle
        groqAPIKey = ""
        cerebrasAPIKey = ""
        geminiAPIKey = ""

        UserDefaults.standard.removeObject(forKey: Keys.didCompleteOnboarding)
        UserDefaults.standard.removeObject(forKey: Keys.completedOnboardingAppVersion)
        UserDefaults.standard.removeObject(forKey: Keys.didCompleteInteractionModelOnboarding)
        UserDefaults.standard.removeObject(forKey: Keys.didCompleteFolderOnboarding)
        UserDefaults.standard.removeObject(forKey: Keys.didCompleteTranscriptShortcutOnboarding)
        UserDefaults.standard.removeObject(forKey: Keys.didCompleteAgentShortcutOnboarding)
        UserDefaults.standard.removeObject(forKey: Keys.didCompleteShortcutOnboarding)
        UserDefaults.standard.removeObject(forKey: Keys.muteSystemAudioDuringRecording)
        UserDefaults.standard.removeObject(forKey: Keys.launchAtLogin)
        UserDefaults.standard.removeObject(forKey: Keys.bubbleOnlyWhileRecording)
        UserDefaults.standard.removeObject(forKey: Keys.listeningMode)
        UserDefaults.standard.removeObject(forKey: Keys.transcriptShortcut)
        UserDefaults.standard.removeObject(forKey: Keys.agentShortcut)
        UserDefaults.standard.removeObject(forKey: Keys.recordingShortcut)
        UserDefaults.standard.removeObject(forKey: Keys.feedbackShortcutEnabled)
        UserDefaults.standard.removeObject(forKey: Keys.feedbackShortcut)
        UserDefaults.standard.removeObject(forKey: Keys.autoPasteEnabled)
        UserDefaults.standard.removeObject(forKey: Keys.copyTranscriptToClipboardEnabled)
        UserDefaults.standard.removeObject(forKey: Keys.restoreOriginalClipboardAfterPasteEnabled)
        UserDefaults.standard.removeObject(forKey: Keys.transcriptScreenOCREnabled)
        UserDefaults.standard.removeObject(forKey: Keys.agentModeEnabled)
        UserDefaults.standard.removeObject(forKey: Keys.skillsEnabled)
        UserDefaults.standard.removeObject(forKey: Keys.skillSelectionScope)
        UserDefaults.standard.removeObject(forKey: Keys.selectedSkillIDs)
        UserDefaults.standard.removeObject(forKey: Keys.myElsonMarkdown)
        UserDefaults.standard.removeObject(forKey: Keys.intentAgentPrompt)
        UserDefaults.standard.removeObject(forKey: Keys.transcriptAgentPrompt)
        UserDefaults.standard.removeObject(forKey: Keys.workingAgentPrompt)
        UserDefaults.standard.removeObject(forKey: Keys.masterSystemPrompt)
        UserDefaults.standard.removeObject(forKey: Keys.legacyAgentSystemPrompt)
        UserDefaults.standard.removeObject(forKey: Keys.legacyOpenClawBaseURL)
        UserDefaults.standard.removeObject(forKey: Keys.runtimeMode)
        UserDefaults.standard.removeObject(forKey: Keys.audioDeciderProvider)
        UserDefaults.standard.removeObject(forKey: Keys.agentProvider)
        ElsonLocalConfigStore.shared.clearSelectedWorkspaceFolder()
        ElsonLocalConfigStore.shared.save(.default)
        TranscriptHistoryStore.shared.clear()
        transcriptHistory = []
        lastOutputSnapshot = nil
        activeFeedbackContext = nil
        didImportWorkingDirectorySourcesThisLaunch = false
    }

    private func updateLaunchAtLoginRegistration() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch-at-login update failed: \(error)")
        }
    }

    private func loadSettings() {
        deferredMyElsonPersistenceTask?.cancel()
        isHydratingMyElsonState = true
        defer { isHydratingMyElsonState = false }
        print("[SETTINGS] ═══════════════════════════════════════════")
        print("[SETTINGS] loadSettings() START")
        print("[SETTINGS] hasStoredWorkspaceFolderSelection=\(hasStoredWorkspaceFolderSelection)")
        let storedConfig = ElsonLocalConfigStore.shared.load(includeWorkingDirectorySources: false)
        print("[SETTINGS] storedConfig keys: groq=\(storedConfig.groqAPIKey.isEmpty ? "EMPTY" : "SET") cerebras=\(storedConfig.cerebrasAPIKey.isEmpty ? "EMPTY" : "SET") gemini=\(storedConfig.geminiAPIKey.isEmpty ? "EMPTY" : "SET")")
        let workspaceConfig = hasStoredWorkspaceFolderSelection
            ? ElsonLocalConfigStore.shared.loadWorkingDirectorySources()
            : nil
        print("[SETTINGS] workspaceConfig: \(workspaceConfig == nil ? "NIL (no bookmark)" : "groq=\(workspaceConfig!.groqAPIKey.isEmpty ? "EMPTY" : "SET") cerebras=\(workspaceConfig!.cerebrasAPIKey.isEmpty ? "EMPTY" : "SET") gemini=\(workspaceConfig!.geminiAPIKey.isEmpty ? "EMPTY" : "SET")")")
        let migrationConfig = ElsonLocalConfigStore.shared.loadExternalApplicationSupportMigrationConfig()
        print("[SETTINGS] migrationConfig: \(migrationConfig == nil ? "NIL" : "groq=\(migrationConfig!.groqAPIKey.isEmpty ? "EMPTY" : "SET")")")
        let legacyPrompt =
            UserDefaults.standard.string(forKey: Keys.masterSystemPrompt)
            ?? ElsonPromptCatalog.migratedPriorAgentPrompt(UserDefaults.standard.string(forKey: Keys.legacyAgentSystemPrompt))
        let completedOnboardingAppVersion = UserDefaults.standard.string(forKey: Keys.completedOnboardingAppVersion)
        let storedDidCompleteOnboarding = UserDefaults.standard.object(forKey: Keys.didCompleteOnboarding) as? Bool ?? false
        print("[SETTINGS] currentAppVersion=\(Self.currentAppVersion) storedVersion=\(completedOnboardingAppVersion ?? "nil") storedOnboarding=\(storedDidCompleteOnboarding)")

        didCompleteOnboarding = storedDidCompleteOnboarding && completedOnboardingAppVersion == Self.currentAppVersion
        didCompleteInteractionModelOnboarding = UserDefaults.standard.object(forKey: Keys.didCompleteInteractionModelOnboarding) as? Bool ?? false
        didCompleteFolderOnboarding = UserDefaults.standard.object(forKey: Keys.didCompleteFolderOnboarding) as? Bool ?? false
        let legacyDidCompleteShortcut = UserDefaults.standard.object(forKey: Keys.didCompleteShortcutOnboarding) as? Bool ?? false
        didCompleteTranscriptShortcutOnboarding = UserDefaults.standard.object(forKey: Keys.didCompleteTranscriptShortcutOnboarding) as? Bool ?? legacyDidCompleteShortcut
        didCompleteAgentShortcutOnboarding = UserDefaults.standard.object(forKey: Keys.didCompleteAgentShortcutOnboarding) as? Bool ?? false
        muteSystemAudioDuringRecording = UserDefaults.standard.object(forKey: Keys.muteSystemAudioDuringRecording) as? Bool ?? true
        launchAtLogin = UserDefaults.standard.object(forKey: Keys.launchAtLogin) as? Bool ?? true
        bubbleOnlyWhileRecording = UserDefaults.standard.object(forKey: Keys.bubbleOnlyWhileRecording) as? Bool ?? false
        listeningMode = ListeningMode(rawValue: UserDefaults.standard.string(forKey: Keys.listeningMode) ?? storedConfig.listeningMode.rawValue) ?? storedConfig.listeningMode
        transcriptShortcut = UserDefaults.standard.string(forKey: Keys.transcriptShortcut)
            .map(RecordingShortcut.init(storageValue:))
            ?? UserDefaults.standard.string(forKey: Keys.recordingShortcut)
            .map(RecordingShortcut.init(storageValue:))
            ?? storedConfig.transcriptShortcut
        agentShortcut = UserDefaults.standard.string(forKey: Keys.agentShortcut)
            .map(RecordingShortcut.init(storageValue:))
            ?? storedConfig.agentShortcut
        if agentShortcut == transcriptShortcut {
            agentShortcut = .feedbackDefault
        }
        recordingShortcut = transcriptShortcut
        feedbackShortcutEnabled = UserDefaults.standard.object(forKey: Keys.feedbackShortcutEnabled) as? Bool ?? storedConfig.feedbackShortcutEnabled
        feedbackShortcut = UserDefaults.standard.string(forKey: Keys.feedbackShortcut)
            .map(RecordingShortcut.init(storageValue:))
            ?? storedConfig.feedbackShortcut
        runtimeMode = RuntimeMode(rawValue: UserDefaults.standard.string(forKey: Keys.runtimeMode) ?? storedConfig.runtimeMode.rawValue) ?? storedConfig.runtimeMode
        autoPasteEnabled = UserDefaults.standard.object(forKey: Keys.autoPasteEnabled) as? Bool ?? storedConfig.autoPaste
        copyTranscriptToClipboardEnabled =
            UserDefaults.standard.object(forKey: Keys.copyTranscriptToClipboardEnabled) as? Bool
            ?? storedConfig.copyTranscriptToClipboard
        restoreOriginalClipboardAfterPasteEnabled =
            UserDefaults.standard.object(forKey: Keys.restoreOriginalClipboardAfterPasteEnabled) as? Bool
            ?? storedConfig.restoreOriginalClipboardAfterPaste
        transcriptScreenOCREnabled =
            UserDefaults.standard.object(forKey: Keys.transcriptScreenOCREnabled) as? Bool
            ?? storedConfig.transcriptScreenOCR
        agentModeEnabled = true
        skillsEnabled = UserDefaults.standard.object(forKey: Keys.skillsEnabled) as? Bool ?? storedConfig.skillsEnabled
        skillSelectionScope =
            UserDefaults.standard.string(forKey: Keys.skillSelectionScope)
            .flatMap(SkillSelectionScope.init(rawValue:))
            ?? storedConfig.skillSelectionScope
        selectedSkillIDs = Set(
            (UserDefaults.standard.array(forKey: Keys.selectedSkillIDs) as? [String])
                ?? storedConfig.selectedSkillIDs
        )
        audioDeciderProvider = Self.fixedTranscriptProvider
        agentProvider = Self.fixedAgentProvider
        let defaultMyElsonMarkdown = MyElsonDocument.normalizedMarkdown(from: "")
        let storedMyElsonMarkdown = UserDefaults.standard.string(forKey: Keys.myElsonMarkdown)
        myElsonMarkdown = storedMyElsonMarkdown ?? storedConfig.myElsonMarkdown
        let wsIntent = workspaceConfig?.intentAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? workspaceConfig?.intentAgentPrompt : nil
        let wsTranscript = workspaceConfig?.transcriptAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? workspaceConfig?.transcriptAgentPrompt : nil
        let wsWorking = workspaceConfig?.workingAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? workspaceConfig?.workingAgentPrompt : nil

        intentAgentPrompt = ElsonPromptCatalog.normalizedIntentAgentPrompt(
            UserDefaults.standard.string(forKey: Keys.intentAgentPrompt)
                ?? wsIntent
                ?? legacyPrompt
                ?? storedConfig.intentAgentPrompt
        )
        transcriptAgentPrompt = ElsonPromptCatalog.normalizedTranscriptAgentPrompt(
            UserDefaults.standard.string(forKey: Keys.transcriptAgentPrompt)
                ?? wsTranscript
                ?? storedConfig.transcriptAgentPrompt
        )
        workingAgentPrompt = ElsonPromptCatalog.normalizedWorkingAgentPrompt(
            UserDefaults.standard.string(forKey: Keys.workingAgentPrompt)
                ?? wsWorking
                ?? legacyPrompt
                ?? storedConfig.workingAgentPrompt
        )
        groqAPIKey = firstNonEmptySecret(storedConfig.groqAPIKey, migrationConfig?.groqAPIKey, workspaceConfig?.groqAPIKey) ?? ""
        cerebrasAPIKey = firstNonEmptySecret(storedConfig.cerebrasAPIKey, migrationConfig?.cerebrasAPIKey, workspaceConfig?.cerebrasAPIKey) ?? ""
        geminiAPIKey = firstNonEmptySecret(storedConfig.geminiAPIKey, migrationConfig?.geminiAPIKey, workspaceConfig?.geminiAPIKey) ?? ""
        print("[SETTINGS] FINAL keys: groq=\(groqAPIKey.isEmpty ? "EMPTY" : "SET(\(groqAPIKey.prefix(8))…)") cerebras=\(cerebrasAPIKey.isEmpty ? "EMPTY" : "SET") gemini=\(geminiAPIKey.isEmpty ? "EMPTY" : "SET")")
        print("[SETTINGS] hasRequiredAPIKeys=\(hasRequiredAPIKeys) didCompleteOnboarding=\(didCompleteOnboarding) needsInstallOnboarding=\(needsInstallOnboarding)")
        print("[SETTINGS] ═══════════════════════════════════════════")
        transcriptHistory = TranscriptHistoryStore.shared.load()
        lastOutputSnapshot = nil
        activeFeedbackContext = nil

        refreshOnboardingStoredFlag()
        loadNormalizedMyElsonFromWorkspaceIfAvailable()
        if myElsonMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            myElsonMarkdown = defaultMyElsonMarkdown
        }
    }

    private func handleIndicatorStateDidChange(to newValue: IndicatorState) {
        indicatorResetTask?.cancel()
        indicatorResetTask = nil
        guard newValue == .success || newValue == .agentSuccess || newValue == .error else { return }

        indicatorResetTask = Task { @MainActor in
            let delay: UInt64
            switch newValue {
            case .success:
                delay = 1_500_000_000
            case .agentSuccess:
                delay = 1_200_000_000
            case .error:
                delay = 2_500_000_000
            default:
                delay = 1_500_000_000
            }
            try? await Task.sleep(nanoseconds: delay)
            if self.indicatorState == newValue {
                self.indicatorState = .idle
            }
        }
    }

    private var hasCompletedFolderOnboarding: Bool {
        // Keep onboarding step calculation side-effect free.
        // Actual workspace verification happens only in the explicit folder-access flow.
        didCompleteFolderOnboarding
    }

    private func persistLocalConfig() {
        guard !isHydratingMyElsonState else { return }
        ElsonLocalConfigStore.shared.save(makeLocalConfig())
    }

    private func syncWorkspaceMyElsonMarkdownIfPossible() {
        guard didCompleteFolderOnboarding else { return }
        // Do not rewrite the bound editor text while the user is typing.
        // Immediate normalization here causes TextEditor to reset selection
        // and jump the insertion point toward the end of the document.
        let valueToSave = myElsonMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? MyElsonDocument.normalizedMarkdown(from: "")
            : myElsonMarkdown
        _ = ElsonLocalConfigStore.shared.saveWorkspaceMyElsonMarkdown(valueToSave)
    }

    private func loadNormalizedMyElsonFromWorkspaceIfAvailable() {
        guard didCompleteFolderOnboarding else { return }
        guard let workspaceMarkdown = ElsonLocalConfigStore.shared.loadWorkspaceMyElsonMarkdown(),
              !workspaceMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        let normalized = MyElsonDocument.normalizedMarkdown(from: workspaceMarkdown)
        if normalized != myElsonMarkdown {
            myElsonMarkdown = normalized
        }
    }

    private func sanitizeSecret(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func firstNonEmptySecret(_ values: String?...) -> String? {
        for value in values {
            let sanitized = sanitizeSecret(value ?? "")
            if !sanitized.isEmpty {
                return sanitized
            }
        }
        return nil
    }

    private func promptHash(_ prompt: String) -> String {
        let digest = SHA256.hash(data: Data(prompt.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func appendTranscriptHistory(
        text: String,
        rawTranscript: String?,
        source: String,
        threadId: String? = nil,
        replyMode: String? = nil,
        actualRoute: String? = nil,
        routingSource: String? = nil,
        forcedRouteReason: String? = nil,
        requestId: String? = nil
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let trimmedRawTranscript = rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = TranscriptHistoryEntry(
            text: trimmedText,
            rawTranscript: trimmedRawTranscript == trimmedText ? nil : trimmedRawTranscript,
            source: source,
            threadId: threadId,
            replyMode: replyMode,
            actualRoute: actualRoute,
            routingSource: routingSource,
            forcedRouteReason: forcedRouteReason
        )

        transcriptHistory.insert(entry, at: 0)
        transcriptHistory = Array(transcriptHistory.prefix(25))
        persistTranscriptHistory()
        TranscriptHistoryStore.shared.exportToWorkspaceCSV(entry)
        scheduleHistorySummaryGeneration(for: entry, requestId: requestId)
    }

    func openHistoryThread(_ entry: TranscriptHistoryEntry, chatStore: ChatStore) {
        guard let threadId = entry.threadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !threadId.isEmpty
        else {
            return
        }

        chatStore.openPersistedThread(
            id: threadId,
            fallbackMessages: historyFallbackMessages(for: entry)
        )
        chatStore.markThreadRead(threadId)

        let normalizedReplyMode = entry.replyMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalizedReplyMode == "transcript" {
            ThreadModeStore.set(threadId: threadId, target: .transcript)
        } else if !normalizedReplyMode.isEmpty {
            ThreadModeStore.set(threadId: threadId, target: .agent)
        }

        NotificationCenter.default.post(name: .openThreadWindow, object: nil)
    }

    private func scheduleHistorySummaryGeneration(for entry: TranscriptHistoryEntry, requestId: String?) {
        let config = makeLocalConfig()
        let startedAt = Date()

        Task {
            let summaryTitle = try? await LocalAIService().generateHistorySummaryTitle(
                text: entry.text,
                rawTranscript: entry.rawTranscript,
                source: entry.source,
                replyMode: entry.replyMode,
                provider: Self.fixedTranscriptProvider,
                cerebrasAPIKey: config.cerebrasAPIKey,
                geminiAPIKey: config.geminiAPIKey
            )
            updateTranscriptHistorySummary(id: entry.id, summaryTitle: summaryTitle)
            if let requestId {
                DebugLog.requestBackgroundTail(
                    requestId: requestId,
                    threadId: entry.threadId ?? "",
                    surface: entry.source,
                    inputSource: entry.rawTranscript == nil ? "text" : "audio",
                    task: "history_title_generation",
                    durationMS: Int(Date().timeIntervalSince(startedAt) * 1000)
                )
            }
        }
    }

    private func updateTranscriptHistorySummary(id: UUID, summaryTitle: String?) {
        guard let index = transcriptHistory.firstIndex(where: { $0.id == id }) else { return }
        let normalizedTitle = summaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcriptHistory[index].summaryTitle != normalizedTitle else { return }
        transcriptHistory[index] = transcriptHistory[index].withSummaryTitle(normalizedTitle)
        persistTranscriptHistory()
    }

    private func persistTranscriptHistory() {
        TranscriptHistoryStore.shared.save(transcriptHistory)
    }

    private func historyFallbackMessages(for entry: TranscriptHistoryEntry) -> [ChatMessage] {
        let normalizedReplyMode = entry.replyMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let cleanedText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTranscript = entry.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var messages: [ChatMessage] = []

        if !rawTranscript.isEmpty {
            let userContent = normalizedReplyMode == "transcript"
                ? (cleanedText.isEmpty ? rawTranscript : cleanedText)
                : rawTranscript
            messages.append(
                ChatMessage(
                    role: .user,
                    content: userContent,
                    style: .voiceTranscript,
                    rawTranscript: rawTranscript
                )
            )
        }

        if normalizedReplyMode == "transcript" {
            if messages.isEmpty, !cleanedText.isEmpty {
                messages.append(ChatMessage(role: .user, content: cleanedText))
            } else if !cleanedText.isEmpty, rawTranscript.caseInsensitiveCompare(cleanedText) != .orderedSame {
                messages.append(ChatMessage(role: .assistant, content: cleanedText))
            }
        } else if !cleanedText.isEmpty {
            messages.append(ChatMessage(role: .assistant, content: cleanedText))
        }

        return messages
    }
}
