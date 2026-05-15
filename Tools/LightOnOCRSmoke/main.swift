import AppKit
import CoreImage
import Foundation
import Gemma4Swift
import MLX
import MLXLMCommon
import MLXVLM

@main
enum LightOnOCRSmoke {
    private static let modelID = "mlx-community/LightOnOCR-1B-1025-4bit"

    static func main() async throws {
        let startedAt = Date()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let imageURL = try makeInputImageURL(root: root)
        let modelCache = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("LocalProcessor", isDirectory: true)
            .appendingPathComponent("LLMModels", isDirectory: true)
        Gemma4ModelCache.customModelsDirectory = modelCache

        print("lighton-smoke model=\(modelID)")
        print("lighton-smoke cache=\(modelCache.path)")
        print("lighton-smoke image=\(imageURL.path)")

        if !Gemma4ModelCache.isDownloaded(modelId: modelID) {
            print("lighton-smoke download=missing; downloading")
            _ = try await Gemma4ModelDownloader.download(modelId: modelID) { progress in
                let percent = Int((progress.bytesFraction * 100).rounded())
                print("lighton-smoke download progress=\(percent)% file=\(progress.currentFile)")
            }
        }

        let modelPath = modelID.split(separator: "/").reduce(modelCache) { partial, part in
            partial.appendingPathComponent(String(part), isDirectory: true)
        }
        guard FileManager.default.fileExists(atPath: modelPath.appendingPathComponent("config.json").path) else {
            throw SmokeError.missingModel(modelID)
        }

        try patchLightOnProcessorConfigIfNeeded(at: modelPath)
        let prompt = try promptConfigString(key: "local_ocr_user_prompt", root: root)

        let loadStartedAt = Date()
        print("lighton-smoke load=start")
        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelPath,
            using: Gemma4TokenizerLoader()
        )
        print("lighton-smoke load=ok seconds=\(seconds(since: loadStartedAt))")

        guard let ciImage = CIImage(contentsOf: imageURL) else {
            throw SmokeError.invalidImage(imageURL.path)
        }

        let generationStartedAt = Date()
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: 160, temperature: 0.0, topP: 1),
            processing: .init(resize: nil)
        )
        let response = try await session.respond(to: prompt, images: [.ciImage(ciImage)], videos: [])
        print("lighton-smoke generation=ok seconds=\(seconds(since: generationStartedAt))")
        print("lighton-smoke response=\(response.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("lighton-smoke gpu_peak_mb=\(MLX.Memory.peakMemory / (1024 * 1024))")
        print("lighton-smoke done seconds=\(seconds(since: startedAt))")
    }

    private static func makeInputImageURL(root: URL) throws -> URL {
        if let path = CommandLine.arguments.dropFirst().first {
            let url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SmokeError.missingImage(url.path)
            }
            return url
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elson-lighton-ocr-smoke.png")
        let image = NSImage(size: NSSize(width: 900, height: 260))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 260).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 42, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        "Elson OCR smoke test 1500 Euro".draw(
            in: NSRect(x: 48, y: 104, width: 804, height: 80),
            withAttributes: attributes
        )
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw SmokeError.invalidImage(outputURL.path)
        }
        try png.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private static func promptConfigString(key: String, root: URL) throws -> String {
        let url = root
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("prompt-config.json")
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = object[key] as? [String]
        else {
            throw SmokeError.missingPromptKey(key)
        }
        return lines.joined(separator: "\n")
    }

    private static func patchLightOnProcessorConfigIfNeeded(at modelDirectory: URL) throws {
        try patchLightOnProcessorConfigFileIfNeeded(
            at: modelDirectory.appendingPathComponent("processor_config.json")
        )
        try patchLightOnProcessorConfigFileIfNeeded(
            at: modelDirectory.appendingPathComponent("preprocessor_config.json")
        )
    }

    private static func patchLightOnProcessorConfigFileIfNeeded(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard object["processor_class"] as? String == "LightOnOCRProcessor" else { return }

        if object["image_processor"] == nil {
            let imageProcessor = object
            object = [
                "processor_class": "LightOnOCRProcessor",
                "image_processor": imageProcessor,
                "image_token": "<|image_pad|>",
                "patch_size": imageProcessor["patch_size"] ?? 14,
                "spatial_merge_size": 2,
            ]
        } else if object["image_token"] == nil {
            object["image_token"] = "<|image_pad|>"
            object["patch_size"] = object["patch_size"] ?? 14
            object["spatial_merge_size"] = object["spatial_merge_size"] ?? 2
        } else {
            return
        }

        let patched = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try patched.write(to: url, options: .atomic)
    }

    private static func seconds(since startedAt: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(startedAt))
    }
}

private enum SmokeError: LocalizedError {
    case missingImage(String)
    case invalidImage(String)
    case missingModel(String)
    case missingPromptKey(String)

    var errorDescription: String? {
        switch self {
        case .missingImage(let path):
            "Missing image: \(path)"
        case .invalidImage(let path):
            "Invalid image: \(path)"
        case .missingModel(let model):
            "Missing local model: \(model)"
        case .missingPromptKey(let key):
            "Missing prompt-config key: \(key)"
        }
    }
}
