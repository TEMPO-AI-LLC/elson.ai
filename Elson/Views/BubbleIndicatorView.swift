import SwiftUI
import UniformTypeIdentifiers

struct BubbleIndicatorView: View {
    @Environment(AppSettings.self) private var appSettings
    let recordingService: AudioRecordingService
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            GlassBubble(
                status: mapIndicatorState(appSettings.indicatorState),
                inputLevel: recordingService.inputLevel,
                action: toggleThreadWindow
            )
        }
        .frame(width: 64, height: 64, alignment: .center)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: .toggleBubbleInterface)) { _ in
            toggleThreadWindow()
        }
        .onDrop(
            of: [
                UTType.fileURL.identifier,
                UTType.item.identifier,
                UTType.data.identifier,
                UTType.image.identifier,
                UTType.plainText.identifier,
            ],
            isTargeted: $isDropTargeted
        ) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: isDropTargeted) { _, targeted in
            guard targeted else { return }
            openThreadWindow()
        }
    }

    private func openThreadWindow() {
        NotificationCenter.default.post(name: .openThreadWindow, object: nil)
    }

    private func toggleThreadWindow() {
        NotificationCenter.default.post(name: .toggleThreadWindow, object: nil)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        openThreadWindow()

        Task {
            let (existingCount, existingBytes) = await MainActor.run {
                (appSettings.pendingAttachments.count, appSettings.pendingAttachments.reduce(0, { $0 + $1.data.count }))
            }
            let remainingCount = max(0, 5 - existingCount)
            let remainingBytes = max(0, (20 * 1024 * 1024) - existingBytes)
            guard remainingCount > 0, remainingBytes > 0 else { return }
            let attachments = await AttachmentDropLoader.loadAttachments(from: providers, limitCount: remainingCount, limitTotalBytes: remainingBytes)
            await MainActor.run {
                appSettings.appendAgentAttachments(attachments)
            }
        }

        return true
    }

    private func mapIndicatorState(_ state: IndicatorState) -> GlassBubble.Status {
        switch state {
        case .hidden, .idle:
            return .idle
        case .listening:
            return .listening
        case .processing:
            return .processing
        case .agentProcessing:
            return .agentProcessing
        case .success:
            return .success
        case .agentSuccess:
            return .agentSuccess
        case .error:
            return .error
        }
    }
}
