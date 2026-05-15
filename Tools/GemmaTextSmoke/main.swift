import Foundation
import Gemma4Swift
import MLX
import MLXLLM
import MLXLMCommon

@main
enum GemmaTextSmoke {
    static func main() async throws {
        let startedAt = Date()
        let defaultModelID = Gemma4Pipeline.Model.e4b4bit.rawValue
        let modelID = CommandLine.arguments.dropFirst().first ?? defaultModelID
        let modelCache = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("LocalProcessor", isDirectory: true)
            .appendingPathComponent("LLMModels", isDirectory: true)
        Gemma4ModelCache.customModelsDirectory = modelCache

        print("smoke model=\(modelID)")
        print("smoke cache=\(modelCache.path)")

        if !Gemma4ModelCache.isDownloaded(modelId: modelID) {
            print("smoke download=missing; downloading")
            _ = try await Gemma4ModelDownloader.download(modelId: modelID) { progress in
                let percent = Int((progress.bytesFraction * 100).rounded())
                print("smoke download progress=\(percent)% file=\(progress.currentFile)")
            }
        }

        let modelPath = modelID.split(separator: "/").reduce(modelCache) { partial, part in
            partial.appendingPathComponent(String(part), isDirectory: true)
        }
        guard FileManager.default.fileExists(atPath: modelPath.appendingPathComponent("config.json").path) else {
            throw SmokeError.missingModel(modelID)
        }

        print("smoke path=\(modelPath.path)")
        if modelID.contains("gemma-4") {
            print("smoke register=gemma-text-only")
            await Gemma4Registration.register(multimodal: false)
        } else {
            print("smoke register=mlx-llm-default")
        }

        let loadStartedAt = Date()
        print("smoke load=start")
        let container = try await loadModelContainer(from: modelPath, using: Gemma4TokenizerLoader())
        print("smoke load=ok seconds=\(String(format: "%.2f", Date().timeIntervalSince(loadStartedAt)))")

        let prompts = [
            "Reply with exactly five words about local AI.",
            "Translate to German: The local model is ready.",
            "Return JSON only: {\"status\":\"ok\",\"backend\":\"gemma\"}"
        ]

        for (index, prompt) in prompts.enumerated() {
            let generationStartedAt = Date()
            let params = GenerateParameters(maxTokens: 64, temperature: 0.0, topP: 0.95)
            let session = ChatSession(
                container,
                instructions: "You are a concise assistant. Follow the user instruction exactly.",
                generateParameters: params
            )
            let response = try await session.respond(to: prompt)
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(generationStartedAt))
            print("smoke generation=\(index + 1) ok seconds=\(elapsed)")
            print("smoke response=\(response.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        print("smoke done seconds=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))")
    }
}

private enum SmokeError: LocalizedError {
    case missingModel(String)

    var errorDescription: String? {
        switch self {
        case .missingModel(let model):
            return "Missing local model: \(model)"
        }
    }
}
