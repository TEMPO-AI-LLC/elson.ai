import AppKit
import Carbon
import Darwin
import Foundation

enum ListeningMode: String, Codable, CaseIterable {
    case hold
    case toggle
}

enum ShortcutModifier: String, Codable, CaseIterable, Hashable {
    case command
    case option
    case control
    case shift
    case function

    fileprivate static let displayOrder: [ShortcutModifier] = [.command, .option, .control, .shift, .function]

    fileprivate var title: String {
        switch self {
        case .command:
            return "cmd"
        case .option:
            return "option"
        case .control:
            return "ctrl"
        case .shift:
            return "shift"
        case .function:
            return "fn"
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .command:
            return "⌘"
        case .option:
            return "⌥"
        case .control:
            return "⌃"
        case .shift:
            return "⇧"
        case .function:
            return "fn"
        }
    }
}

struct RecordingShortcut: Codable, Equatable, Hashable {
    let modifiers: [ShortcutModifier]

    init(modifiers: [ShortcutModifier]) {
        let unique = Set(modifiers)
        self.modifiers = ShortcutModifier.displayOrder.filter { unique.contains($0) }
    }

    init(storageValue: String) {
        let values = storageValue
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .compactMap { part -> ShortcutModifier? in
                switch part {
                case "cmd", "command":
                    return .command
                case "option", "opt", "alt":
                    return .option
                case "ctrl", "control":
                    return .control
                case "shift":
                    return .shift
                case "fn", "function":
                    return .function
                default:
                    return nil
                }
            }
        self.init(modifiers: values)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(storageValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }

    static let `default` = RecordingShortcut(modifiers: [.function])
    static let feedbackDefault = RecordingShortcut(modifiers: [.shift, .function])

    static func from(carbonModifiers: UInt32) -> RecordingShortcut {
        var modifiers: [ShortcutModifier] = []
        if (carbonModifiers & UInt32(cmdKey)) != 0 { modifiers.append(.command) }
        if (carbonModifiers & UInt32(optionKey)) != 0 { modifiers.append(.option) }
        if (carbonModifiers & UInt32(controlKey)) != 0 { modifiers.append(.control) }
        if (carbonModifiers & UInt32(shiftKey)) != 0 { modifiers.append(.shift) }
        if (carbonModifiers & UInt32(kEventKeyModifierFnMask)) != 0 { modifiers.append(.function) }
        return RecordingShortcut(modifiers: modifiers)
    }

    static func from(event: NSEvent) -> RecordingShortcut {
        var modifiers: [ShortcutModifier] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.append(.command) }
        if flags.contains(.option) { modifiers.append(.option) }
        if flags.contains(.control) { modifiers.append(.control) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        if flags.contains(.function) { modifiers.append(.function) }
        return RecordingShortcut(modifiers: modifiers)
    }

    var storageValue: String {
        modifiers.map(\.rawValue).joined(separator: "+")
    }

    var title: String {
        modifiers.isEmpty ? "Not set" : modifiers.map(\.title).joined(separator: " + ")
    }

    var symbolTokens: [String] {
        modifiers.map(\.symbol)
    }

    var isEmpty: Bool {
        modifiers.isEmpty
    }

    func matches(carbonModifiers: UInt32) -> Bool {
        self == RecordingShortcut.from(carbonModifiers: carbonModifiers)
    }
}

enum RuntimeMode: String, Codable, CaseIterable {
    case local
    case hosted
}

struct ElsonLocalConfig: Codable, Equatable {
    var groqAPIKey: String
    var cerebrasAPIKey: String
    var geminiAPIKey: String
    var agentProvider: LocalModelProvider
    var myElsonMarkdown: String
    var transcriptAgentPrompt: String
    var workingAgentPrompt: String
    var agentModeEnabled: Bool
    var skillsEnabled: Bool
    var skillSelectionScope: SkillSelectionScope
    var selectedSkillIDs: [String]
    var autoPaste: Bool
    var copyTranscriptToClipboard: Bool
    var restoreOriginalClipboardAfterPaste: Bool
    var transcriptScreenOCR: Bool
    var listeningMode: ListeningMode
    var transcriptShortcut: RecordingShortcut
    var agentShortcut: RecordingShortcut
    var recordingShortcut: RecordingShortcut
    var runtimeMode: RuntimeMode
    var feedbackShortcutEnabled: Bool
    var feedbackShortcut: RecordingShortcut

    enum CodingKeys: String, CodingKey {
        case groqAPIKey = "groq_api_key"
        case cerebrasAPIKey = "cerebras_api_key"
        case geminiAPIKey = "gemini_api_key"
        case agentProvider = "agent_provider"
        case myElsonMarkdown = "my_elson_markdown"
        case transcriptAgentPrompt = "transcript_agent_prompt_v2"
        case workingAgentPrompt = "working_agent_prompt_v2"
        case agentModeEnabled = "agent_mode_enabled"
        case skillsEnabled = "skills_enabled"
        case skillSelectionScope = "skill_selection_scope"
        case selectedSkillIDs = "selected_skill_ids"
        case autoPaste = "auto_paste"
        case copyTranscriptToClipboard = "copy_transcript_to_clipboard"
        case restoreOriginalClipboardAfterPaste = "restore_original_clipboard_after_paste"
        case transcriptScreenOCR = "transcript_screen_ocr"
        case listeningMode = "listening_mode"
        case transcriptShortcut = "transcript_shortcut"
        case agentShortcut = "agent_shortcut"
        case recordingShortcut = "recording_shortcut"
        case runtimeMode = "runtime_mode"
        case feedbackShortcutEnabled = "feedback_shortcut_enabled"
        case feedbackShortcut = "feedback_shortcut"
    }

    static let `default` = ElsonLocalConfig(
        groqAPIKey: "",
        cerebrasAPIKey: "",
        geminiAPIKey: "",
        agentProvider: .google,
        myElsonMarkdown: "",
        transcriptAgentPrompt: ElsonPromptCatalog.defaultTranscriptAgentPrompt,
        workingAgentPrompt: ElsonPromptCatalog.defaultWorkingAgentPrompt,
        agentModeEnabled: true,
        skillsEnabled: false,
        skillSelectionScope: .all,
        selectedSkillIDs: [],
        autoPaste: true,
        copyTranscriptToClipboard: false,
        restoreOriginalClipboardAfterPaste: false,
        transcriptScreenOCR: true,
        listeningMode: .hold,
        transcriptShortcut: .default,
        agentShortcut: .feedbackDefault,
        recordingShortcut: .default,
        runtimeMode: .local,
        feedbackShortcutEnabled: false,
        feedbackShortcut: .feedbackDefault
    )

    init(
        groqAPIKey: String,
        cerebrasAPIKey: String,
        geminiAPIKey: String,
        agentProvider: LocalModelProvider,
        myElsonMarkdown: String,
        transcriptAgentPrompt: String,
        workingAgentPrompt: String,
        agentModeEnabled: Bool,
        skillsEnabled: Bool,
        skillSelectionScope: SkillSelectionScope,
        selectedSkillIDs: [String],
        autoPaste: Bool,
        copyTranscriptToClipboard: Bool,
        restoreOriginalClipboardAfterPaste: Bool,
        transcriptScreenOCR: Bool,
        listeningMode: ListeningMode,
        transcriptShortcut: RecordingShortcut,
        agentShortcut: RecordingShortcut,
        recordingShortcut: RecordingShortcut,
        runtimeMode: RuntimeMode,
        feedbackShortcutEnabled: Bool,
        feedbackShortcut: RecordingShortcut
    ) {
        self.groqAPIKey = Self.sanitizeSecret(groqAPIKey)
        self.cerebrasAPIKey = Self.sanitizeSecret(cerebrasAPIKey)
        self.geminiAPIKey = Self.sanitizeSecret(geminiAPIKey)
        self.agentProvider = agentProvider
        self.myElsonMarkdown = myElsonMarkdown
        self.transcriptAgentPrompt = ElsonPromptCatalog.normalizedTranscriptAgentPrompt(transcriptAgentPrompt)
        self.workingAgentPrompt = ElsonPromptCatalog.normalizedWorkingAgentPrompt(workingAgentPrompt)
        self.agentModeEnabled = agentModeEnabled
        self.skillsEnabled = skillsEnabled
        self.skillSelectionScope = skillSelectionScope
        self.selectedSkillIDs = selectedSkillIDs
        self.autoPaste = autoPaste
        self.copyTranscriptToClipboard = copyTranscriptToClipboard
        self.restoreOriginalClipboardAfterPaste = restoreOriginalClipboardAfterPaste
        self.transcriptScreenOCR = transcriptScreenOCR
        self.listeningMode = listeningMode
        self.transcriptShortcut = transcriptShortcut
        self.agentShortcut = agentShortcut
        self.recordingShortcut = recordingShortcut.isEmpty ? transcriptShortcut : recordingShortcut
        self.runtimeMode = runtimeMode
        self.feedbackShortcutEnabled = feedbackShortcutEnabled
        self.feedbackShortcut = feedbackShortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ElsonLocalConfig.default

        groqAPIKey = Self.sanitizeSecret(try container.decodeIfPresent(String.self, forKey: .groqAPIKey) ?? fallback.groqAPIKey)
        cerebrasAPIKey = Self.sanitizeSecret(try container.decodeIfPresent(String.self, forKey: .cerebrasAPIKey) ?? fallback.cerebrasAPIKey)
        geminiAPIKey = Self.sanitizeSecret(try container.decodeIfPresent(String.self, forKey: .geminiAPIKey) ?? fallback.geminiAPIKey)
        agentProvider = try container.decodeIfPresent(LocalModelProvider.self, forKey: .agentProvider) ?? fallback.agentProvider
        myElsonMarkdown = try container.decodeIfPresent(String.self, forKey: .myElsonMarkdown) ?? fallback.myElsonMarkdown
        transcriptAgentPrompt = ElsonPromptCatalog.normalizedTranscriptAgentPrompt(
            try container.decodeIfPresent(String.self, forKey: .transcriptAgentPrompt)
                ?? fallback.transcriptAgentPrompt
        )
        workingAgentPrompt = ElsonPromptCatalog.normalizedWorkingAgentPrompt(
            try container.decodeIfPresent(String.self, forKey: .workingAgentPrompt)
                ?? fallback.workingAgentPrompt
        )
        agentModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentModeEnabled) ?? fallback.agentModeEnabled
        skillsEnabled = try container.decodeIfPresent(Bool.self, forKey: .skillsEnabled) ?? fallback.skillsEnabled
        skillSelectionScope = try container.decodeIfPresent(SkillSelectionScope.self, forKey: .skillSelectionScope) ?? fallback.skillSelectionScope
        selectedSkillIDs = try container.decodeIfPresent([String].self, forKey: .selectedSkillIDs) ?? fallback.selectedSkillIDs
        autoPaste = try container.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? fallback.autoPaste
        copyTranscriptToClipboard = try container.decodeIfPresent(Bool.self, forKey: .copyTranscriptToClipboard) ?? fallback.copyTranscriptToClipboard
        restoreOriginalClipboardAfterPaste =
            try container.decodeIfPresent(Bool.self, forKey: .restoreOriginalClipboardAfterPaste)
            ?? fallback.restoreOriginalClipboardAfterPaste
        transcriptScreenOCR = try container.decodeIfPresent(Bool.self, forKey: .transcriptScreenOCR) ?? fallback.transcriptScreenOCR
        listeningMode = try container.decodeIfPresent(ListeningMode.self, forKey: .listeningMode) ?? fallback.listeningMode
        let legacyRecordingShortcut = try container.decodeIfPresent(RecordingShortcut.self, forKey: .recordingShortcut)
            ?? fallback.recordingShortcut
        transcriptShortcut = try container.decodeIfPresent(RecordingShortcut.self, forKey: .transcriptShortcut)
            ?? legacyRecordingShortcut
        agentShortcut = try container.decodeIfPresent(RecordingShortcut.self, forKey: .agentShortcut)
            ?? fallback.agentShortcut
        recordingShortcut = transcriptShortcut
        runtimeMode = try container.decodeIfPresent(RuntimeMode.self, forKey: .runtimeMode) ?? fallback.runtimeMode
        feedbackShortcutEnabled = try container.decodeIfPresent(Bool.self, forKey: .feedbackShortcutEnabled) ?? fallback.feedbackShortcutEnabled
        feedbackShortcut = try container.decodeIfPresent(RecordingShortcut.self, forKey: .feedbackShortcut) ?? fallback.feedbackShortcut
    }

    private static func sanitizeSecret(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

}

final class ElsonLocalConfigStore: @unchecked Sendable {
    static let shared = ElsonLocalConfigStore()
    private static let testAppSupportConfigURLEnv = "ELSON_TEST_APP_SUPPORT_CONFIG_URL"
    private static let testWorkspaceFolderURLEnv = "ELSON_TEST_WORKSPACE_FOLDER_URL"

    private enum WorkspaceKeys {
        static let bookmark = "workspace_folder_bookmark"
        static let path = "workspace_folder_path"
    }

    private enum WorkspaceFiles {
        static let myElsonMarkdown = "myelson.md"
        static let defaultFolderName = "Elson"
    }

    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    static func setTestingOverrides(appSupportConfigURL: URL?, workspaceFolderURL: URL?) {
        if let appSupportConfigURL {
            setenv(testAppSupportConfigURLEnv, appSupportConfigURL.path, 1)
        } else {
            unsetenv(testAppSupportConfigURLEnv)
        }

        if let workspaceFolderURL {
            setenv(testWorkspaceFolderURLEnv, workspaceFolderURL.path, 1)
        } else {
            unsetenv(testWorkspaceFolderURLEnv)
        }
    }

    static func clearTestingOverrides() {
        unsetenv(testAppSupportConfigURLEnv)
        unsetenv(testWorkspaceFolderURLEnv)
    }

    func load(includeWorkingDirectorySources: Bool = true) -> ElsonLocalConfig {
        print("[CONFIG LOAD] Starting load (includeWorkingSources=\(includeWorkingDirectorySources))")
        if let config = loadFromConfigFile(includeWorkingDirectorySources: includeWorkingDirectorySources) {
            print("[CONFIG LOAD] ✅ Loaded from config file — groq=\(config.groqAPIKey.isEmpty ? "EMPTY" : "SET(\(config.groqAPIKey.prefix(8))…)") cerebras=\(config.cerebrasAPIKey.isEmpty ? "EMPTY" : "SET") gemini=\(config.geminiAPIKey.isEmpty ? "EMPTY" : "SET")")
            return config
        }
        print("[CONFIG LOAD] ⚠️ No config file found")
        print("[CONFIG LOAD] Returning .default")
        return .default
    }

    func save(_ config: ElsonLocalConfig) {
        let appSupportURL = appSupportConfigURL()
        do {
            try writeConfig(config, to: appSupportURL)
            print("[CONFIG SAVE] ✅ appSupport: \(appSupportURL.path) — groq=\(config.groqAPIKey.isEmpty ? "EMPTY" : "SET(\(config.groqAPIKey.prefix(8))…)") cerebras=\(config.cerebrasAPIKey.isEmpty ? "EMPTY" : "SET") gemini=\(config.geminiAPIKey.isEmpty ? "EMPTY" : "SET")")
        } catch {
            print("[CONFIG SAVE] ❌ appSupport FAILED at \(appSupportURL.path): \(error)")
        }

        // Also persist to workspace folder so keys survive Application Support wipes
        let _ = withWorkspaceFolderAccess { root -> Void in
            let wsURL = repoConfigURL(baseURL: root)
            do {
                try writeConfig(config, to: wsURL)
                print("[CONFIG SAVE] ✅ workspace: \(wsURL.path)")
            } catch {
                print("[CONFIG SAVE] ❌ workspace FAILED at \(wsURL.path): \(error)")
            }
        }
    }

    func loadWorkingDirectorySources() -> ElsonLocalConfig? {
        withSelectedWorkspaceFolderAccess({ root in
            loadWorkingDirectorySources(from: root)
        })
    }

    func loadExternalApplicationSupportMigrationConfig() -> ElsonLocalConfig? {
        let sandboxURL = appSupportConfigURL()
        let externalURL = externalAppSupportConfigURL()
        guard sandboxURL.path != externalURL.path,
              fm.fileExists(atPath: externalURL.path)
        else {
            return nil
        }

        do {
            return try decoder.decode(ElsonLocalConfig.self, from: Data(contentsOf: externalURL))
        } catch {
            print("Failed to decode external local config at \(externalURL.path): \(error)")
            return nil
        }
    }

    @MainActor
    func selectWorkspaceFolderForOnboarding() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose Custom Folder"
        panel.message = "Elson will use this custom folder for files, MyElson context, and daily transcript CSV exports."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = fm.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        return persistSelectedWorkspaceFolder(url)
    }

    func confirmWorkspaceFolderOnboardingAccess(seedMyElsonMarkdown: String = MyElsonDocument.normalizedMarkdown(from: "")) -> Bool {
        withWorkspaceFolderAccess { root in
            verifyWorkspaceFolderAccess(root, seedMyElsonMarkdown: seedMyElsonMarkdown)
        } ?? false
    }

    func requestWorkingDirectoryAccess() -> Bool {
        let url = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        do {
            _ = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return true
        } catch {
            print("Failed to access working directory at \(url.path): \(error)")
            return false
        }
    }

    func hasSelectedWorkspaceFolder() -> Bool {
        let hasBookmark = UserDefaults.standard.data(forKey: WorkspaceKeys.bookmark) != nil
        let hasPath = !(UserDefaults.standard.string(forKey: WorkspaceKeys.path)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
        return hasBookmark && hasPath
    }

    func hasVerifiedSelectedWorkspaceFolderAccess() -> Bool {
        withWorkspaceFolderAccess { root in
            verifyWorkspaceFolderAccess(root, seedMyElsonMarkdown: "")
        } ?? false
    }

    func selectedWorkspaceFolderPath() -> String? {
        if let stored = UserDefaults.standard.string(forKey: WorkspaceKeys.path),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }

        return defaultWorkspaceFolderURL().path
    }

    func clearSelectedWorkspaceFolder() {
        UserDefaults.standard.removeObject(forKey: WorkspaceKeys.bookmark)
        UserDefaults.standard.removeObject(forKey: WorkspaceKeys.path)
    }

    func hasWorkspaceMyElsonFile() -> Bool {
        withWorkspaceFolderAccess { root in
            fm.fileExists(atPath: workspaceMyElsonURL(baseURL: root).path)
        } ?? false
    }

    func workspaceMyElsonFilePath() -> String? {
        withWorkspaceFolderAccess { root in
            workspaceMyElsonURL(baseURL: root).path
        }
    }

    func loadWorkspaceMyElsonMarkdown() -> String? {
        withWorkspaceFolderAccess { root in
            let url = workspaceMyElsonURL(baseURL: root)
            if !fm.fileExists(atPath: url.path) {
                return nil
            }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else {
                return ""
            }
            return text
        } ?? nil
    }

    @discardableResult
    func ensureWorkspaceMyElsonFile(initialContents: String = "") -> Bool {
        do {
            return try withWorkspaceFolderAccess { root in
                try ensureWorkspaceFiles(in: root, seedMyElsonMarkdown: initialContents)
                return true
            } ?? false
        } catch {
            print("Failed to prepare workspace MyElson file: \(error)")
            return false
        }
    }

    @discardableResult
    func saveWorkspaceMyElsonMarkdown(_ markdown: String) -> Bool {
        withWorkspaceFolderAccess { root in
            do {
                let url = workspaceMyElsonURL(baseURL: root)
                if !fm.fileExists(atPath: url.path) {
                    try ensureWorkspaceFiles(in: root, seedMyElsonMarkdown: markdown)
                    return true
                }
                try Data(markdown.utf8).write(to: url, options: [.atomic])
                return true
            } catch {
                print("Failed to write workspace MyElson markdown at \(root.path): \(error)")
                return false
            }
        } ?? false
    }

    func withWorkspaceFolderAccess<T>(_ body: (URL) throws -> T?) rethrows -> T? {
        print("TCC DIAGNOSTICS: withWorkspaceFolderAccess called")
        if let overrideWorkspaceFolderURL = Self.testingWorkspaceFolderURL() {
            do {
                try fm.createDirectory(at: overrideWorkspaceFolderURL, withIntermediateDirectories: true)
            } catch {
                print("Failed to prepare override workspace folder at \(overrideWorkspaceFolderURL.path): \(error)")
                return nil
            }
            return try body(overrideWorkspaceFolderURL)
        }
        if hasSelectedWorkspaceFolder() {
            print("TCC DIAGNOSTICS: hasSelectedWorkspaceFolder is true, using bookmark")
            return try withSelectedWorkspaceFolderAccess(body)
        }

        let root = defaultWorkspaceFolderURL()
        print("TCC DIAGNOSTICS: using defaultWorkspaceFolderURL at \(root.path)")
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            print("TCC DIAGNOSTICS: createDirectory succeeded for \(root.path)")
        } catch {
            print("Failed to prepare default workspace folder at \(root.path): \(error)")
            print("TCC DIAGNOSTICS: createDirectory FAILED with error: \(error)")
            return nil
        }

        print("TCC DIAGNOSTICS: About to execute body(root)")
        return try body(root)
    }

    func withSelectedWorkspaceFolderAccess<T>(_ body: (URL) throws -> T?) rethrows -> T? {
        guard let root = resolveSelectedWorkspaceFolderURL() else { return nil }
        let started = root.startAccessingSecurityScopedResource()
        defer {
            if started {
                root.stopAccessingSecurityScopedResource()
            }
        }
        return try body(root)
    }

    private func persistSelectedWorkspaceFolder(_ url: URL) -> Bool {
        do {
            let bookmark: Data
            do {
                bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                print("Failed to create security-scoped bookmark: \(error), falling back to standard bookmark")
                bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            UserDefaults.standard.set(bookmark, forKey: WorkspaceKeys.bookmark)
            UserDefaults.standard.set(url.path, forKey: WorkspaceKeys.path)
            return true
        } catch {
            print("Failed to persist workspace folder bookmark for \(url.path): \(error)")
            UserDefaults.standard.set(url.path, forKey: WorkspaceKeys.path)
            return true
        }
    }

    private func resolveSelectedWorkspaceFolderURL() -> URL? {
        if let bookmark = UserDefaults.standard.data(forKey: WorkspaceKeys.bookmark) {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isStale {
                    _ = persistSelectedWorkspaceFolder(url)
                }
                return url
            } catch {
                print("Failed to resolve security-scoped bookmark: \(error), falling back...")
                do {
                    let url = try URL(
                        resolvingBookmarkData: bookmark,
                        options: [],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    if isStale {
                        _ = persistSelectedWorkspaceFolder(url)
                    }
                    return url
                } catch {
                    print("Failed to resolve standard bookmark: \(error)")
                }
            }
        }

        if let path = UserDefaults.standard.string(forKey: WorkspaceKeys.path), !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func verifyWorkspaceFolderAccess(_ root: URL, seedMyElsonMarkdown: String) -> Bool {
        do {
            _ = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)

            let probeURL = root.appendingPathComponent(".elson_access_probe_\(UUID().uuidString)")
            let data = Data("ok".utf8)
            try data.write(to: probeURL, options: [.atomic])
            try fm.removeItem(at: probeURL)

            try ensureWorkspaceFiles(in: root, seedMyElsonMarkdown: seedMyElsonMarkdown)

            let markdownURL = workspaceMyElsonURL(baseURL: root)
            _ = try Data(contentsOf: markdownURL)

            let csvURL = workspaceDailyTranscriptCSVURL(baseURL: root, date: Date())
            let handle = try FileHandle(forWritingTo: csvURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            return true
        } catch {
            print("Failed to verify workspace folder access at \(root.path): \(error)")
            return false
        }
    }

    private func ensureWorkspaceFiles(in root: URL, seedMyElsonMarkdown: String) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let markdownURL = workspaceMyElsonURL(baseURL: root)
        if !fm.fileExists(atPath: markdownURL.path) {
            let seed = seedMyElsonMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : seedMyElsonMarkdown
            try Data(seed.utf8).write(to: markdownURL, options: [.atomic])
        }

        let csvURL = workspaceDailyTranscriptCSVURL(baseURL: root, date: Date())
        if !fm.fileExists(atPath: csvURL.path) {
            try Data(csvHeader.utf8).write(to: csvURL, options: [.atomic])
        }
    }

    private func touchWorkingDirectoryURL(_ url: URL, treatAsDirectory: Bool) -> Bool {
        guard fm.fileExists(atPath: url.path) else { return true }

        do {
            if treatAsDirectory {
                _ = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            } else {
                _ = try Data(contentsOf: url)
            }
            return true
        } catch {
            print("Failed to access working directory item at \(url.path): \(error)")
            return false
        }
    }

    private func loadFromConfigFile(includeWorkingDirectorySources: Bool) -> ElsonLocalConfig? {
        var candidates: [URL] = [appSupportConfigURL()]
        if includeWorkingDirectorySources {
            if let selectedConfig = withSelectedWorkspaceFolderAccess({ root in
                repoConfigURL(baseURL: root)
            }) {
                candidates.insert(selectedConfig, at: 0)
            }
        }
        print("[CONFIG LOAD] Checking \(candidates.count) candidate(s):")
        for (i, url) in candidates.enumerated() {
            let exists = fm.fileExists(atPath: url.path)
            print("[CONFIG LOAD]   [\(i)] \(url.path) — exists=\(exists)")
            guard exists else { continue }
            do {
                let data = try Data(contentsOf: url)
                print("[CONFIG LOAD]   [\(i)] Read \(data.count) bytes")
                let config = try decoder.decode(ElsonLocalConfig.self, from: data)
                print("[CONFIG LOAD]   [\(i)] ✅ Decoded successfully")
                return config
            } catch {
                print("[CONFIG LOAD]   [\(i)] ❌ Decode FAILED: \(error)")
            }
        }
        return nil
    }

    private func loadWorkingDirectorySources(from root: URL) -> ElsonLocalConfig? {
        loadFromWorkingDirectoryConfigFile(baseURL: root)
    }

    private func loadFromWorkingDirectoryConfigFile(baseURL: URL) -> ElsonLocalConfig? {
        let url = repoConfigURL(baseURL: baseURL)
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(ElsonLocalConfig.self, from: Data(contentsOf: url))
        } catch {
            print("Failed to decode local config at \(url.path): \(error)")
            return nil
        }
    }

    private func repoConfigURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("Config/local-config.json")
    }

    private func workspaceMyElsonURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent(WorkspaceFiles.myElsonMarkdown)
    }

    private func workspaceDailyTranscriptCSVURL(baseURL: URL, date: Date) -> URL {
        baseURL.appendingPathComponent("\(workspaceDailyTranscriptDateFormatter.string(from: date))_elson.csv")
    }

    private func defaultWorkspaceFolderURL() -> URL {
        if let overrideWorkspaceFolderURL = Self.testingWorkspaceFolderURL() {
            return overrideWorkspaceFolderURL
        }
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent(WorkspaceFiles.defaultFolderName, isDirectory: true)
    }

    private var csvHeader: String {
        "created_at,source,text,raw_transcript\n"
    }

    private var workspaceDailyTranscriptDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "ddMMyyyy"
        return formatter
    }

    private func appSupportConfigURL() -> URL {
        if let overrideAppSupportConfigURL = Self.testingAppSupportConfigURL() {
            return overrideAppSupportConfigURL
        }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base.appendingPathComponent("Elson/local-config.json")
    }

    private func externalAppSupportConfigURL() -> URL {
        URL(fileURLWithPath: Self.posixHomeDirectoryPath(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Elson/local-config.json")
    }

    private static func posixHomeDirectoryPath() -> String {
        guard let passwd = getpwuid(getuid()),
              let homeDirectory = passwd.pointee.pw_dir
        else {
            return NSHomeDirectory()
        }
        return String(cString: homeDirectory)
    }

    private static func testingAppSupportConfigURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment[testAppSupportConfigURLEnv],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func testingWorkspaceFolderURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment[testWorkspaceFolderURLEnv],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func writeConfig(_ config: ElsonLocalConfig, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(config)
        try data.write(to: url, options: [.atomic])
    }
}
