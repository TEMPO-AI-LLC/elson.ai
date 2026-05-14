import AppKit
import FluidAudio
import Foundation
import Gemma4Swift
import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom

enum LocalProcessingAudioBackend: String, Sendable {
    case fluidAudio
    case groq
}

enum LocalProcessingLLMBackend: String, Sendable {
    case gemma4Swift
    case hostedProviders
}

enum LocalProcessorPaths {
    static var rootDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("LocalProcessor", isDirectory: true)
    }

    static var gemmaModelsDirectory: URL {
        rootDirectory.appendingPathComponent("GemmaModels", isDirectory: true)
    }

    static func configureGemmaCache() {
        Gemma4ModelCache.customModelsDirectory = gemmaModelsDirectory
    }
}

struct LocalProcessorStatus: Equatable, Sendable {
    let fluidAudioReady: Bool
    let gemmaReady: Bool
    let isPreparing: Bool
    let errorMessage: String?

    static let gemmaModel = Gemma4Pipeline.Model.e4b4bit

    var isReady: Bool {
        fluidAudioReady && gemmaReady && errorMessage == nil
    }

    var summary: String {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if isPreparing {
            return "Preparing local processor..."
        }
        if isReady {
            return "Local processor ready."
        }

        var missing: [String] = []
        if !fluidAudioReady { missing.append("FluidAudio") }
        if !gemmaReady { missing.append("Gemma 4") }
        return missing.isEmpty ? "Local processor not checked." : "Download required: \(missing.joined(separator: ", "))."
    }

    var detail: String {
        "\(Self.gemmaModel.displayName), ~\(String(format: "%.1f", Self.gemmaModel.estimatedSizeGB)) GB. FluidAudio v3 multilingual auto."
    }

    static func current(isPreparing: Bool = false, errorMessage: String? = nil) -> LocalProcessorStatus {
        LocalProcessorPaths.configureGemmaCache()
        let asrReady = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
        let gemmaReady = Gemma4ModelCache.isDownloaded(gemmaModel)
        return LocalProcessorStatus(
            fluidAudioReady: asrReady,
            gemmaReady: gemmaReady,
            isPreparing: isPreparing,
            errorMessage: errorMessage
        )
    }
}

actor FluidAudioTranscriber: LocalAudioTranscribing {
    static let shared = FluidAudioTranscriber()

    private let manager = AsrManager(config: .default)
    private var decoderState = TdtDecoderState.make()
    private var isPrepared = false

    func prepare() async throws {
        guard !isPrepared else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        try await manager.loadModels(models)
        decoderState = TdtDecoderState.make()
        isPrepared = true
    }

    func transcribeDetailed(
        audioURL: URL,
        groqAPIKey: String,
        logContext: LocalRequestLogContext?,
        extraMetadata: String
    ) async throws -> LocalTranscriptionResult {
        _ = groqAPIKey
        try await prepare()

        let startedAt = Date()
        DebugLog.providerEvent(
            phase: "start",
            service: "fluid_audio_transcription",
            model: "FluidAudio Parakeet TDT v3",
            metadata: "\(logContext?.metadata ?? "") file=\(audioURL.lastPathComponent) \(extraMetadata)",
            payloadPreview: "language=auto"
        )

        var state = decoderState
        let result = try await manager.transcribe(audioURL, decoderState: &state, language: nil)
        decoderState = TdtDecoderState.make()

        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw LocalAIServiceError.noSpeechDetected
        }

        DebugLog.providerEvent(
            phase: "success",
            service: "fluid_audio_transcription",
            model: "FluidAudio Parakeet TDT v3",
            metadata: "\(logContext?.metadata ?? "") duration_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) transcript_chars=\(transcript.count)",
            payloadPreview: transcript
        )

        return LocalTranscriptionResult(
            text: transcript,
            language: nil,
            duration: result.duration,
            segments: nil
        )
    }
}

@MainActor
final class LocalGemmaService {
    static let shared = LocalGemmaService()

    private var container: ModelContainer?
    private var isPreparing = false

    private init() {}

    func prepare(
        progress: (@Sendable (Gemma4DownloadProgress) -> Void)? = nil
    ) async throws {
        if container != nil { return }
        if isPreparing {
            while isPreparing {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            if container != nil { return }
        }

        isPreparing = true
        defer { isPreparing = false }

        LocalProcessorPaths.configureGemmaCache()
        if !Gemma4ModelCache.isDownloaded(LocalProcessorStatus.gemmaModel) {
            _ = try await Gemma4ModelDownloader.download(
                LocalProcessorStatus.gemmaModel,
                progress: progress
            )
        }

        guard let localPath = Gemma4ModelCache.localPath(for: LocalProcessorStatus.gemmaModel) else {
            throw LocalAIServiceError.invalidResponse("Gemma 4 local model cache")
        }

        await Gemma4Registration.register(multimodal: true)
        container = try await loadModelContainer(from: localPath, using: Gemma4TokenizerLoader())
    }

    func runTranscriptAgent(request envelope: ElsonRequestEnvelope) async throws -> String {
        let fallbackTranscript = (envelope.rawTranscript ?? envelope.enhancedTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackTranscript.isEmpty else { return "" }

        let systemPrompt = ElsonPromptCatalog.transcriptAgentSystemPrompt(
            transcriptAgentPrompt: envelope.transcriptAgentPrompt,
            includeConversationHistory: envelope.surface == "chat"
        )
        let userPrompt = ElsonPromptCatalog.transcriptAgentUserPrompt(
            envelope: envelope,
            attachmentSummary: attachmentSummary(from: envelope.attachments)
        )
        let images = imageInputs(from: envelope.attachments)
        let output: String
        if images.isEmpty {
            output = try await generateText(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.2,
                maxTokens: 700
            )
        } else {
            output = try await generateMultimodalText(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                images: images,
                temperature: 0.2,
                maxTokens: 700
            )
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallbackTranscript
    }

    func runWorkingAgent(request envelope: ElsonRequestEnvelope) async throws -> AgentDecision {
        let systemPrompt = ElsonPromptCatalog.workingAgentSystemPrompt(
            workingAgentPrompt: envelope.workingAgentPrompt,
            includeConversationHistory: envelope.surface == "chat"
        )
        let userPrompt = ElsonPromptCatalog.workingAgentUserPrompt(
            envelope: envelope,
            attachmentSummary: attachmentSummary(from: envelope.attachments)
        )
        let images = imageInputs(from: envelope.attachments)
        let output: String
        if images.isEmpty {
            output = try await generateText(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.1,
                maxTokens: 1200
            )
        } else {
            output = try await generateMultimodalText(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                images: images,
                temperature: 0.1,
                maxTokens: 1200
            )
        }

        guard let jsonData = LocalAIService().extractJSONData(from: output) else {
            throw LocalAIServiceError.invalidResponse("Local Gemma Working Agent")
        }
        return LocalAIService().normalizedAgentDecision(from: jsonData)
    }

    func extractScreenContext(
        images: [LocalImageInput],
        myElsonMarkdown: String,
        logContext: LocalRequestLogContext
    ) async throws -> LocalScreenContext {
        guard !images.isEmpty else { return .none }

        let systemPrompt = ElsonPromptCatalog.screenExtractorSystemPrompt(
            wordsGlossaryMarkdown: MyElsonDocument.wordsGlossaryMarkdown(from: myElsonMarkdown)
        )
        let userPrompt = ElsonPromptCatalog.screenExtractorUserPrompt()
        let output = try await generateMultimodalText(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            images: images,
            temperature: 0.1,
            maxTokens: 500
        )

        guard let jsonData = LocalAIService().extractJSONData(from: output) else {
            throw LocalAIServiceError.invalidResponse("Local Gemma screen extraction")
        }
        let decoded = try JSONDecoder().decode(LocalGemmaScreenExtractionResponse.self, from: jsonData)
        let screenText = decoded.screenText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let screenDescription = decoded.screenDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = LocalScreenContext(
            hasScreenContext: !(screenText?.isEmpty ?? true) || !(screenDescription?.isEmpty ?? true),
            screenText: screenText?.nilIfEmpty,
            screenDescription: screenDescription?.nilIfEmpty
        )

        DebugLog.providerEvent(
            phase: "success",
            service: "local_gemma_screen_extraction",
            model: LocalProcessorStatus.gemmaModel.rawValue,
            metadata: "\(logContext.metadata) images=\(images.count) has_screen_context=\(context.hasScreenContext)",
            payloadPreview: output
        )
        return context
    }

    private func generateText(
        systemPrompt: String,
        userPrompt: String,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        try await prepare()
        guard let container else {
            throw LocalAIServiceError.invalidResponse("Local Gemma model")
        }

        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature, topP: 0.95)
        let session = ChatSession(container, instructions: systemPrompt, generateParameters: parameters)
        return try await session.respond(to: userPrompt)
    }

    private func generateMultimodalText(
        systemPrompt: String,
        userPrompt: String,
        images: [LocalImageInput],
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        try await prepare()
        guard let container else {
            throw LocalAIServiceError.invalidResponse("Local Gemma model")
        }

        let pixelValues = try imagePixelValues(from: images)
        let content = (Array(repeating: "<|image|>", count: images.count) + [userPrompt])
            .joined(separator: "\n")
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": content],
        ]
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

        nonisolated(unsafe) let capturedInputIds = MLXArray(tokenIds.map { Int32($0) })
        nonisolated(unsafe) let capturedPixelValues = pixelValues
        let tokenFilter = Gemma4TokenFilter(mode: .disabled)

        let generated = await container.perform { context in
            if let model = context.model as? Gemma4MultimodalLLMModel {
                model.pendingPixelValues = capturedPixelValues
            }

            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature, topP: 0.95)
            let cache = context.model.newCache(parameters: parameters)
            let prefill = context.model(capturedInputIds.reshaped(1, -1), cache: cache)
            var nextToken = argMax(prefill[0..., prefill.dim(1) - 1, 0...], axis: -1).item(Int32.self)

            var pieces: [String] = []
            var visibleTokens = 0
            let maxTotalTokens = maxTokens * 3
            for _ in 0 ..< maxTotalTokens {
                let text = context.tokenizer.decode(tokenIds: [Int(nextToken)])
                let filtered = tokenFilter.process(tokenId: nextToken, text: text)
                if !filtered.isEmpty {
                    pieces.append(filtered)
                    visibleTokens += 1
                }

                if tokenFilter.isEOS(nextToken) || visibleTokens >= maxTokens {
                    break
                }

                let nextInput = MLXArray([nextToken]).reshaped(1, 1)
                let output = context.model(nextInput, cache: cache)
                if temperature <= 0.01 {
                    nextToken = argMax(output[0..., 0, 0...], axis: -1).item(Int32.self)
                } else {
                    let logits = output[0..., 0, 0...] / temperature
                    let probabilities = softmax(logits, axis: -1)
                    nextToken = MLXRandom.categorical(log(probabilities)).item(Int32.self)
                }
            }
            return pieces.joined()
        }

        return generated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func imagePixelValues(from images: [LocalImageInput]) throws -> MLXArray {
        let allPixelValues = try images.map { image -> MLXArray in
            guard let nsImage = NSImage(data: image.data),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                throw LocalAIServiceError.invalidResponse("Local Gemma image input")
            }
            return try Gemma4ImageProcessor.processImage(cgImage)
        }

        guard allPixelValues.count > 1 else {
            return allPixelValues[0]
        }

        let maxHeight = allPixelValues.map { $0.dim(2) }.max()!
        let maxWidth = allPixelValues.map { $0.dim(3) }.max()!
        let padded = allPixelValues.map { value -> MLXArray in
            let height = value.dim(2)
            let width = value.dim(3)
            guard height != maxHeight || width != maxWidth else { return value }
            let result = MLXArray.zeros([1, 3, maxHeight, maxWidth], dtype: value.dtype)
            result[0..., 0..., 0 ..< height, 0 ..< width] = value
            return result
        }
        return concatenated(padded, axis: 0)
    }

    private func imageInputs(from attachments: [ElsonAttachmentPayload]) -> [LocalImageInput] {
        attachments.compactMap { attachment in
            guard attachment.kind == "image" || attachment.mime.lowercased().hasPrefix("image/") else {
                return nil
            }
            guard let data = decodeDataRef(attachment.dataRef) else {
                return nil
            }
            return LocalImageInput(name: attachment.name, mime: attachment.mime, data: data)
        }
    }

    private func decodeDataRef(_ dataRef: String) -> Data? {
        guard let separator = dataRef.range(of: "base64,") else {
            return nil
        }
        return Data(base64Encoded: String(dataRef[separator.upperBound...]))
    }

    private func attachmentSummary(from attachments: [ElsonAttachmentPayload]) -> String {
        guard !attachments.isEmpty else { return "None" }
        return attachments.map { attachment in
            "\(attachment.kind) | \(attachment.name) | \(attachment.mime) | source=\(attachment.source)"
        }.joined(separator: "\n")
    }
}

enum LocalProcessingRouter {
    static func audioBackend(for config: ElsonLocalConfig) -> LocalProcessingAudioBackend {
        config.runtimeMode == .local ? .fluidAudio : .groq
    }

    static func llmBackend(for config: ElsonLocalConfig) -> LocalProcessingLLMBackend {
        config.runtimeMode == .local ? .gemma4Swift : .hostedProviders
    }

    static func status() -> LocalProcessorStatus {
        LocalProcessorStatus.current()
    }

    static func prepareLocalProcessor() async throws -> LocalProcessorStatus {
        _ = LocalProcessorStatus.current(isPreparing: true)
        try await FluidAudioTranscriber.shared.prepare()
        try await LocalGemmaService.shared.prepare()
        return LocalProcessorStatus.current()
    }

    static func transcribeDetailed(
        audioURL: URL,
        config: ElsonLocalConfig,
        logContext: LocalRequestLogContext?,
        extraMetadata: String = ""
    ) async throws -> LocalTranscriptionResult {
        switch config.runtimeMode {
        case .local:
            return try await FluidAudioTranscriber.shared.transcribeDetailed(
                audioURL: audioURL,
                groqAPIKey: "",
                logContext: logContext,
                extraMetadata: extraMetadata
            )
        case .hosted:
            return try await LocalAIService().transcribeDetailed(
                audioURL: audioURL,
                groqAPIKey: config.groqAPIKey,
                logContext: logContext,
                extraMetadata: extraMetadata
            )
        }
    }

    static func transcribe(
        audioURL: URL,
        config: ElsonLocalConfig,
        logContext: LocalRequestLogContext?,
        extraMetadata: String = ""
    ) async throws -> String {
        try await transcribeDetailed(
            audioURL: audioURL,
            config: config,
            logContext: logContext,
            extraMetadata: extraMetadata
        ).text
    }

    static func runTranscriptAgent(
        request: ElsonRequestEnvelope,
        config: ElsonLocalConfig,
        hostedProvider: LocalModelProvider
    ) async throws -> String {
        switch config.runtimeMode {
        case .local:
            return try await LocalGemmaService.shared.runTranscriptAgent(request: request)
        case .hosted:
            return try await LocalAIService().runTranscriptAgent(
                request: request,
                provider: hostedProvider,
                cerebrasAPIKey: config.cerebrasAPIKey,
                geminiAPIKey: config.geminiAPIKey
            )
        }
    }

    static func runWorkingAgent(
        request: ElsonRequestEnvelope,
        config: ElsonLocalConfig,
        hostedProvider: LocalModelProvider
    ) async throws -> AgentDecision {
        switch config.runtimeMode {
        case .local:
            return try await LocalGemmaService.shared.runWorkingAgent(request: request)
        case .hosted:
            return try await LocalAIService().runWorkingAgent(
                request: request,
                provider: hostedProvider,
                cerebrasAPIKey: config.cerebrasAPIKey,
                geminiAPIKey: config.geminiAPIKey
            )
        }
    }

    static func extractScreenContext(
        images: [LocalImageInput],
        config: ElsonLocalConfig,
        myElsonMarkdown: String,
        logContext: LocalRequestLogContext
    ) async throws -> LocalScreenContext {
        switch config.runtimeMode {
        case .local:
            return try await LocalGemmaService.shared.extractScreenContext(
                images: images,
                myElsonMarkdown: myElsonMarkdown,
                logContext: logContext
            )
        case .hosted:
            return try await LocalAIService().extractScreenContext(
                images: images,
                groqAPIKey: config.groqAPIKey,
                myElsonMarkdown: myElsonMarkdown,
                logContext: logContext
            )
        }
    }
}

private struct LocalGemmaScreenExtractionResponse: Decodable {
    let screenText: String?
    let screenDescription: String?

    enum CodingKeys: String, CodingKey {
        case screenText = "screen_text"
        case screenDescription = "screen_description"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
