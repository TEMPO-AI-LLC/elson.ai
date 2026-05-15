import Foundation
import Gemma4Swift
import MLX
import MLXLLM
import MLXLMCommon

@main
enum GemmaImageSmoke {
    static func main() async throws {
        let startedAt = Date()
        let model = Gemma4Pipeline.Model.e4b4bit
        let imagePath = CommandLine.arguments.dropFirst().first ?? "vendor/gemma-4-swift-mlx/input_sample.jpg"
        let imageURL = URL(fileURLWithPath: imagePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        let modelCache = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("LocalProcessor", isDirectory: true)
            .appendingPathComponent("LLMModels", isDirectory: true)
        Gemma4ModelCache.customModelsDirectory = modelCache

        print("image-smoke model=\(model.rawValue)")
        print("image-smoke cache=\(modelCache.path)")
        print("image-smoke image=\(imageURL.path)")

        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw SmokeError.missingImage(imageURL.path)
        }

        if !Gemma4ModelCache.isDownloaded(model) {
            print("image-smoke download=missing; downloading")
            _ = try await Gemma4ModelDownloader.download(model) { progress in
                let percent = Int((progress.bytesFraction * 100).rounded())
                print("image-smoke download progress=\(percent)% file=\(progress.currentFile)")
            }
        }

        guard let modelPath = Gemma4ModelCache.localPath(for: model) else {
            throw SmokeError.missingModel(model.rawValue)
        }

        print("image-smoke path=\(modelPath.path)")
        print("image-smoke register=multimodal")
        await Gemma4Registration.register(multimodal: true)

        let loadStartedAt = Date()
        print("image-smoke load=start")
        let container = try await loadModelContainer(from: modelPath, using: Gemma4TokenizerLoader())
        print("image-smoke load=ok seconds=\(String(format: "%.2f", Date().timeIntervalSince(loadStartedAt)))")

        let textStartedAt = Date()
        let textSession = ChatSession(
            container,
            instructions: "You are a concise assistant.",
            generateParameters: GenerateParameters(maxTokens: 48, temperature: 0.0, topP: 0.95)
        )
        let textResponse = try await textSession.respond(to: "Reply with exactly four words about multimodal readiness.")
        print("image-smoke text_response=\(textResponse.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("image-smoke text_seconds=\(String(format: "%.2f", Date().timeIntervalSince(textStartedAt)))")

        let imageStartedAt = Date()
        let pixelValues = try Gemma4ImageProcessor.processImage(url: imageURL)
        print("image-smoke image=processed shape=\(pixelValues.shape) seconds=\(String(format: "%.2f", Date().timeIntervalSince(imageStartedAt)))")

        let prompt = "Describe the image in one concise English sentence and name the main visible object."
        let response = try await describeImage(container: container, pixelValues: pixelValues, prompt: prompt)
        print("image-smoke response=\(response.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("image-smoke gpu_peak_mb=\(MLX.GPU.peakMemory / (1024 * 1024))")
        print("image-smoke done seconds=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))")
    }

    private static func describeImage(container: ModelContainer, pixelValues: MLXArray, prompt: String) async throws -> String {
        let content = "<|image|>\n\(prompt)"
        let messages: [[String: String]] = [["role": "user", "content": content]]
        var tokenIds: [Int] = try await container.perform { context in
            try context.tokenizer.applyChatTemplate(messages: messages)
        }

        let imageTokenId = Int(Gemma4Processor.imageTokenId)
        let boiTokenId = Int(Gemma4Processor.boiTokenId)
        let eoiTokenId = Int(Gemma4Processor.eoiTokenId)
        var expandedTokenIds: [Int] = []
        for tokenId in tokenIds {
            if tokenId == imageTokenId {
                expandedTokenIds.append(boiTokenId)
                expandedTokenIds.append(contentsOf: Array(repeating: imageTokenId, count: 280))
                expandedTokenIds.append(eoiTokenId)
            } else {
                expandedTokenIds.append(tokenId)
            }
        }
        tokenIds = expandedTokenIds

        let imageCount = tokenIds.filter { $0 == imageTokenId }.count
        print("image-smoke token_count=\(tokenIds.count) image_tokens=\(imageCount)")

        nonisolated(unsafe) let capturedInputIds = MLXArray(tokenIds.map { Int32($0) })
        nonisolated(unsafe) let capturedPixelValues = pixelValues
        let tokenFilter = Gemma4TokenFilter(mode: .disabled)

        return await container.perform { context in
            guard let model = context.model as? Gemma4MultimodalLLMModel else {
                return "ERROR: loaded model is not Gemma4MultimodalLLMModel"
            }
            model.pendingPixelValues = capturedPixelValues

            let parameters = GenerateParameters(maxTokens: 96, temperature: 0.0, topP: 0.95)
            let cache = context.model.newCache(parameters: parameters)
            let prefill = context.model(capturedInputIds.reshaped(1, -1), cache: cache)
            var nextToken = argMax(prefill[0..., prefill.dim(1) - 1, 0...], axis: -1).item(Int32.self)

            var pieces: [String] = []
            var visibleTokens = 0
            for _ in 0 ..< 288 {
                if tokenFilter.isEOS(nextToken) {
                    break
                }

                let text = context.tokenizer.decode(tokenIds: [Int(nextToken)])
                let filtered = tokenFilter.process(tokenId: nextToken, text: text)
                if !filtered.isEmpty {
                    pieces.append(filtered)
                    visibleTokens += 1
                }

                if visibleTokens >= 96 {
                    break
                }

                let nextInput = MLXArray([nextToken]).reshaped(1, 1)
                let output = context.model(nextInput, cache: cache)
                nextToken = argMax(output[0..., 0, 0...], axis: -1).item(Int32.self)
            }

            return pieces.joined()
        }
    }
}

private enum SmokeError: LocalizedError {
    case missingImage(String)
    case missingModel(String)

    var errorDescription: String? {
        switch self {
        case .missingImage(let path):
            return "Missing image: \(path)"
        case .missingModel(let model):
            return "Missing local model: \(model)"
        }
    }
}
