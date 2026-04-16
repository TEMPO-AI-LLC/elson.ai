import AppKit
import Foundation
import UniformTypeIdentifiers

enum AttachmentDropLoader {
    static func loadAttachments(from providers: [NSItemProvider], limitCount: Int, limitTotalBytes: Int) async -> [AgentAttachment] {
        guard limitCount > 0 else { return [] }
        guard limitTotalBytes > 0 else { return [] }

        var out: [AgentAttachment] = []
        out.reserveCapacity(min(limitCount, providers.count))

        var remainingBytes = limitTotalBytes

        for provider in providers {
            if out.count >= limitCount { break }
            if remainingBytes <= 0 { break }

            if let urls = await loadFileURLs(from: provider) {
                for url in urls {
                    if out.count >= limitCount { break }
                    if remainingBytes <= 0 { break }
                    if let attachment = makeAttachment(fromFileURL: url, remainingBytes: remainingBytes, suggestedName: provider.suggestedName) {
                        out.append(attachment)
                        remainingBytes -= attachment.data.count
                    }
                }
                if out.count >= limitCount { break }
            }

            // Some drag sources provide file data without a file URL (e.g. PDF from certain apps).
            // Best-effort: use file representation first (supports file promises), then fall back to in-memory data.
            if out.count < limitCount, remainingBytes > 0 {
                if let fileURL = await loadFileRepresentationURL(from: provider, typeIdentifier: UTType.pdf.identifier),
                   let attachment = makeAttachment(fromFileURL: fileURL, remainingBytes: remainingBytes, suggestedName: provider.suggestedName)
                {
                    out.append(attachment)
                    remainingBytes -= attachment.data.count
                } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier),
                          let data = await loadData(from: provider, typeIdentifier: UTType.pdf.identifier),
                          !data.isEmpty,
                          data.count <= remainingBytes
                {
                    let base = (provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                        ? provider.suggestedName!
                        : "dropped"
                    let name = base.lowercased().hasSuffix(".pdf") ? base : "\(base).pdf"
                    out.append(AgentAttachment(fileName: name, mimeType: "application/pdf", data: data))
                    remainingBytes -= data.count
                }
            }

            // Generic file promise/data fallback: try to get a temporary file for any type.
            // This is especially useful when the drag source doesn't expose a file URL.
            if out.count < limitCount, remainingBytes > 0 {
                let typeIdentifiers = [
                    UTType.data.identifier,
                    UTType.item.identifier,
                ]
                for typeIdentifier in typeIdentifiers {
                    if out.count >= limitCount { break }
                    if remainingBytes <= 0 { break }
                    guard let fileURL = await loadFileRepresentationURL(from: provider, typeIdentifier: typeIdentifier) else { continue }
                    guard let attachment = makeAttachment(fromFileURL: fileURL, remainingBytes: remainingBytes, suggestedName: provider.suggestedName) else { continue }
                    out.append(attachment)
                    remainingBytes -= attachment.data.count
                    break
                }
            }

            // Fallback for non-file drags (e.g. dragged images from browsers/apps).
            if out.count < limitCount, remainingBytes > 0 {
                if let data = await loadImageData(from: provider),
                   let jpeg = ImageAttachmentCodec.jpegData(from: data),
                   jpeg.count <= remainingBytes
                {
                    out.append(AgentAttachment(fileName: "pasted.jpg", mimeType: "image/jpeg", data: jpeg))
                    remainingBytes -= jpeg.count
                }
            }

            // Fallback for dragged text selections (best-effort).
            if out.count < limitCount, remainingBytes > 0 {
                if let textData = await loadData(from: provider, typeIdentifier: UTType.plainText.identifier),
                   !textData.isEmpty,
                   textData.count <= remainingBytes
                {
                    out.append(AgentAttachment(fileName: "dropped.txt", mimeType: "text/plain", data: textData))
                    remainingBytes -= textData.count
                }
            }
        }

        return out
    }

    private static func loadFileURLs(from provider: NSItemProvider) async -> [URL]? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: [url])
                    return
                }
                if let nsurl = item as? NSURL, let url = nsurl as URL? {
                    continuation.resume(returning: [url])
                    return
                }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: [url])
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func loadFileRepresentationURL(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { return nil }

        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private static func makeAttachment(fromFileURL url: URL, remainingBytes: Int, suggestedName: String?) -> AgentAttachment? {
        guard url.isFileURL else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        if values?.isDirectory == true { return nil }

        let inferredName: String = {
            if !url.lastPathComponent.isEmpty { return url.lastPathComponent }
            if let suggestedName, !suggestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return suggestedName }
            return "attachment"
        }()
        let contentType = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let mimeType = contentType?.preferredMIMEType ?? "application/octet-stream"

        if String(mimeType).lowercased().starts(with: "image/") {
            if let jpeg = ImageAttachmentCodec.jpegData(fromFileURL: url), !jpeg.isEmpty, jpeg.count <= remainingBytes {
                let base = url.deletingPathExtension().lastPathComponent
                let name = base.isEmpty ? "image.jpg" : "\(base).jpg"
                return AgentAttachment(fileName: name, mimeType: "image/jpeg", data: jpeg)
            }
            return nil
        }

        let fileSize = values?.fileSize ?? 0
        guard fileSize <= remainingBytes else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        guard data.count <= remainingBytes else { return nil }
        return AgentAttachment(fileName: inferredName, mimeType: mimeType, data: data)
    }

    private static func loadImageData(from provider: NSItemProvider) async -> Data? {
        let candidates: [UTType] = [
            .jpeg,
            .png,
            .tiff,
            .image,
        ].compactMap { $0 }

        for type in candidates {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let data = await loadData(from: provider, typeIdentifier: type.identifier) {
                    return data
                }
            }
        }

        return nil
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
