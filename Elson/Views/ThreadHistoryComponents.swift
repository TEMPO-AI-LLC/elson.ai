import SwiftUI

struct ThreadHistoryTopChrome: View {
    let topChromeHeight: CGFloat
    let replaySessionId: String?
    let isReprocessing: Bool
    let onNewChat: () -> Void
    let onReplay: (String) -> Void

    var body: some View {
        HStack {
            Button(action: onNewChat) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .elsonGlassSurface(.control, in: Circle())
            }
            .buttonStyle(.plain)

            if let replaySessionId {
                Button {
                    onReplay(replaySessionId)
                } label: {
                    Group {
                        if isReprocessing {
                            ProgressView()
                                .scaleEffect(0.55)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .elsonGlassSurface(.control, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isReprocessing)
                .help("Replay")
            }

            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .elsonGlassSurface(.control, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .frame(height: topChromeHeight, alignment: .top)
    }
}

struct ThreadHistoryComposer: View {
    let recordingService: AudioRecordingService
    @Binding var selectedThreadTarget: ThreadReplyTarget?
    @Binding var pendingThreadTarget: ThreadReplyTarget
    @Binding var draftText: String
    @Binding var isComposerFocused: Bool
    @Binding var composerHeight: CGFloat
    let capturedVoiceSession: LocalChunkedAudioSession?
    let isSending: Bool
    let canSend: Bool
    let onToggleVoiceCapture: () -> Void
    let onEscape: () -> Void
    let onSend: () -> Void

    var body: some View {
        ElsonGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onToggleVoiceCapture) {
                    Image(systemName: recordingService.isRecording ? "stop.fill" : "mic.fill")
                        .foregroundStyle(recordingService.isRecording ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .frame(width: 36, height: 36)
                        .background(recordingService.isRecording ? Color.accentColor : Color.clear)
                        .clipShape(Circle())
                        .elsonGlassSurface(.control, in: Circle())
                }
                .buttonStyle(.plain)

                ZStack(alignment: .leading) {
                    if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, capturedVoiceSession == nil {
                        Text("Message")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                            .allowsHitTesting(false)
                    }

                    FWTextEditor(
                        text: $draftText,
                        isFocused: $isComposerFocused,
                        isEditable: !isSending && !recordingService.isRecording,
                        minVisibleLines: 1,
                        maxVisibleLines: 5.5,
                        measuredHeight: $composerHeight,
                        showsVerticalScrollerWhenClipped: true,
                        textInsetX: 6,
                        textInsetY: 4,
                        lineFragmentPadding: 0,
                        onSubmit: onSend,
                        onEscape: onEscape
                    )
                    .frame(height: composerHeight)
                    .opacity(recordingService.isRecording ? 0.55 : 1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .elsonGlassControl(cornerRadius: 20)

                modeControl

                Button(action: onSend) {
                    Group {
                        if isSending {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.up")
                                .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(canSend ? Color.accentColor : Color.clear)
                    .clipShape(Circle())
                    .elsonGlassSurface(.control, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
    }

    @ViewBuilder
    private var modeControl: some View {
        if let selectedThreadTarget {
            Circle()
                .fill(selectedThreadTarget == .transcript ? Color.orange : Color.purple)
                .frame(width: 10, height: 10)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
        } else {
            Button {
                pendingThreadTarget = pendingThreadTarget == .transcript ? .agent : .transcript
            } label: {
                ZStack(alignment: pendingThreadTarget == .agent ? .trailing : .leading) {
                    Capsule(style: .continuous)
                        .fill((pendingThreadTarget == .transcript ? Color.orange : Color.purple).opacity(0.88))
                        .frame(width: 42, height: 24)

                    Circle()
                        .fill(Color.white.opacity(0.96))
                        .frame(width: 20, height: 20)
                        .padding(.horizontal, 2)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

struct ThreadHistoryMessageRow: View {
    let message: ConversationThreadMessage
    let transcriptText: String
    let isVoiceExpanded: Bool
    let assistantHoverVisible: Bool
    let onToggleVoiceExpansion: () -> Void
    let onOpenAttachment: (ChatMessageAttachment) -> Void
    let onHoverAssistant: (Bool) -> Void
    let onReplayVoiceMessage: (String) -> Void

    private var insertedText: String? {
        let trimmed = message.insertedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        let normalizedInserted = trimmed
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.content
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedInserted != normalizedMessage else { return nil }
        return trimmed
    }

    var body: some View {
        let isAssistant = message.role == .assistant
        let bubbleStyle: ElsonGlassSurfaceStyle = isAssistant ? .chrome : .control
        let bubbleShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let primaryAttachment = message.attachments.first
        let bubbleContent = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(isAssistant ? "Elson.ai" : "You")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if !isAssistant,
                   let captureSessionId = message.captureSessionId {
                    Button {
                        onReplayVoiceMessage(captureSessionId)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Replay")
                }

                if !isAssistant,
                   message.showsAttachmentChip,
                   let attachment = primaryAttachment {
                    Button {
                        onOpenAttachment(attachment)
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isAssistant {
                VStack(alignment: .leading, spacing: 10) {
                    MarkdownMessageView(message.content)

                    if let insertedText {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("Inserted")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                Spacer(minLength: 0)

                                CopyFeedbackButton(text: insertedText)
                            }

                            MarkdownMessageView(insertedText)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                }
            } else if message.style == .voiceTranscript {
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: onToggleVoiceExpansion) {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "waveform")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 0)

                            Image(systemName: isVoiceExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(transcriptText)

                    if !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if isVoiceExpanded {
                                HStack(spacing: 8) {
                                    Spacer(minLength: 0)
                                    CopyFeedbackButton(text: transcriptText)
                                }
                            }

                            Text(transcriptText)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .lineLimit(isVoiceExpanded ? nil : 4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else {
                Text(message.content)
                    .textSelection(.enabled)
            }
        }

        HStack {
            if isAssistant { Spacer(minLength: 36) }
            ZStack(alignment: .topTrailing) {
                bubbleContent
                    .padding(12)
                    .elsonGlassSurface(
                        bubbleStyle,
                        in: bubbleShape,
                        interactive: false
                    )

                if isAssistant {
                    HStack(spacing: 6) {
                        CopyFeedbackButton(
                            text: message.content,
                            isVisible: assistantHoverVisible
                        )
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
            }
            .contentShape(bubbleShape)
            .onHover { hovering in
                guard isAssistant else { return }
                onHoverAssistant(hovering)
            }
            if !isAssistant { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ThreadHistoryInFlightRow: View {
    let title: String

    var body: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.75)
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .elsonGlassSurface(.control, in: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: false)
    }
}
