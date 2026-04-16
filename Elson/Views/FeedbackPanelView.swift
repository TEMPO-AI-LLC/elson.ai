import SwiftUI

struct FeedbackPanelView: View {
    @Environment(AppSettings.self) private var appSettings

    @State private var rating: FeedbackRating = .good
    @State private var routeOverride: FeedbackRouteOverride = .unchanged
    @State private var noteText = ""
    @State private var noteHeight: CGFloat = 72
    @State private var isNoteFocused = false
    @State private var statusText: String?
    @State private var isSubmitting = false
    @State private var feedbackRecorder = AudioRecordingService()

    private var snapshot: LastOutputSnapshot? {
        appSettings.activeFeedbackContext?.snapshot ?? appSettings.lastOutputSnapshot
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            snapshotPreview
            controls
            footer
        }
        .padding(18)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)
        .onAppear {
            guard let snapshot else { return }
            rating = .good
            routeOverride = .unchanged
            noteText = ""
            statusText = "For \(snapshot.sourceSurface)."
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Feedback")
                    .font(.system(size: 15, weight: .semibold))
                if let snapshot {
                    Text(snapshot.requestId)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button("Close") {
                closePanel()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .semibold))
        }
    }

    @ViewBuilder
    private var snapshotPreview: some View {
        if let snapshot {
            HStack(alignment: .top, spacing: 10) {
                previewCard(title: "Processed", text: snapshot.processedText)
                previewCard(title: "Raw", text: snapshot.rawTranscript ?? "No raw transcript")
            }
        } else {
            previewCard(title: "No output", text: "Run Elson once, then use the feedback shortcut.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                feedbackButton(title: "Good", selected: rating == .good) {
                    rating = .good
                }
                feedbackButton(title: "Bad", selected: rating == .bad) {
                    rating = .bad
                }

                Spacer()

                Picker("Route", selection: $routeOverride) {
                    Text("Keep route").tag(FeedbackRouteOverride.unchanged)
                    Text("Transcript").tag(FeedbackRouteOverride.directTranscript)
                    Text("Full Agent").tag(FeedbackRouteOverride.fullAgent)
                }
                .labelsHidden()
                .frame(width: 150)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Note")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(action: toggleNoteRecording) {
                        Label(
                            feedbackRecorder.isRecording ? "Stop mic" : "Use mic",
                            systemImage: feedbackRecorder.isRecording ? "stop.fill" : "mic.fill"
                        )
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                }

                FWTextEditor(
                    text: $noteText,
                    isFocused: $isNoteFocused,
                    minVisibleLines: 3,
                    maxVisibleLines: 5,
                    measuredHeight: $noteHeight,
                    showsVerticalScrollerWhenClipped: true,
                    textInsetX: 8,
                    textInsetY: 6,
                    lineFragmentPadding: 0,
                    onEscape: closePanel
                )
                .frame(height: noteHeight)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center) {
            Text(statusText ?? "Stored in feedback.jsonl.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            Button("Save") {
                submitFeedback()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting || snapshot == nil)
        }
    }

    private func previewCard(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func feedbackButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 70)
        }
        .buttonStyle(.borderedProminent)
        .tint(selected ? .accentColor : .gray.opacity(0.45))
    }

    private func toggleNoteRecording() {
        if feedbackRecorder.isRecording {
            stopNoteRecording()
        } else {
            startNoteRecording()
        }
    }

    private func startNoteRecording() {
        Task { @MainActor in
            do {
                try await PermissionCoordinator.ensureMicrophonePermission()
            } catch {
                statusText = error.localizedDescription
                return
            }

            guard feedbackRecorder.startRecording() else {
                statusText = "Could not start mic."
                return
            }

            statusText = "Recording note…"
            DebugLog.runtime("feedback_note_recording_started")
        }
    }

    private func stopNoteRecording() {
        guard let snapshot else { return }
        guard let audioURL = feedbackRecorder.stopRecordingDiscardingIfShorterThan(0.35) else {
            statusText = "Note recording too short."
            return
        }

        statusText = "Transcribing note…"
        DebugLog.runtime("feedback_note_transcription_started request_id=\(snapshot.requestId)")

        Task {
            defer { try? FileManager.default.removeItem(at: audioURL) }

            do {
                let transcript = try await LocalAIService().transcribe(
                    audioURL: audioURL,
                    groqAPIKey: appSettings.makeLocalConfig().groqAPIKey,
                    logContext: LocalRequestLogContext(
                        requestId: snapshot.requestId,
                        threadId: snapshot.threadId ?? "feedback",
                        surface: "feedback",
                        inputSource: "audio"
                    ),
                    extraMetadata: "purpose=feedback_note_stt"
                )

                await MainActor.run {
                    appendToNote(transcript)
                    statusText = "Note ready."
                    DebugLog.runtime("feedback_note_transcription_completed request_id=\(snapshot.requestId) chars=\(transcript.count)")
                }
            } catch {
                await MainActor.run {
                    statusText = error.localizedDescription
                }
            }
        }
    }

    private func appendToNote(_ addition: String) {
        let trimmed = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            noteText = trimmed
        } else if noteText.hasSuffix(" ") || noteText.hasSuffix("\n") {
            noteText += trimmed
        } else {
            noteText += " " + trimmed
        }
    }

    private func submitFeedback() {
        guard let subject = snapshot?.feedbackSubject else {
            statusText = "No output to attach."
            return
        }

        isSubmitting = true
        Task { @MainActor in
            let saved = await appSettings.submitFeedback(
                subject: subject,
                rating: rating,
                note: noteText,
                routeOverride: routeOverride
            )
            isSubmitting = false

            guard saved else {
                statusText = "Could not save feedback."
                return
            }

            closePanel()
        }
    }

    private func closePanel() {
        if feedbackRecorder.isRecording {
            _ = feedbackRecorder.stopRecording()
        }
        appSettings.endFeedbackCapture()
        NotificationCenter.default.post(name: .closeFeedbackWindow, object: nil)
    }
}
