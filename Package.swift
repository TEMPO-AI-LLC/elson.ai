// swift-tools-version: 6.2
import Foundation
import PackageDescription

enum ElsonBuildVariant: String {
    case modern
    case compat15

    init(environment: [String: String]) {
        if let rawValue = environment["ELSON_BUILD_VARIANT"],
           let variant = ElsonBuildVariant(rawValue: rawValue) {
            self = variant
        } else {
            self = .modern
        }
    }

    var minimumPlatform: SupportedPlatform.MacOSVersion {
        switch self {
        case .modern:
            return .v26
        case .compat15:
            return .v15
        }
    }

    var swiftSettings: [SwiftSetting] {
        switch self {
        case .modern:
            return []
        case .compat15:
            return [.define("ELSON_COMPAT15_VARIANT")]
        }
    }
}

let buildVariant = ElsonBuildVariant(environment: ProcessInfo.processInfo.environment)

let package = Package(
    name: "Elson",
    platforms: [.macOS(buildVariant.minimumPlatform)],
    products: [
        .executable(name: "Elson", targets: ["Elson"])
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Elson",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Elson",
            exclude: [
                "Resources/AppIcon.iconset",
                "Resources/Info.plist",
                "build",
                "Views/CloudDashboardView.swift",
                "Views/DebugConsoleView.swift",
                "Views/GlassPopover.swift",
                "Views/FloatingPopoverWindow.swift",
                "Views/KeyboardShortcutPicker.swift",
                "Views/PopoverIndicatorView.swift",
                "Views/FloatingIndicatorView.swift",
                "Views/OnboardingView.swift",
                "Views/SettingsView.swift",
                "Utils/SizeReporting.swift",
                "Utils/WindowSizer.swift",
            ],
            sources: [
                "ElsonApp.swift",
                "App/ElsonWindowCoordinator.swift",
                "DesignSystem/ElsonGlass.swift",
                "Models/APIProvider.swift",
                "Models/AppSettings.swift",
                "Models/ChatStore.swift",
                "Models/ConversationHistory.swift",
                "Models/FeedbackLog.swift",
                "Models/LastOutputSnapshot.swift",
                "Models/RegisteredSkill.swift",
                "Models/ThreadAttachment.swift",
                "Models/ModelConfig.swift",
                "Models/PromptConfig.swift",
                "Models/TranscriptHistory.swift",
                "Runtime/DesktopActionExecutor.swift",
                "Runtime/ElsonPromptCatalog.swift",
                "Runtime/EmbeddedAgentTransport.swift",
                "Runtime/ElsonLocalConfig.swift",
                "Runtime/ElsonRuntime.swift",
                "Runtime/GroqTranscriptionSanitizer.swift",
                "Runtime/IntentEvalFixtureStore.swift",
                "Runtime/LocalAIService.swift",
                "Runtime/LocalDirectTransport.swift",
                "Runtime/MyElsonMemory.swift",
                "Runtime/PostResponseCorrectionCoordinator.swift",
                "Runtime/RuntimeTransport.swift",
                "Runtime/ShortcutWakeWord.swift",
                "Services/AudioRecordingService.swift",
                "Services/AIService.swift",
                "Services/KeyboardService.swift",
                "Services/LocalChunkedAudioSession.swift",
                "Services/LocalChunkedAudioRetryStore.swift",
                "Services/PermissionCoordinator.swift",
                "Services/ScreenSnapshotService.swift",
                "Services/SkillCatalogStore.swift",
                "Services/SystemAudioDucker.swift",
                "Utils/AttachmentDropLoader.swift",
                "Utils/ClipboardHelper.swift",
                "Utils/DebugLog.swift",
                "Utils/FrontmostAppContextResolver.swift",
                "Utils/ImageAttachmentCodec.swift",
                "Utils/NotificationHelper.swift",
                "Views/BubbleIndicatorView.swift",
                "Views/ContentView.swift",
                "Views/CopyFeedbackButton.swift",
                "Views/ElsonSettingsView.swift",
                "Views/FeedbackPanelView.swift",
                "Views/ElsonSettingsComponents.swift",
                "Views/FWTextEditor.swift",
                "Views/FloatingFeedbackWindow.swift",
                "Views/FloatingIndicatorWindow.swift",
                "Views/GlassBubble.swift",
                "Views/InstallOnboardingView.swift",
                "Views/InstallOnboardingArtView.swift",
                "Views/MarkdownMessageView.swift",
                "Views/RecordingShortcutCaptureButton.swift",
                "Views/StatusMenuView.swift",
                "Views/ThreadHistoryComponents.swift",
                "Views/ThreadHistoryWindowView.swift",
            ],
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/model-config.json"),
                .copy("Resources/prompt-config.json"),
            ],
            swiftSettings: buildVariant.swiftSettings
        ),
    ]
)
