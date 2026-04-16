import AppKit
import SwiftUI

@main
struct ElsonApp: App {
    @State private var appSettings = AppSettings()
    @State private var recordingService = AudioRecordingService()
    @State private var keyboardService = KeyboardService()
    @State private var chatStore = ChatStore()
    @State private var windowCoordinator = ElsonWindowCoordinator()
    @State private var didConfigureApplication = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appSettings)
                .environment(chatStore)
                .environment(keyboardService)
                .onAppear {
                    configureApplicationIfNeeded()
                    appSettings.refreshOnboardingStoredFlag()
                    windowCoordinator.syncBubbleVisibility()
                }
                .onChange(of: appSettings.bubbleOnlyWhileRecording) { _, _ in
                    windowCoordinator.syncBubbleVisibility()
                }
                .onChange(of: recordingService.isRecording) { _, _ in
                    windowCoordinator.syncBubbleVisibility()
                }
                .onChange(of: appSettings.didCompleteOnboarding) { _, _ in
                    windowCoordinator.syncBubbleVisibility()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    appSettings.refreshOnboardingStoredFlag()
                    windowCoordinator.syncBubbleVisibility()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Settings {
            ElsonSettingsView(recordingService: recordingService)
                .environment(appSettings)
                .environment(chatStore)
        }

        MenuBarExtra {
            StatusMenuView(recordingService: recordingService)
                .environment(appSettings)
        } label: {
            Text("E")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    private func configureApplicationIfNeeded() {
        guard !didConfigureApplication else { return }

        appSettings.applyLaunchAtLoginPreference()
        keyboardService.setup(
            with: appSettings,
            recordingService: recordingService,
            chatStore: chatStore
        )
        windowCoordinator.configure(
            appSettings: appSettings,
            recordingService: recordingService,
            chatStore: chatStore
        )
        didConfigureApplication = true
    }
}
