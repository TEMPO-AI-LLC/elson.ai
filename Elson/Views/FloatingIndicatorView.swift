import SwiftUI

struct FloatingIndicatorView: View {
    @Environment(AppSettings.self) private var appSettings
    @EnvironmentObject private var windowSizer: WindowSizer

    let recordingService: AudioRecordingService
    @State private var isPopoverOpen = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if isPopoverOpen {
                GlassPopover(
                    transcription: appSettings.lastTranscription,
                    recordingService: recordingService,
                    onCopy: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            appSettings.indicatorState = .success
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation {
                                isPopoverOpen = false
                            }
                        }
                    }
                )
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

            BubbleIndicatorView(recordingService: recordingService)
        }
        .padding(16)
        .fixedSize()
        .reportSize { size in
            windowSizer.requestResize(to: size)
        }
        .opacity(appSettings.indicatorState == .hidden ? 0 : 1)
        .onChange(of: appSettings.indicatorState) { _, newState in
            if newState == .success || newState == .agentSuccess {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    appSettings.indicatorState = .idle
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleBubbleInterface)) { _ in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isPopoverOpen.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closePopover)) { _ in
            withAnimation {
                isPopoverOpen = false
            }
        }
    }
}
