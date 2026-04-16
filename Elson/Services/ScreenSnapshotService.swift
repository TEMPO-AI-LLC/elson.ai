import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Security
@preconcurrency import ScreenCaptureKit

enum ScreenSnapshotError: Error, LocalizedError {
    case permissionDenied
    case captureFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission is not granted"
        case .captureFailed:
            return "Failed to capture screenshot"
        case .encodeFailed:
            return "Failed to encode screenshot"
        }
    }
}

@MainActor
final class ScreenSnapshotService {
    static let shared = ScreenSnapshotService()

    private init() {}

    private var didRequestAccessThisSession = false
    private(set) var lastFailureContext: String? = nil
    private(set) var lastFailureAt: Date? = nil

    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func debugReport() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "(nil)"
        let bundlePath = Bundle.main.bundleURL.path
        let executablePath = Bundle.main.executableURL?.path ?? "(nil)"
        let pid = ProcessInfo.processInfo.processIdentifier

        let signing = codeSigningInfo()
        let signingIdentifier = signing.identifier ?? "(unknown)"
        let teamID = signing.teamIdentifier ?? "(none)"
        let cdHash = signing.cdHash ?? "(unknown)"
        let idMatches = (bundleID == signingIdentifier) ? "true" : "false"

        let lastFailure = lastFailureContext ?? "(none)"
        let lastFailureAtString: String = {
            guard let lastFailureAt else { return "(none)" }
            return ISO8601DateFormatter().string(from: lastFailureAt)
        }()

        return """
        Screen Recording Debug Info

        Permission:
        - preflight: \(hasPermission() ? "true" : "false")
        - requestedThisSession: \(didRequestAccessThisSession ? "true" : "false")

        App:
        - bundleId: \(bundleID)
        - bundlePath: \(bundlePath)
        - executablePath: \(executablePath)
        - pid: \(pid)

        Code Signing:
        - identifier: \(signingIdentifier)
        - bundleIdMatchesSigningIdentifier: \(idMatches)
        - teamId: \(teamID)
        - cdHash: \(cdHash)

        Last Failure:
        - at: \(lastFailureAtString)
        - context: \(lastFailure)

        Notes:
        - If teamId is (none), this is an ad-hoc/unsigned build. macOS may treat each rebuild as a different app for Screen Recording permission.
        - If you have multiple copies of Elson.ai installed, ensure you're granting permission to the same one you are running (compare bundlePath).
        """
    }

    func noScreenshotTroubleshootingMessage() -> String {
        """
        No screenshot is available.

        Common causes:
        - Screen recording permission is not granted
        - Permission was granted, but macOS requires a full quit/relaunch
        - Multiple copies of the app exist (permission granted to a different copy)
        - Ad-hoc/unsigned builds (permission may not persist across rebuilds)

        To enable screenshots, grant Elson.ai permission in:
        System Settings → Privacy & Security → Screen & System Audio Recording

        Then quit Elson.ai and reopen it.

        ---
        \(debugReport())
        """
    }

    func requestAccessIfNeeded() -> Bool {
        if hasPermission() {
            return true
        }
        guard !didRequestAccessThisSession else {
            recordFailure("requestAccessIfNeeded(): suppressed (already requested this session)")
            return false
        }
        didRequestAccessThisSession = true
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            recordFailure("CGRequestScreenCaptureAccess(): returned false")
        }
        return granted
    }

    func captureJPEGDataIfPermitted(maxPixelSize: Int? = 1280, quality: CGFloat = 0.78) async throws -> Data {
        guard hasPermission() else {
            recordFailure("captureJPEGDataIfPermitted(): permission denied")
            throw ScreenSnapshotError.permissionDenied
        }

        let image = try await captureFullScreenImage()

        guard let image else {
            recordFailure("captureJPEGDataIfPermitted(): SCScreenshotManager returned nil")
            throw ScreenSnapshotError.captureFailed
        }

        let outputImage: CGImage
        if let maxPixelSize, let downscaled = downscaleIfNeeded(image: image, maxPixelSize: maxPixelSize) {
            outputImage = downscaled
        } else {
            outputImage = image
        }

        do {
            return try encodeJPEG(image: outputImage, quality: quality)
        } catch {
            recordFailure("encodeJPEG(): \(error.localizedDescription)")
            throw error
        }
    }

    func openSystemPreferences() {
        PermissionCoordinator.openScreenRecordingSettings()
    }

    func captureJPEGToTemporaryFile() async throws -> URL {
        guard hasPermission() else {
            recordFailure("captureJPEGToTemporaryFile(): permission denied")
            throw ScreenSnapshotError.permissionDenied
        }
        let data = try await captureJPEGDataIfPermitted(quality: 0.82)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("elson_screen_\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    func loadJPEGData(from url: URL?) -> Data? {
        guard let url else { return nil }
        return try? Data(contentsOf: url)
    }

    private func captureFullScreenImage() async throws -> CGImage? {
        let captureRect = NSScreen.screens
            .map(\.frame)
            .reduce(CGRect.null) { partial, frame in
                partial.union(frame)
            }

        guard !captureRect.isNull, !captureRect.isEmpty else {
            return nil
        }

        if #available(macOS 15.2, *) {
            return try await withCheckedThrowingContinuation { continuation in
                SCScreenshotManager.captureImage(in: captureRect) { image, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: image)
                    }
                }
            }
        }

        return try await captureLegacyFullScreenImage(captureRect: captureRect)
    }

    private func encodeJPEG(image: CGImage, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            recordFailure("encodeJPEG(): CGImageDestinationCreateWithData failed")
            throw ScreenSnapshotError.encodeFailed
        }

        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))
        ]
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            recordFailure("encodeJPEG(): CGImageDestinationFinalize failed")
            throw ScreenSnapshotError.encodeFailed
        }
        return data as Data
    }

    private func downscaleIfNeeded(image: CGImage, maxPixelSize: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let currentMax = max(width, height)
        guard currentMax > maxPixelSize, maxPixelSize > 0 else {
            return nil
        }

        let scale = Double(maxPixelSize) / Double(currentMax)
        let newWidth = max(1, Int(Double(width) * scale))
        let newHeight = max(1, Int(Double(height) * scale))

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    private func captureLegacyFullScreenImage(captureRect: CGRect) async throws -> CGImage? {
        let shareableContent = try await shareableContentForScreenshotCapture()
        let images = try await captureDisplayImages(from: shareableContent.displays)
        return compositeDisplayImages(images, within: captureRect)
    }

    private func shareableContentForScreenshotCapture() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            ) { shareableContent, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let shareableContent {
                    continuation.resume(returning: shareableContent)
                } else {
                    continuation.resume(throwing: ScreenSnapshotError.captureFailed)
                }
            }
        }
    }

    private func captureDisplayImages(from displays: [SCDisplay]) async throws -> [CapturedDisplayImage] {
        var capturedImages: [CapturedDisplayImage] = []

        for display in displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = max(1, CGFloat(filter.pointPixelScale))

            configuration.width = max(1, Int(display.frame.width * scale))
            configuration.height = max(1, Int(display.frame.height * scale))

            if let image = try await captureLegacyDisplayImage(filter: filter, configuration: configuration) {
                capturedImages.append(
                    CapturedDisplayImage(
                        image: image,
                        frame: display.frame
                    )
                )
            }
        }

        return capturedImages
    }

    private func captureLegacyDisplayImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage? {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    private func compositeDisplayImages(
        _ capturedImages: [CapturedDisplayImage],
        within captureRect: CGRect
    ) -> CGImage? {
        guard !capturedImages.isEmpty else {
            return nil
        }

        let scale = capturedImages
            .compactMap { capturedImage -> CGFloat? in
                guard capturedImage.frame.width > 0 else { return nil }
                return CGFloat(capturedImage.image.width) / capturedImage.frame.width
            }
            .max() ?? 1

        let canvasWidth = max(1, Int(captureRect.width * scale))
        let canvasHeight = max(1, Int(captureRect.height * scale))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        guard let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high

        for capturedImage in capturedImages {
            let drawRect = CGRect(
                x: (capturedImage.frame.minX - captureRect.minX) * scale,
                y: (capturedImage.frame.minY - captureRect.minY) * scale,
                width: capturedImage.frame.width * scale,
                height: capturedImage.frame.height * scale
            )
            context.draw(capturedImage.image, in: drawRect)
        }

        return context.makeImage()
    }

    private func recordFailure(_ context: String) {
        lastFailureContext = context
        lastFailureAt = Date()
        print("🖼️ DEBUG: ScreenSnapshotService failure: \(context)")
    }

    private struct CapturedDisplayImage {
        let image: CGImage
        let frame: CGRect
    }

    private struct CodeSigningInfo {
        let identifier: String?
        let teamIdentifier: String?
        let cdHash: String?
    }

    private func codeSigningInfo() -> CodeSigningInfo {
        guard let executableURL = Bundle.main.executableURL else {
            return CodeSigningInfo(identifier: nil, teamIdentifier: nil, cdHash: nil)
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return CodeSigningInfo(identifier: nil, teamIdentifier: nil, cdHash: nil)
        }

        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF)
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else {
            return CodeSigningInfo(identifier: nil, teamIdentifier: nil, cdHash: nil)
        }

        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
        let uniqueData = info[kSecCodeInfoUnique as String] as? Data
        let cdHash = uniqueData.map(hexString) // "unique" is the cdhash for the running code.

        return CodeSigningInfo(identifier: identifier, teamIdentifier: teamIdentifier, cdHash: cdHash)
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
