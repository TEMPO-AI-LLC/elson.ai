import SwiftUI

struct CloudDashboardView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(ChatStore.self) private var chatStore
    let recordingService: AudioRecordingService

    var body: some View {
        ElsonSettingsView(recordingService: recordingService)
            .environment(appSettings)
            .environment(chatStore)
    }
}
