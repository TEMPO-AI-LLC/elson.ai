import Foundation

@MainActor
enum DesktopActionExecutor {
    static func execute(_ actions: [ElsonAction], appSettings: AppSettings) async -> [String] {
        var notes: [String] = []
        for action in actions {
            switch action.type {
            case "capture_screenshot":
                if let data = try? await ScreenSnapshotService.shared.captureJPEGDataIfPermitted(maxPixelSize: 1280, quality: 0.7) {
                    appSettings.pendingScreenshotJPEGData = [data]
                    notes.append("Captured screenshot locally.")
                } else {
                    notes.append("Screenshot capture failed or permission missing.")
                }
            case "paste_text", "update_myelson", "append_note", "capture_reminder":
                continue
            default:
                notes.append("Action not implemented locally: \(action.type)")
            }
        }
        return notes
    }
}
