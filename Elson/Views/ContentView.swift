import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        Group {
            if appSettings.needsInstallOnboarding {
                InstallOnboardingView()
            } else {
                PixelAnchorView()
            }
        }
        .background(MainWindowCaptureView())
        .onAppear {
            NotificationHelper.requestPermission()
            appSettings.refreshOnboardingStoredFlag()
            Task { @MainActor in
                await appSettings.refreshSkillsCatalog(force: true)
            }
            if !appSettings.needsInstallOnboarding {
                appSettings.importWorkingDirectorySourcesIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appSettings.refreshOnboardingStoredFlag()
            Task { @MainActor in
                await appSettings.refreshSkillsCatalog(force: true)
            }
            if !appSettings.needsInstallOnboarding {
                appSettings.importWorkingDirectorySourcesIfNeeded()
            }
        }
        .onChange(of: appSettings.didCompleteOnboarding) { _, completed in
            guard completed else { return }
            appSettings.importWorkingDirectorySourcesIfNeeded()
        }
    }
}

private struct PixelAnchorView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
    }
}

private struct MainWindowCaptureView: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowCaptureNSView {
        MainWindowCaptureNSView()
    }

    func updateNSView(_ nsView: MainWindowCaptureNSView, context: Context) {}
}

private final class MainWindowCaptureNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mainAppWindowDidResolve, object: window)
        }
    }
}
