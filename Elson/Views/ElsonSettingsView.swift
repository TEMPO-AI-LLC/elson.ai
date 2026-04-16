import AppKit
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case history = "History"
    case myElson = "Elson.md"
    case settings = "Settings"

    var id: String { rawValue }
}

@MainActor
struct ElsonSettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(ChatStore.self) private var chatStore
    let recordingService: AudioRecordingService

    @State private var selectedTab: SettingsTab = .history
    @State private var expandedHistoryIds: Set<UUID> = []
    @State private var permissionRefreshToken = UUID()
    @State private var isEditingGroqKey = false
    @State private var isEditingCerebrasKey = false
    @State private var isEditingGeminiKey = false
    @State private var isGrantingFolderAccess = false
    @State private var groqDraftKey = ""
    @State private var cerebrasDraftKey = ""
    @State private var geminiDraftKey = ""
    @State private var groqKeyStatus: String? = nil
    @State private var cerebrasKeyStatus: String? = nil
    @State private var geminiKeyStatus: String? = nil
    @State private var isSavingGroqKey = false
    @State private var isSavingCerebrasKey = false
    @State private var isSavingGeminiKey = false
    @State private var isRefreshingSkills = false
    @State private var isSkillsListExpanded = false
    @State private var skillSearchQuery = ""

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Elson.ai")
                .font(.system(size: 34, weight: .semibold))

            tabStrip

            ScrollView(showsIndicators: false) {
                Group {
                    switch selectedTab {
                    case .history:
                        historyTab
                    case .myElson:
                        myElsonTab
                    case .settings:
                        settingsTab
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }
        }
        .padding(28)
        .frame(minWidth: 860, minHeight: 700)
        .onAppear {
            syncAPIKeyDraftsFromSettings()
            refreshSkills(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshToken = UUID()
            refreshSkills(force: true)
        }
        .onChange(of: appSettings.skillsEnabled) { _, enabled in
            refreshSkills(force: enabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsElsonMDTab)) { _ in
            selectedTab = .myElson
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 10) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selectedTab == tab ? Color.white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selectedTab == tab ? Color.blue : Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    private var historyTab: some View {
        VStack(spacing: 24) {
            if appSettings.transcriptHistory.isEmpty {
                ElsonSettingsCard(title: "No transcript history yet") {
                    Text("Start speaking with Elson.ai and your cleaned results will appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 640)
            } else {
                VStack(spacing: 14) {
                    ForEach(appSettings.transcriptHistory) { entry in
                        transcriptHistoryCard(entry)
                    }
                }
                .frame(maxWidth: 640)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func transcriptHistoryCard(_ entry: TranscriptHistoryEntry) -> some View {
        let isExpanded = expandedHistoryIds.contains(entry.id)
        let card = ElsonSettingsCard(title: historyTitle(for: entry)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(historyPreview(for: entry))
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? nil : 3)

                    Spacer(minLength: 12)

                    CopyFeedbackButton(text: entry.text)
                }

                HStack(alignment: .center, spacing: 8) {
                    Text(historyMetadata(for: entry))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    if entry.isNavigable {
                        Label("Open chat", systemImage: "arrow.up.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                if let routingDetails = historyRoutingDetails(for: entry) {
                    Text(routingDetails)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if let rawTranscript = entry.rawTranscript, !rawTranscript.isEmpty {
                    Button(isExpanded ? "Hide original transcript" : "Show original transcript") {
                        toggleHistoryExpansion(for: entry.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                    if isExpanded {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Original transcript")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(rawTranscript)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }

        if entry.isNavigable {
            card
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture {
                    openHistoryThread(entry)
                }
        } else {
            card
        }
    }

    private var myElsonTab: some View {
        @Bindable var appSettings = appSettings

        return VStack(spacing: 24) {
            ElsonSettingsCard(title: "Elson.md") {
                TextEditor(text: $appSettings.myElsonMarkdown)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 280)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )

                HStack {
                    Text("Intent Agent Prompt")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Reset") {
                        appSettings.resetIntentAgentPrompt()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text("Base rules for routing, reply detection, and new-thread decisions.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextEditor(text: $appSettings.intentAgentPrompt)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )

                HStack {
                    Text("Transcript Agent Prompt")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Reset") {
                        appSettings.resetTranscriptAgentPrompt()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text("Base rules for business-ready transcript polish.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextEditor(text: $appSettings.transcriptAgentPrompt)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )

                HStack {
                    Text("Working Agent Prompt")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Reset") {
                        appSettings.resetWorkingAgentPrompt()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text("Base rules for replies, memory updates, and repair.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextEditor(text: $appSettings.workingAgentPrompt)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
            }
            .frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var settingsTab: some View {
        @Bindable var appSettings = appSettings

        return VStack(spacing: 28) {
            ElsonSettingsCard(title: "API Keys") {
                ElsonMaskedAPIKeyEditor(
                    title: "Groq",
                    persistedValue: appSettings.groqAPIKey,
                    draftValue: $groqDraftKey,
                    isEditing: $isEditingGroqKey,
                    isSaving: isSavingGroqKey,
                    statusText: groqKeyStatus,
                    maskedValue: appSettings.maskedKey(for: appSettings.groqAPIKey),
                    onSave: saveGroqKey,
                    onCancel: cancelGroqKeyEditing
                )

                ElsonMaskedAPIKeyEditor(
                    title: "Cerebras",
                    persistedValue: appSettings.cerebrasAPIKey,
                    draftValue: $cerebrasDraftKey,
                    isEditing: $isEditingCerebrasKey,
                    isSaving: isSavingCerebrasKey,
                    statusText: cerebrasKeyStatus,
                    maskedValue: appSettings.maskedKey(for: appSettings.cerebrasAPIKey),
                    onSave: saveCerebrasKey,
                    onCancel: cancelCerebrasKeyEditing
                )

                ElsonMaskedAPIKeyEditor(
                    title: "Gemini",
                    persistedValue: appSettings.geminiAPIKey,
                    draftValue: $geminiDraftKey,
                    isEditing: $isEditingGeminiKey,
                    isSaving: isSavingGeminiKey,
                    statusText: geminiKeyStatus,
                    maskedValue: appSettings.maskedKey(for: appSettings.geminiAPIKey),
                    onSave: saveGeminiKey,
                    onCancel: cancelGeminiKeyEditing
                )
            }

            ElsonSettingsCard(title: "Modes") {
                VStack(spacing: 14) {
                    HStack {
                        Text("Transcript")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("Groq STT + OCR, then Cerebras")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Agent")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("Groq STT + screenshot to Gemini 3.1 Flash Lite")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ElsonSettingsCard(title: "Shortcuts") {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcript Shortcut")
                            .font(.system(size: 13, weight: .semibold))
                        RecordingShortcutCaptureButton(shortcut: $appSettings.transcriptShortcut)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Agent Shortcut")
                            .font(.system(size: 13, weight: .semibold))
                        RecordingShortcutCaptureButton(shortcut: $appSettings.agentShortcut)
                    }

                    if appSettings.hasShortcutConflict {
                        Text("Transcript and Agent shortcuts must differ.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Both shortcuts save instantly.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if appSettings.transcriptShortcut == RecordingShortcut(modifiers: [.function]) || appSettings.agentShortcut == RecordingShortcut(modifiers: [.function]) {
                        Link("fn may open Emoji & Symbols. Open Keyboard Settings.", destination: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ElsonSettingsCard(title: "Chat") {
                Text("Each chat thread now has its own Transcript / Agent toggle. New threads require a mode before sending.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            ElsonSettingsCard(title: "Permissions") {
                ElsonPermissionRow(
                    title: "Microphone",
                    detail: microphonePermissionDetail,
                    actionTitle: PermissionCoordinator.hasMicrophonePermission() ? "Open Settings" : "Grant Access",
                    action: PermissionCoordinator.openMicrophoneSettings
                )

                ElsonPermissionRow(
                    title: "Screen Recording",
                    detail: screenRecordingPermissionDetail,
                    actionTitle: PermissionCoordinator.hasScreenRecordingPermission() ? "Open Settings" : "Grant Access",
                    action: PermissionCoordinator.openScreenRecordingSettings
                )

                ElsonPermissionRow(
                    title: "Accessibility",
                    detail: PermissionCoordinator.hasAccessibilityPermission()
                        ? "Granted."
                        : "Not granted or not detectable yet. Useful if macOS blocks global-control behavior after reinstall.",
                    actionTitle: "Open Settings",
                    action: PermissionCoordinator.openAccessibilitySettings
                )

                ElsonPermissionRow(
                    title: "Full Disk Access",
                    detail: PermissionCoordinator.hasFullDiskAccessPermission()
                        ? "Granted. Elson can scan local skill folders."
                        : "Required for external skill discovery outside the workspace. Enable Elson in Privacy & Security > Full Disk Access.",
                    actionTitle: "Open Settings",
                    action: PermissionCoordinator.openFullDiskAccessSettings
                )

                ElsonPermissionRow(
                    title: "Folder",
                    detail: appSettings.workspaceFolderPath
                        ?? "Elson stores MyElson context and daily transcript CSV exports in ~/Documents/Elson by default.",
                    actionTitle: isGrantingFolderAccess
                        ? "Choosing…"
                        : (
                            appSettings.hasStoredWorkspaceFolderSelection && !appSettings.didCompleteFolderOnboarding
                                ? "Allow Folder Access"
                                : (appSettings.hasStoredWorkspaceFolderSelection ? "Change Folder" : "Choose Custom Folder")
                        ),
                    action: {
                        guard !isGrantingFolderAccess else { return }
                        isGrantingFolderAccess = true
                        Task { @MainActor in
                            if appSettings.hasStoredWorkspaceFolderSelection && !appSettings.didCompleteFolderOnboarding {
                                _ = appSettings.completeFolderOnboardingStep()
                            } else {
                                _ = appSettings.chooseDifferentWorkspaceFolder()
                            }
                            isGrantingFolderAccess = false
                        }
                    }
                )
            }

            ElsonSettingsCard(title: "Recording") {
                Picker("Listening Mode", selection: $appSettings.listeningMode) {
                    ForEach(ListeningMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(recordingModeDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("Auto-paste into active field", isOn: $appSettings.autoPasteEnabled)
                Toggle("Automatically copy transcript to clipboard", isOn: $appSettings.copyTranscriptToClipboardEnabled)
                Toggle(
                    "Restore original clipboard after paste",
                    isOn: $appSettings.restoreOriginalClipboardAfterPasteEnabled
                )
                .disabled(!appSettings.autoPasteEnabled)
                Toggle("Mute system audio during recording", isOn: $appSettings.muteSystemAudioDuringRecording)
            }

            ElsonSettingsCard(title: "Skills") {
                Toggle("Skills enabled", isOn: $appSettings.skillsEnabled)

                if appSettings.skillsEnabled {
                    if !appSettings.fullDiskAccessPermissionGranted {
                        Text("Grant Full Disk Access first. Elson will only start scanning for skills after that permission is enabled.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Open Full Disk Access") {
                            PermissionCoordinator.openFullDiskAccessSettings()
                        }
                        .buttonStyle(.bordered)
                    }

                    Picker("Skill scope", selection: $appSettings.skillSelectionScope) {
                        ForEach(SkillSelectionScope.allCases, id: \.self) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!appSettings.fullDiskAccessPermissionGranted)

                    if isRefreshingSkills, appSettings.fullDiskAccessPermissionGranted {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading skills…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }

                    Text(appSettings.skillsLastScanError ?? skillsCountSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let skillsLastScanAt = appSettings.skillsLastScanAt {
                        Text("Last scan: \(skillsLastScanAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        refreshSkills(force: true)
                    } label: {
                        HStack(spacing: 8) {
                            if isRefreshingSkills {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isRefreshingSkills ? "Refreshing Skills…" : "Refresh Skills")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshingSkills || !appSettings.fullDiskAccessPermissionGranted)

                    TextField("Search skills", text: $skillSearchQuery)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!appSettings.fullDiskAccessPermissionGranted)

                    if !appSettings.fullDiskAccessPermissionGranted {
                        EmptyView()
                    } else if appSettings.discoveredSkills.isEmpty {
                        Text("No SKILL.md files found.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if appSettings.skillSelectionScope == .selectedOnly, appSettings.selectedSkillsCount == 0 {
                        Text("No skills selected. Search and tick the skills you want Elson to use.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isSkillsListExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isSkillsListExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(isSkillsListExpanded ? "Hide skill list" : "Show skill list (\(appSettings.discoveredSkills.count))")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)

                        if isSkillsListExpanded {
                            VStack(spacing: 10) {
                                ForEach(filteredSkills) { skill in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            if appSettings.skillSelectionScope == .selectedOnly {
                                                Toggle(
                                                    isOn: Binding(
                                                        get: { appSettings.isSkillSelected(skill) },
                                                        set: { newValue in
                                                            appSettings.setSkillSelected(skill, isSelected: newValue)
                                                        }
                                                    )
                                                ) {
                                                    Text(skill.name)
                                                        .font(.system(size: 13, weight: .semibold))
                                                }
                                                .toggleStyle(.checkbox)
                                            } else {
                                                Text(skill.name)
                                                    .font(.system(size: 13, weight: .semibold))
                                            }
                                            Spacer()
                                            Text(skill.sourceFamily.rawValue)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.secondary)
                                        }

                                        Text(skill.description)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        Text(skill.displayPath)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(12)
                                    .background(Color.primary.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }
                    }
                }
            }

            ElsonSettingsCard(title: "Debug") {
                Text(DebugLog.logsDirectoryURL().path)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Tail logs with `tail -f ~/Library/Application Support/Elson/Logs/llm.log` or `runtime.log`.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Open Logs Folder") {
                    DebugLog.openLogsFolder()
                }
                .buttonStyle(.bordered)
            }

            ElsonSettingsCard(title: "App") {
                Toggle("Launch at login", isOn: $appSettings.launchAtLogin)
                Toggle("Show Elson.ai Bubble ONLY when recording", isOn: $appSettings.bubbleOnlyWhileRecording)

                HStack(spacing: 12) {
                    Button("Open Chat") {
                        NotificationCenter.default.post(name: .openThreadWindow, object: nil)
                    }
                    .buttonStyle(.bordered)

                    Button("Reset Local State", role: .destructive) {
                        if recordingService.isRecording {
                            _ = recordingService.stopRecording()
                        }
                        chatStore.hardReset()
                        appSettings.hardReset()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .id(permissionRefreshToken)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var recordingModeDescription: String {
        switch appSettings.listeningMode {
        case .hold:
            return "Hold to record. Release to stop."
        case .toggle:
            return "Press once to start. Release. Press again to stop."
        }
    }

    private var filteredSkills: [RegisteredSkill] {
        appSettings.filteredSkills(searchQuery: skillSearchQuery)
    }

    private var skillsCountSummary: String {
        let total = appSettings.discoveredSkills.count
        switch appSettings.skillSelectionScope {
        case .all:
            return "Found \(total) skill\(total == 1 ? "" : "s"). All are active."
        case .selectedOnly:
            let selected = appSettings.selectedSkillsCount
            return "Found \(total) skill\(total == 1 ? "" : "s"). \(selected) selected."
        }
    }

    private func refreshSkills(force: Bool) {
        guard !isRefreshingSkills else { return }
        isRefreshingSkills = true
        Task { @MainActor in
            await appSettings.refreshSkillsCatalog(force: force)
            isRefreshingSkills = false
        }
    }

    private func historyTitle(for entry: TranscriptHistoryEntry) -> String {
        "\(entry.displayTitle) • \(Self.historyDateFormatter.string(from: entry.createdAt))"
    }

    private func historyPreview(for entry: TranscriptHistoryEntry) -> String {
        entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func historyMetadata(for entry: TranscriptHistoryEntry) -> String {
        let source = entry.source.capitalized
        let mode = historyModeLabel(for: entry)
        return [source, mode].joined(separator: " • ")
    }

    private func historyModeLabel(for entry: TranscriptHistoryEntry) -> String {
        let normalizedReplyMode = entry.replyMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalizedReplyMode == "transcript" {
            return "Transcript"
        }
        if normalizedReplyMode.isEmpty {
            return entry.isNavigable ? "Thread linked" : "Local only"
        }
        return "Agent"
    }

    private func historyRoutingDetails(for entry: TranscriptHistoryEntry) -> String? {
        let route = entry.actualRoute?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = entry.routingSource?.trimmingCharacters(in: .whitespacesAndNewlines)
        let forcedReason = entry.forcedRouteReason?.trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = [route, source, forcedReason].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value.replacingOccurrences(of: "_", with: " ")
        }

        guard !parts.isEmpty else { return nil }
        return "Routing: " + parts.joined(separator: " • ")
    }

    private func toggleHistoryExpansion(for id: UUID) {
        if expandedHistoryIds.contains(id) {
            expandedHistoryIds.remove(id)
        } else {
            expandedHistoryIds.insert(id)
        }
    }

    private func openHistoryThread(_ entry: TranscriptHistoryEntry) {
        appSettings.openHistoryThread(entry, chatStore: chatStore)
    }

    private var microphonePermissionDetail: String {
        switch PermissionCoordinator.microphoneStatus() {
        case .authorized:
            return "Granted."
        case .notDetermined:
            return "Not requested yet. Elson.ai will ask on first recording attempt."
        case .denied, .restricted:
            return "Missing. Elson.ai should error immediately and open Microphone settings."
        @unknown default:
            return "Unknown microphone permission state."
        }
    }

    private var screenRecordingPermissionDetail: String {
        PermissionCoordinator.hasScreenRecordingPermission()
            ? "Granted."
            : "Missing. Agent screenshot capture will fail until macOS Screen Recording is enabled, then Elson.ai is fully quit and reopened."
    }

    private func saveGroqKey() {
        guard !isSavingGroqKey else { return }
        isSavingGroqKey = true
        groqKeyStatus = nil

        Task { @MainActor in
            defer { isSavingGroqKey = false }
            do {
                try await appSettings.validateAndSaveGroqAPIKey(groqDraftKey)
                groqDraftKey = appSettings.groqAPIKey
                isEditingGroqKey = false
                groqKeyStatus = trimmedSecret(groqDraftKey).isEmpty ? "Cleared." : "Validated and saved."
            } catch {
                groqKeyStatus = error.localizedDescription
            }
        }
    }

    private func saveCerebrasKey() {
        guard !isSavingCerebrasKey else { return }
        isSavingCerebrasKey = true
        cerebrasKeyStatus = nil

        Task { @MainActor in
            defer { isSavingCerebrasKey = false }
            do {
                try await appSettings.validateAndSaveCerebrasAPIKey(cerebrasDraftKey)
                cerebrasDraftKey = appSettings.cerebrasAPIKey
                isEditingCerebrasKey = false
                cerebrasKeyStatus = trimmedSecret(cerebrasDraftKey).isEmpty ? "Cleared." : "Validated and saved."
            } catch {
                cerebrasKeyStatus = error.localizedDescription
            }
        }
    }

    private func saveGeminiKey() {
        guard !isSavingGeminiKey else { return }
        isSavingGeminiKey = true
        geminiKeyStatus = nil

        Task { @MainActor in
            defer { isSavingGeminiKey = false }
            do {
                try await appSettings.validateAndSaveGeminiAPIKey(geminiDraftKey)
                geminiDraftKey = appSettings.geminiAPIKey
                isEditingGeminiKey = false
                geminiKeyStatus = trimmedSecret(geminiDraftKey).isEmpty ? "Cleared." : "Validated and saved."
            } catch {
                geminiKeyStatus = error.localizedDescription
            }
        }
    }

    private func cancelGroqKeyEditing() {
        groqDraftKey = appSettings.groqAPIKey
        groqKeyStatus = nil
        isEditingGroqKey = false
    }

    private func cancelCerebrasKeyEditing() {
        cerebrasDraftKey = appSettings.cerebrasAPIKey
        cerebrasKeyStatus = nil
        isEditingCerebrasKey = false
    }

    private func cancelGeminiKeyEditing() {
        geminiDraftKey = appSettings.geminiAPIKey
        geminiKeyStatus = nil
        isEditingGeminiKey = false
    }

    private func syncAPIKeyDraftsFromSettings() {
        if !isEditingGroqKey {
            groqDraftKey = appSettings.groqAPIKey
        }
        if !isEditingCerebrasKey {
            cerebrasDraftKey = appSettings.cerebrasAPIKey
        }
        if !isEditingGeminiKey {
            geminiDraftKey = appSettings.geminiAPIKey
        }
    }

    private func trimmedSecret(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
