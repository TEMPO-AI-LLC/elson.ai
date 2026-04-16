import AppKit

enum ImageAttachmentCodec {
    static func isSupportedImageURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "png" || ext == "jpg" || ext == "jpeg" || ext == "webp" || ext == "heic" || ext == "heif" || ext == "tif" || ext == "tiff"
    }

    static func jpegData(fromFileURL url: URL, maxPixelSize: CGFloat = 1280, quality: CGFloat = 0.72) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return jpegData(from: data, maxPixelSize: maxPixelSize, quality: quality)
    }

    static func jpegData(from data: Data, maxPixelSize: CGFloat = 1280, quality: CGFloat = 0.72) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return jpegData(from: image, maxPixelSize: maxPixelSize, quality: quality)
    }

    static func jpegData(from image: NSImage, maxPixelSize: CGFloat = 1280, quality: CGFloat = 0.72) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let maxSide = max(width, height)
        let scale = maxSide > 0 ? min(1.0, maxPixelSize / maxSide) : 1.0
        let targetSize = CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))

        guard
            let ctx = CGContext(
                data: nil,
                width: Int(targetSize.width),
                height: Int(targetSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: targetSize))
        guard let resized = ctx.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: resized)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
