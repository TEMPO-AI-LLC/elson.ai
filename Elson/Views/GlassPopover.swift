import SwiftUI

struct GlassPopover: View {
    static let innerContentSize = CGSize(width: 270, height: 360)
    static let windowPadding = EdgeInsets(top: 12, leading: 20, bottom: 30, trailing: 20)
    static let contentSize = CGSize(
        width: innerContentSize.width + windowPadding.leading + windowPadding.trailing,
        height: innerContentSize.height + windowPadding.top + windowPadding.bottom
    )

    @Environment(AppSettings.self) private var appSettings

    let transcription: String
    let recordingService: AudioRecordingService
    let onCopy: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Elson.ai")
                            .font(.system(size: 14, weight: .semibold))
                        Text(statusLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Open Chat") {
                        NotificationCenter.default.post(name: .openThreadWindow, object: nil)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }

                ScrollView {
                    if trimmedTranscription.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Nothing here yet.")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Start recording or open the chat window for the full thread interface.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownMessageView(trimmedTranscription)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(12)
                .elsonGlassSurface(.chrome, in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: false)

                HStack {
                    if !trimmedTranscription.isEmpty {
                        CopyFeedbackButton(text: trimmedTranscription, onSuccess: onCopy)
                    }

                    Spacer()

                    if recordingService.isRecording {
                        Label("Listening", systemImage: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .elsonGlassSurface(.control, in: Capsule(), interactive: false)
                    }
                }
            }
            .padding(18)
            .frame(width: Self.contentSize.width, height: Self.contentSize.height)
            .elsonGlassCard(cornerRadius: 24)
        }
    }

    private var trimmedTranscription: String {
        let explicitTranscript = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitTranscript.isEmpty {
            return explicitTranscript
        }
        return appSettings.lastTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusLabel: String {
        if recordingService.isRecording {
            return "Listening"
        }

        switch appSettings.indicatorState {
        case .agentProcessing:
            return "Agent working"
        case .processing:
            return "Processing"
        case .success, .agentSuccess:
            return "Ready"
        case .error:
            return "Needs attention"
        case .hidden, .idle, .listening:
            return "Standby"
        }
    }
}

#Preview {
    GlassPopover(
        transcription: "This is a sample transcription that shows the dormant popover surface using the current glass language.",
        recordingService: AudioRecordingService(),
        onCopy: {}
    )
    .environment(AppSettings())
}
