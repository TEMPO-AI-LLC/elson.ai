import AppKit
import SwiftUI

struct StatusMenuView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(ChatStore.self) private var chatStore
    let recordingService: AudioRecordingService

    var body: some View {
        ElsonGlassGroup(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Elson.ai")
                        .font(.headline)
                    if let sessionId = appSettings.lastReplayableCaptureSessionId {
                        Button {
                            appSettings.reprocessCapturedSession(sessionId: sessionId, chatStore: chatStore, source: "menu_replay")
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .disabled(appSettings.reprocessingCapturedSessionId != nil)
                        .help("Replay")
                    }
                    Spacer()
                    statusDot
                }

                if let snapshot = appSettings.lastOutputSnapshot, snapshot.isUsableForFeedback {
                    HStack(alignment: .top, spacing: 10) {
                        outputCard(title: "Processed", text: snapshot.processedText)
                        if let rawTranscript = snapshot.rawTranscript, !rawTranscript.isEmpty {
                            outputCard(title: "Raw", text: rawTranscript)
                        }
                    }
                }

                VStack(spacing: 0) {
                    menuButton("Open Chat", systemImage: "bubble.left.and.bubble.right") {
                        NotificationCenter.default.post(name: .openThreadWindow, object: nil)
                    }
                    Divider().overlay(Color.primary.opacity(0.08))
                    SettingsLink {
                        Label("Open Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    Divider().overlay(Color.primary.opacity(0.08))
                    menuButton("Open Privacy Settings", systemImage: "lock.shield") {
                        recordingService.openSystemPreferences()
                    }
                    Divider().overlay(Color.primary.opacity(0.08))
                    menuButton("Open Screen Recording Settings", systemImage: "rectangle.on.rectangle") {
                        ScreenSnapshotService.shared.openSystemPreferences()
                    }
                    Divider().overlay(Color.primary.opacity(0.08))
                    menuButton("Quit Elson.ai", systemImage: "power", destructive: true) {
                        NSApp.terminate(nil)
                    }
                }
                .elsonGlassSurface(.chrome, in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
            }
        }
        .frame(width: 320)
        .padding(16)
        .elsonGlassCard(cornerRadius: 22)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    private var statusColor: Color {
        switch appSettings.indicatorState {
        case .idle:
            return .gray
        case .listening:
            return .blue
        case .processing:
            return .orange
        case .agentProcessing:
            return .purple
        case .success:
            return .green
        case .agentSuccess:
            return .purple
        case .error:
            return .red
        case .hidden:
            return .clear
        }
    }

    @ViewBuilder
    private func menuButton(_ title: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(title)
                Spacer()
            }
            .foregroundStyle(destructive ? Color.red.opacity(0.95) : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func outputCard(title: String, text: String) -> some View {
        StatusMenuOutputCard(title: title, text: text)
    }
}

private struct StatusMenuOutputCard: View {
    let title: String
    let text: String

    @State private var isCopied = false
    @State private var resetTask: Task<Void, Never>? = nil

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                if isCopied {
                    Text("Copied")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.green)
                }

                Button(action: copy) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(trimmedText.isEmpty)
                .help("Copy")
            }

            Text(text)
                .font(.caption)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elsonGlassSurface(.chrome, in: RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: false)
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private func copy() {
        guard !trimmedText.isEmpty, ClipboardHelper.copyToClipboard(trimmedText) else { return }

        resetTask?.cancel()
        isCopied = true
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            isCopied = false
            resetTask = nil
        }
    }
}
