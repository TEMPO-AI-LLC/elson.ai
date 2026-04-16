import AppKit
import SwiftUI

@MainActor
final class ElsonWindowCoordinator {
    private final class NonActivatingHostingView<Content: View>: NSHostingView<Content> {
        required init(rootView: Content) {
            super.init(rootView: rootView)
            configureForTransparency()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        private func configureForTransparency() {
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.isOpaque = false
        }
    }

    private var bubbleWindow: FloatingIndicatorWindow?
    private var threadWindow: NSWindow?
    private var feedbackWindow: FloatingFeedbackWindow?
    private weak var mainWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var onboardingCueTask: Task<Void, Never>?
    private var isAwaitingFolderAccessReturn = false
    private var didResignActiveDuringFolderPrompt = false

    private var appSettings: AppSettings?
    private weak var recordingService: AudioRecordingService?
    private var chatStore: ChatStore?

    func configure(
        appSettings: AppSettings,
        recordingService: AudioRecordingService,
        chatStore: ChatStore
    ) {
        self.appSettings = appSettings
        self.recordingService = recordingService
        self.chatStore = chatStore

        if observers.isEmpty {
            wireWindowLifecycle()
        }
    }

    func syncBubbleVisibility() {
        guard let appSettings, let recordingService else { return }
        guard !appSettings.needsInstallOnboarding else {
            hideBubbleWindow()
            return
        }

        let shouldShowBubble = !appSettings.bubbleOnlyWhileRecording || recordingService.isRecording
        if shouldShowBubble {
            showBubbleWindow()
        } else {
            hideBubbleWindow()
        }
    }

    private func showBubbleWindow() {
        guard let appSettings, let recordingService else { return }

        if let existing = bubbleWindow {
            existing.orderFrontRegardless()
            return
        }

        let bubbleRootView = BubbleIndicatorView(recordingService: recordingService)
            .environment(appSettings)

        let window = FloatingIndicatorWindow()
        window.contentView = NonActivatingHostingView(rootView: bubbleRootView)
        window.orderFrontRegardless()
        bubbleWindow = window
    }

    private func bringBubbleToFront() {
        guard let appSettings, !appSettings.needsInstallOnboarding else { return }
        showBubbleWindow()
        bubbleWindow?.orderFrontRegardless()
    }

    private func hideBubbleWindow() {
        guard let bubbleWindow else { return }
        bubbleWindow.orderOut(nil)
        bubbleWindow.close()
        self.bubbleWindow = nil
    }

    private func wireWindowLifecycle() {
        let threadObserver = NotificationCenter.default.addObserver(
            forName: .openThreadWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showThreadWindow()
            }
        }

        let bringBubbleToFrontObserver = NotificationCenter.default.addObserver(
            forName: .bringBubbleToFront,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.bringBubbleToFront()
            }
        }

        let toggleObserver = NotificationCenter.default.addObserver(
            forName: .toggleThreadWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.toggleThreadWindow()
            }
        }

        let openFeedbackObserver = NotificationCenter.default.addObserver(
            forName: .openFeedbackWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showFeedbackWindow()
            }
        }

        let closeFeedbackObserver = NotificationCenter.default.addObserver(
            forName: .closeFeedbackWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closeFeedbackWindow()
            }
        }

        let onboardingObserver = NotificationCenter.default.addObserver(
            forName: .completeInstallOnboardingHandoff,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.completeInstallOnboardingHandoff()
            }
        }

        let mainWindowObserver = NotificationCenter.default.addObserver(
            forName: .mainAppWindowDidResolve,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let resolvedWindow = notification.object as? NSWindow
            Task { @MainActor in
                self?.mainWindow = resolvedWindow
            }
        }

        let folderPromptStartObserver = NotificationCenter.default.addObserver(
            forName: .folderAccessPromptWillBegin,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isAwaitingFolderAccessReturn = true
                self?.didResignActiveDuringFolderPrompt = false
            }
        }

        let folderPromptFinishObserver = NotificationCenter.default.addObserver(
            forName: .folderAccessPromptDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isAwaitingFolderAccessReturn = false
                self?.didResignActiveDuringFolderPrompt = false
            }
        }

        let resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isAwaitingFolderAccessReturn else { return }
                self.didResignActiveDuringFolderPrompt = true
            }
        }

        let becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restoreMainWindowAfterFolderAccessIfNeeded()
            }
        }

        observers = [
            threadObserver,
            bringBubbleToFrontObserver,
            toggleObserver,
            openFeedbackObserver,
            closeFeedbackObserver,
            onboardingObserver,
            mainWindowObserver,
            folderPromptStartObserver,
            folderPromptFinishObserver,
            resignActiveObserver,
            becomeActiveObserver,
        ]
    }

    private func completeInstallOnboardingHandoff() {
        guard let appSettings else { return }

        let onboardingWindow = mainWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        showBubbleWindow()
        onboardingWindow?.orderOut(nil)

        onboardingCueTask?.cancel()
        onboardingCueTask = Task { @MainActor in
            appSettings.indicatorState = .listening

            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            appSettings.indicatorState = .agentProcessing

            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            appSettings.indicatorState = .idle
            onboardingCueTask = nil
        }
    }

    private func restoreMainWindowAfterFolderAccessIfNeeded() {
        guard isAwaitingFolderAccessReturn, didResignActiveDuringFolderPrompt else { return }
        guard let appSettings, appSettings.needsInstallOnboarding else {
            isAwaitingFolderAccessReturn = false
            didResignActiveDuringFolderPrompt = false
            return
        }

        let onboardingWindow = mainWindow
            ?? NSApp.windows.first(where: { window in
                window !== threadWindow && window !== bubbleWindow
            })

        guard let onboardingWindow else { return }

        if onboardingWindow.isMiniaturized {
            onboardingWindow.deminiaturize(nil)
        }
        onboardingWindow.makeKeyAndOrderFront(nil)
        onboardingWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        isAwaitingFolderAccessReturn = false
        didResignActiveDuringFolderPrompt = false
    }

    private func toggleThreadWindow() {
        guard let appSettings else { return }

        guard !appSettings.needsInstallOnboarding else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let existing = threadWindow {
            if existing.isVisible && NSApp.isActive && existing.isKeyWindow {
                existing.orderOut(nil)
            } else {
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        showThreadWindow()
    }

    private func showThreadWindow() {
        guard let appSettings, let recordingService, let chatStore else { return }
        guard !appSettings.needsInstallOnboarding else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let existing = threadWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ThreadHistoryWindowView(recordingService: recordingService)
            .environment(appSettings)
            .environment(chatStore)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Elson.ai"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.center()
        window.contentView = NonActivatingHostingView(rootView: rootView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        threadWindow = window
    }

    private func showFeedbackWindow() {
        guard let appSettings else { return }
        guard appSettings.activeFeedbackContext != nil else { return }

        if let existing = feedbackWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = FeedbackPanelView()
            .environment(appSettings)

        let window = FloatingFeedbackWindow()
        window.contentView = NonActivatingHostingView(rootView: rootView)
        positionFeedbackWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        feedbackWindow = window
    }

    private func closeFeedbackWindow() {
        guard let feedbackWindow else {
            appSettings?.endFeedbackCapture()
            return
        }

        feedbackWindow.orderOut(nil)
        feedbackWindow.close()
        self.feedbackWindow = nil
        appSettings?.endFeedbackCapture()
    }

    private func positionFeedbackWindow(_ window: NSWindow) {
        if let bubbleWindow {
            let bubbleFrame = bubbleWindow.frame
            let x = max(16, bubbleFrame.minX - window.frame.width - 16)
            let y = bubbleFrame.minY
            window.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        window.center()
    }
}
