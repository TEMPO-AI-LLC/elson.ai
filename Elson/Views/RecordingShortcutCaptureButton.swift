import AppKit
import SwiftUI

struct RecordingShortcutCaptureButton: View {
    @Binding var shortcut: RecordingShortcut

    @State private var isCapturing = false
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?
    @State private var lastObservedShortcut: RecordingShortcut = .default
    @State private var finalizeTask: Task<Void, Never>?

    var body: some View {
        Button(action: toggleCapture) {
            VStack(spacing: 16) {
                Image(systemName: isCapturing ? "keyboard.badge.ellipsis" : "keyboard")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isCapturing ? .white : .secondary)

                if isCapturing {
                    Text("Press shortcut")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    HStack(spacing: 10) {
                        ForEach(shortcut.symbolTokens, id: \.self) { token in
                            shortcutToken(token)
                        }
                    }
                }

                Text(isCapturing ? "Esc to cancel" : "Click to change")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isCapturing ? Color.white.opacity(0.78) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .padding(.horizontal, 28)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(isCapturing ? Color.blue : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(isCapturing ? Color.blue.opacity(0.9) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Press a modifier combo. fn is the default.")
        .onDisappear {
            stopCapture(commit: false)
        }
    }

    @ViewBuilder
    private func shortcutToken(_ token: String) -> some View {
        Text(token)
            .font(.system(size: token == "fn" ? 24 : 28, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(minWidth: token == "fn" ? 58 : 52, minHeight: 52)
            .padding(.horizontal, token == "fn" ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private func toggleCapture() {
        if isCapturing {
            stopCapture(commit: false)
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        stopCapture(commit: false)
        isCapturing = true
        lastObservedShortcut = shortcut

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            handle(event: event)
            return nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            handle(event: event)
        }
    }

    private func handle(event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            Task { @MainActor in
                stopCapture(commit: false)
            }
            return
        }

        let observed = RecordingShortcut.from(event: event)
        guard !observed.isEmpty else { return }

        Task { @MainActor in
            lastObservedShortcut = observed
            finalizeTask?.cancel()
            finalizeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard isCapturing else { return }
                shortcut = lastObservedShortcut
                stopCapture(commit: false)
            }
        }
    }

    private func stopCapture(commit: Bool) {
        finalizeTask?.cancel()
        finalizeTask = nil

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if commit && !lastObservedShortcut.isEmpty {
            shortcut = lastObservedShortcut
        }

        isCapturing = false
    }
}
