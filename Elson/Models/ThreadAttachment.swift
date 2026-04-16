import AppKit
import Foundation

struct ChatMessageAttachment: Identifiable, Equatable, Codable, Hashable {
    let kind: String
    let displayName: String
    let mimeType: String
    let relativePath: String

    var id: String { relativePath }

    var isImage: Bool {
        kind == "image" || mimeType.lowercased().hasPrefix("image/")
    }
}

enum ThreadAttachmentStore {
    static func storeScreenshotJPEG(
        _ data: Data,
        threadId: String,
        messageId: UUID,
        index: Int = 1
    ) -> ChatMessageAttachment? {
        guard !data.isEmpty else { return nil }

        let safeThread = safeComponent(threadId)
        let safeMessage = safeComponent(messageId.uuidString)
        let fileName = "screenshot-\(index).jpg"
        let fileManager = FileManager.default
        let directoryURL = rootURL()
            .appendingPathComponent(safeThread, isDirectory: true)
            .appendingPathComponent(safeMessage, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent(fileName)

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            let relativePath = "\(safeThread)/\(safeMessage)/\(fileName)"
            DebugLog.runtime(
                "thread_attachment_stored thread_id=\(threadId) message_id=\(messageId.uuidString) stored_attachment_count=1 stored_screenshot_path=\(relativePath) attachment_renderable=true"
            )
            return ChatMessageAttachment(
                kind: "image",
                displayName: "Screenshot",
                mimeType: "image/jpeg",
                relativePath: relativePath
            )
        } catch {
            DebugLog.runtimeError(
                "thread_attachment_store_failed thread_id=\(threadId) message_id=\(messageId.uuidString) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    static func fileURL(for attachment: ChatMessageAttachment) -> URL {
        rootURL().appendingPathComponent(attachment.relativePath)
    }

    static func image(for attachment: ChatMessageAttachment) -> NSImage? {
        guard attachment.isImage else { return nil }
        let url = fileURL(for: attachment)
        return NSImage(contentsOf: url)
    }

    private static func rootURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("thread-attachments", isDirectory: true)
    }

    private static func safeComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
