import AppKit
import SwiftUI

@MainActor
struct InstallOnboardingView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.colorScheme) private var colorScheme
    private let permissionPoll = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    @State private var currentStep: InstallOnboardingStep = .interactionModel
    @State private var isEditingGroqKey = false
    @State private var isEditingCerebrasKey = false
    @State private var isEditingGeminiKey = false
    @State private var groqDraftKey = ""
    @State private var cerebrasDraftKey = ""
    @State private var geminiDraftKey = ""
    @State private var statusText: String? = nil
    @State private var isWorking = false
    @State private var refreshToken = UUID()
    @State private var folderAutoConfirmAt: Date? = nil
    @State private var isShowingBulkKeyEditor = false
    @State private var bulkKeyEditorText = ""
    @State private var bulkKeyEditorError: String? = nil

    var body: some View {
        ZStack {
            backgroundView

            VStack(spacing: 18) {
                Spacer(minLength: 20)

                contentCard
                    .frame(maxWidth: 520)

                Spacer(minLength: 20)
            }
            .padding(28)
        }
        .frame(minWidth: 980, minHeight: 780)
        .id(refreshToken)
        .onAppear {
            syncAPIKeyDraftsFromSettings()
            syncCurrentStep(force: true)
            presentOnboardingWindowIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appSettings.refreshOnboardingStoredFlag()
            refreshToken = UUID()
            syncCurrentStep(force: false)
        }
        .onReceive(permissionPoll) { _ in
            if currentStep == .folder,
               !appSettings.didCompleteFolderOnboarding,
               let deadline = folderAutoConfirmAt,
               Date() >= deadline {
                folderAutoConfirmAt = nil
                NotificationCenter.default.post(name: .folderAccessPromptWillBegin, object: nil)
                if appSettings.completeFolderOnboardingStep() {
                    NotificationCenter.default.post(name: .folderAccessPromptDidFinish, object: nil)
                    statusText = nil
                } else {
                    let path = appSettings.workspaceFolderPath ?? "~/Documents/Elson"
                    statusText = "Documents access is still missing for \(path). Allow it in the macOS prompt or try again."
                }
            }
            appSettings.refreshOnboardingStoredFlag()
            syncCurrentStep(force: false)
        }
    }

    private func presentOnboardingWindowIfNeeded() {
        DispatchQueue.main.async {
            guard appSettings.needsInstallOnboarding else { return }

            let onboardingWindow = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: \.isVisible)

            if let onboardingWindow {
                if onboardingWindow.isMiniaturized {
                    onboardingWindow.deminiaturize(nil)
                }
                onboardingWindow.makeKeyAndOrderFront(nil)
                onboardingWindow.orderFrontRegardless()
            }

            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var isLightMode: Bool {
        colorScheme == .light
    }

    private var titleColor: Color {
        isLightMode ? Color.black.opacity(0.82) : Color.white.opacity(0.96)
    }

    private var secondaryTextColor: Color {
        isLightMode ? Color.black.opacity(0.58) : Color.white.opacity(0.72)
    }

    private var tertiaryTextColor: Color {
        isLightMode ? Color.black.opacity(0.48) : Color.white.opacity(0.68)
    }

    private var fieldLabelColor: Color {
        isLightMode ? Color.black.opacity(0.70) : Color.white.opacity(0.70)
    }

    private var fieldTextColor: Color {
        isLightMode ? Color.black.opacity(0.74) : Color.white.opacity(0.94)
    }

    private var fieldBackgroundColor: Color {
        isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.06)
    }

    private var cardChromeColor: Color {
        isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.05)
    }

    private var cardBackgroundColor: Color {
        isLightMode
            ? Color(red: 0.975, green: 0.973, blue: 0.970)
            : Color(red: 0.115, green: 0.120, blue: 0.148)
    }

    private var cardBorderColor: Color {
        isLightMode ? Color.white.opacity(0.92) : Color.white.opacity(0.10)
    }

    private var cardShadowColor: Color {
        isLightMode ? Color.black.opacity(0.08) : Color.black.opacity(0.30)
    }

    private var backgroundView: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.09, blue: 0.12),
                Color(red: 0.11, green: 0.11, blue: 0.16),
                Color(red: 0.13, green: 0.12, blue: 0.18),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.20))
                    .frame(width: 340, height: 340)
                    .blur(radius: 12)
                    .offset(x: -220, y: -160)

                Circle()
                    .fill(Color.purple.opacity(0.16))
                    .frame(width: 280, height: 280)
                    .blur(radius: 18)
                    .offset(x: 250, y: 170)
            }
        )
        .ignoresSafeArea()
    }

    private var contentCard: some View {
        VStack(spacing: 20) {
            progressDots

            if currentStep == .celebration {
                readyContent
            } else {
                InstallOnboardingArtView(step: currentStep)
                    .frame(height: 180)

                VStack(spacing: 8) {
                    Text(title(for: currentStep))
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .multilineTextAlignment(.center)

                    Text(subtitle(for: currentStep))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(secondaryTextColor)
                        .multilineTextAlignment(.center)
                }
            }

            if currentStep == .apiKeys {
                apiKeysEditor
            }

            if currentStep == .interactionModel {
                interactionModelEditor
            }

            if currentStep == .transcriptShortcut {
                transcriptShortcutEditor
            }

            if currentStep == .agentShortcut {
                agentShortcutEditor
            }

            Button {
                handlePrimaryAction(for: currentStep)
            } label: {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(primaryButtonTitle(for: currentStep))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(isLightMode ? Color.white.opacity(0.96) : Color.white)
                .background(primaryButtonBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .disabled(!primaryButtonEnabled(for: currentStep) || isWorking)

            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .overlay(alignment: .topTrailing) {
            if currentStep == .apiKeys {
                Button {
                    bulkKeyEditorError = nil
                    if !isShowingBulkKeyEditor {
                        bulkKeyEditorText = ""
                    }
                    isShowingBulkKeyEditor.toggle()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isLightMode ? Color.black.opacity(0.62) : Color.white.opacity(0.82))
                        .frame(width: 28, height: 28)
                        .background(cardChromeColor)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(18)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(cardBackgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        }
        .shadow(color: cardShadowColor, radius: 28, y: 16)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: currentStep)
    }

    private var readyContent: some View {
        VStack(spacing: 18) {
            InstallOnboardingArtView(step: .celebration)
                .frame(height: 220)

            VStack(spacing: 10) {
                Text("Ready")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(titleColor)
                    .multilineTextAlignment(.center)

                Text("When you close this window, the bubble will appear at the bottom right. Press your shortcut to start.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
    }

    private var apiKeysEditor: some View {
        VStack(spacing: 12) {
            Text("All 3 keys are required.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isShowingBulkKeyEditor {
                bulkKeyPasteEditor
            }

            keyEditorRow(
                title: "Groq",
                subtitle: "Speech + screen.",
                destination: URL(string: "https://console.groq.com/keys")!,
                value: $groqDraftKey,
                isEditing: $isEditingGroqKey
            )

            keyEditorRow(
                title: "Cerebras",
                subtitle: "Intent + text.",
                destination: URL(string: "https://cloud.cerebras.ai/platform/api-keys")!,
                value: $cerebrasDraftKey,
                isEditing: $isEditingCerebrasKey
            )

            keyEditorRow(
                title: "Gemini",
                subtitle: "Transcript + agent fallback.",
                destination: URL(string: "https://aistudio.google.com/apikey")!,
                value: $geminiDraftKey,
                isEditing: $isEditingGeminiKey
            )
        }
    }

    private var interactionModelEditor: some View {
        VStack(spacing: 12) {
            modeCard(
                title: "Transcript",
                tint: Color.orange,
                detail: "Use when you want text to paste or send.",
                examples: "Email, Slack, ticket, note."
            )
            modeCard(
                title: "Agent",
                tint: Color.purple,
                detail: "Use when you want Elson to answer or act.",
                examples: "Reply, explain, save, inspect."
            )
        }
    }

    private var bulkKeyPasteEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if bulkKeyEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("""
                    GROQ_API_KEY="..."
                    CEREBRAS_API_KEY="..."
                    GEMINI_API_KEY="..."
                    """)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(tertiaryTextColor)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $bulkKeyEditorText)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            HStack(spacing: 10) {
                Button("Cancel") {
                    bulkKeyEditorError = nil
                    isShowingBulkKeyEditor = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tertiaryTextColor)

                Spacer()

                Button("Save") {
                    applyBulkKeyPaste()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(titleColor)
            }

            if let bulkKeyEditorError, !bulkKeyEditorError.isEmpty {
                Text(bulkKeyEditorError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
            }
        }
        .padding(14)
        .background(cardChromeColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var transcriptShortcutEditor: some View {
        @Bindable var appSettings = appSettings

        return VStack(spacing: 14) {
            RecordingShortcutCaptureButton(shortcut: $appSettings.transcriptShortcut)
        }
    }

    private var agentShortcutEditor: some View {
        @Bindable var appSettings = appSettings

        return VStack(spacing: 14) {
            RecordingShortcutCaptureButton(shortcut: $appSettings.agentShortcut)

            if appSettings.hasShortcutConflict {
                Text("Agent shortcut must differ from the transcript shortcut.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
            }
        }
    }

    private var progressDots: some View {
        HStack(spacing: 10) {
            ForEach(Array(InstallOnboardingStep.allCases.enumerated()), id: \.offset) { index, step in
                Circle()
                    .fill(progressColor(for: step, index: index))
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle()
                            .stroke(isLightMode ? Color.black.opacity(step == currentStep ? 0.22 : 0) : Color.white.opacity(step == currentStep ? 0.75 : 0), lineWidth: 1.5)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func keyEditorRow(
        title: String,
        subtitle: String,
        destination: URL,
        value: Binding<String>,
        isEditing: Binding<Bool>
    ) -> some View {
        let masked = appSettings.maskedKey(for: value.wrappedValue)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(fieldLabelColor)

                Link(destination: destination) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tertiaryTextColor)
                }
                .buttonStyle(.plain)
                .help("\(subtitle) Open key page.")

                Spacer()
            }

            if !masked.isEmpty && !isEditing.wrappedValue {
                HStack {
                    Text(masked)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(fieldTextColor)
                    Spacer()
                    Button("Change") {
                        isEditing.wrappedValue = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tertiaryTextColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(fieldBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                SecureField("\(title) API Key", text: value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(fieldTextColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tertiaryTextColor)
        }
    }

    private func modeCard(title: String, tint: Color, detail: String, examples: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(tint.opacity(isLightMode ? 0.92 : 0.88))
                .frame(width: 12, height: 12)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(titleColor)

                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryTextColor)

                Text(examples)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tertiaryTextColor)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(cardChromeColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var primaryButtonBackgroundColor: Color {
        guard primaryButtonEnabled(for: currentStep) else {
            return isLightMode ? Color.black.opacity(0.14) : Color.black.opacity(0.22)
        }

        return isLightMode
            ? Color(red: 0.17, green: 0.19, blue: 0.27).opacity(0.92)
            : Color.black.opacity(0.78)
    }

    private func title(for step: InstallOnboardingStep) -> String {
        switch step {
        case .interactionModel:
            return "Two Modes"
        case .apiKeys:
            return "API Keys"
        case .microphone:
            return "Microphone"
        case .screen:
            return "Screen"
        case .accessibility:
            return "Accessibility"
        case .fullDiskAccess:
            return "Skills"
        case .folder:
            return "Documents"
        case .transcriptShortcut:
            return "Transcript"
        case .agentShortcut:
            return "Agent"
        case .celebration:
            return "Ready"
        }
    }

    private func subtitle(for step: InstallOnboardingStep) -> String {
        switch step {
        case .interactionModel:
            return "Choose the right shortcut for the job."
        case .apiKeys:
            return "Add the 3 keys."
        case .microphone:
            return "Mic so Elson understands you."
        case .screen:
            return "Screen so Elson sees your context."
        case .accessibility:
            return "Accessibility so Elson can paste for you."
        case .fullDiskAccess:
            return "Full Disk Access so Elson can discover local SKILL.md files."
        case .folder:
            let path = appSettings.workspaceFolderPath ?? "~/Documents/Elson"
            if appSettings.hasStoredWorkspaceFolderSelection {
                return "Grant access to your saved custom folder at \(path), or change it later in Settings."
            }
            return "Allow Elson to use \(path) for MyElson context and daily transcript CSV exports. You can choose a different folder later in Settings."
        case .transcriptShortcut:
            return "For text."
        case .agentShortcut:
            return "For Elson."
        case .celebration:
            return "When you close this window, the bubble will appear at the bottom right."
        }
    }

    private func primaryButtonTitle(for step: InstallOnboardingStep) -> String {
        switch step {
        case .interactionModel:
            return "Continue"
        case .apiKeys:
            return "Continue"
        case .microphone:
            return "Allow Microphone"
        case .screen:
            return "Allow Screen"
        case .accessibility:
            return "Open Accessibility"
        case .fullDiskAccess:
            return "Open Full Disk Access"
        case .folder:
            if appSettings.hasStoredWorkspaceFolderSelection, !appSettings.didCompleteFolderOnboarding {
                return "Allow Folder Access"
            }
            return "Allow Documents Access"
        case .transcriptShortcut, .agentShortcut:
            return "Continue"
        case .celebration:
            return "Start Using Elson"
        }
    }

    private func primaryButtonEnabled(for step: InstallOnboardingStep) -> Bool {
        switch step {
        case .apiKeys:
            return !trimmedSecret(groqDraftKey).isEmpty
                && !trimmedSecret(cerebrasDraftKey).isEmpty
                && !trimmedSecret(geminiDraftKey).isEmpty
                && !isWorking
        case .transcriptShortcut, .agentShortcut:
            return !appSettings.hasShortcutConflict
        case .celebration:
            return appSettings.hasCompletedRequiredInstallSetup
        default:
            return true
        }
    }

    private func handlePrimaryAction(for step: InstallOnboardingStep) {
        statusText = nil

        switch step {
        case .interactionModel:
            appSettings.didCompleteInteractionModelOnboarding = true
            appSettings.refreshOnboardingStoredFlag()
            syncCurrentStep(force: false)
        case .apiKeys:
            isWorking = true
            Task { @MainActor in
                defer { isWorking = false }
                do {
                    try await appSettings.validateAndSaveAPIKeys(
                        groq: groqDraftKey,
                        cerebras: cerebrasDraftKey,
                        gemini: geminiDraftKey
                    )
                    isEditingGroqKey = false
                    isEditingCerebrasKey = false
                    isEditingGeminiKey = false
                    statusText = nil
                    syncAPIKeyDraftsFromSettings()
                    appSettings.refreshOnboardingStoredFlag()
                    syncCurrentStep(force: false)
                } catch {
                    statusText = error.localizedDescription
                }
            }
        case .microphone:
            isWorking = true
            Task { @MainActor in
                defer { isWorking = false }
                do {
                    try await PermissionCoordinator.ensureMicrophonePermission()
                    appSettings.refreshOnboardingStoredFlag()
                    syncCurrentStep(force: false)
                } catch {
                    statusText = nil
                }
            }
        case .screen:
            do {
                try PermissionCoordinator.ensureScreenRecordingPermission(
                    requestIfNeeded: true,
                    openSettingsOnFailure: false
                )
                appSettings.refreshOnboardingStoredFlag()
                syncCurrentStep(force: false)
            } catch {
                statusText = "Use the macOS screen recording dialog. Only click Open System Settings there if you want to continue."
            }
        case .accessibility:
            do {
                try PermissionCoordinator.ensureAccessibilityPermission(
                    requestIfNeeded: true,
                    openSettingsOnFailure: false
                )
                appSettings.refreshOnboardingStoredFlag()
                syncCurrentStep(force: false)
            } catch {
                statusText = "Use the macOS accessibility prompt. Only click Open System Settings there, then enable Elson."
            }
        case .fullDiskAccess:
            PermissionCoordinator.openFullDiskAccessSettings()
            appSettings.refreshOnboardingStoredFlag()
            if !appSettings.fullDiskAccessPermissionGranted {
                statusText = "Enable Elson in Privacy & Security > Full Disk Access, then return to Elson."
            } else {
                syncCurrentStep(force: false)
            }
        case .folder:
            folderAutoConfirmAt = nil
            NotificationCenter.default.post(name: .folderAccessPromptWillBegin, object: nil)
            if appSettings.completeFolderOnboardingStep() {
                NotificationCenter.default.post(name: .folderAccessPromptDidFinish, object: nil)
                statusText = nil
                syncCurrentStep(force: false)
            } else {
                let path = appSettings.workspaceFolderPath ?? "~/Documents/Elson"
                statusText = appSettings.hasStoredWorkspaceFolderSelection
                    ? "Allow access to your selected folder at \(path) in the macOS prompt or choose a different folder in Settings."
                    : "Allow Documents access for \(path) in the macOS prompt."
                folderAutoConfirmAt = Date().addingTimeInterval(0.8)
            }
        case .transcriptShortcut:
            appSettings.didCompleteTranscriptShortcutOnboarding = true
            appSettings.refreshOnboardingStoredFlag()
            syncCurrentStep(force: false)
        case .agentShortcut:
            if appSettings.hasShortcutConflict {
                statusText = "Transcript and Agent shortcuts must differ."
                return
            }
            appSettings.didCompleteAgentShortcutOnboarding = true
            appSettings.refreshOnboardingStoredFlag()
            syncCurrentStep(force: false)
        case .celebration:
            appSettings.didCompleteOnboarding = true
            appSettings.refreshOnboardingStoredFlag()
            NotificationCenter.default.post(name: .completeInstallOnboardingHandoff, object: nil)
        }
    }

    private func syncCurrentStep(force: Bool) {
        appSettings.refreshOnboardingStoredFlag()
        guard let next = appSettings.firstIncompleteInstallOnboardingStep else { return }
        if force || next != currentStep {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                currentStep = next
            }
        }
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

    private func applyBulkKeyPaste() {
        let parsed = parseBulkAPIKeyBlock(bulkKeyEditorText)
        guard parsed.groq != nil || parsed.cerebras != nil || parsed.gemini != nil else {
            bulkKeyEditorError = "No API keys found."
            return
        }

        if let groq = parsed.groq {
            groqDraftKey = groq
            isEditingGroqKey = false
        }
        if let cerebras = parsed.cerebras {
            cerebrasDraftKey = cerebras
            isEditingCerebrasKey = false
        }
        if let gemini = parsed.gemini {
            geminiDraftKey = gemini
            isEditingGeminiKey = false
        }

        bulkKeyEditorError = nil
        isShowingBulkKeyEditor = false
        statusText = nil
    }

    private func parseBulkAPIKeyBlock(_ text: String) -> (groq: String?, cerebras: String?, gemini: String?) {
        var groq: String?
        var cerebras: String?
        var gemini: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let cleanedLine = line.hasPrefix("export ") ? String(line.dropFirst(7)) : line
            guard let separator = cleanedLine.firstIndex(of: "=") else { continue }

            let key = String(cleanedLine[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = cleanedLine[cleanedLine.index(after: separator)...]
            let value = normalizedBulkKeyValue(String(rawValue))
            guard !value.isEmpty else { continue }

            switch key {
            case "GROQ_API_KEY":
                groq = value
            case "CEREBRAS_API_KEY":
                cerebras = value
            case "GEMINI_API_KEY":
                gemini = value
            default:
                continue
            }
        }

        return (groq, cerebras, gemini)
    }

    private func normalizedBulkKeyValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func progressColor(for step: InstallOnboardingStep, index: Int) -> Color {
        if step == currentStep {
            return Color.white.opacity(0.94)
        }
        if index < currentStep.rawValue {
            return Color.blue.opacity(0.72)
        }
        return Color.white.opacity(0.32)
    }
}
