import SwiftUI

struct PopoverIndicatorView: View {
    @Environment(AppSettings.self) private var appSettings
    let recordingService: AudioRecordingService

    var body: some View {
        GlassPopover(
            transcription: appSettings.lastTranscription,
            recordingService: recordingService,
            onCopy: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    appSettings.indicatorState = .success
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(name: .closePopover, object: nil)
                }
            }
        )
        .fixedSize()
    }
}
