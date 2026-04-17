import Foundation

struct LocalImageInput: Sendable {
    let name: String
    let mime: String
    let data: Data
}

struct LocalScreenContext: Codable, Hashable, Sendable {
    let hasScreenContext: Bool
    let screenText: String?
    let screenDescription: String?

    static let none = LocalScreenContext(
        hasScreenContext: false,
        screenText: nil,
        screenDescription: nil
    )
}

struct LocalFormattingRequest: Sendable {
    struct AttachmentContext: Sendable {
        let kind: String
        let name: String
        let mime: String
        let source: String
    }

    let rawTranscript: String?
    let enhancedTranscript: String
    let transcriptSnippetCount: Int?
    let requestId: String
    let threadId: String
    let mode: String
    let surface: String
    let inputSource: String
    let transcriptAgentPrompt: String
    let clipboardText: String?
    let conversationHistory: [ElsonConversationTurnPayload]
    let attachments: [AttachmentContext]
    let screenContext: LocalScreenContext
    let extraContextMarkdown: String

    var attachmentSummaryText: String {
        guard !attachments.isEmpty else { return "None" }
        return attachments.map { attachment in
            "\(attachment.kind) | \(attachment.name) | \(attachment.mime) | source=\(attachment.source)"
        }.joined(separator: "\n")
    }
}

struct LocalRequestLogContext: Sendable {
    let requestId: String
    let threadId: String
    let surface: String
    let inputSource: String

    var metadata: String {
        "request_id=\(requestId) thread_id=\(threadId) surface=\(surface) input_source=\(inputSource)"
    }
}

struct WordsCorrectionResult: Hashable, Sendable {
    let patch: MyElsonPatch?
    let reason: String
}

enum PromptLearningDecision: String, Hashable, Sendable {
    case noLearning = "no_learning"
    case updateTranscriptPrompt = "update_transcript_prompt"
    case updateWorkingAgentPrompt = "update_working_agent_prompt"
}

struct PromptLearningResult: Hashable, Sendable {
    let decision: PromptLearningDecision
    let updatedPrompt: String?
    let reason: String
}

struct LocalAIService: Sendable {
    private let session: URLSession = .shared

    func validateGroqAPIKey(_ groqAPIKey: String) async throws {
        let sanitized = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            throw LocalAIServiceError.missingGroqKey
        }

        let model = ModelConfig.shared.localRuntime.groq.validation.model
        try await validateChatCompletionAPIKey(
            apiKey: sanitized,
            url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            model: model,
            service: "Groq key validation"
        )
    }

    func validateCerebrasAPIKey(_ cerebrasAPIKey: String) async throws {
        let sanitized = cerebrasAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            throw LocalAIServiceError.missingCerebrasKey
        }

        let model = ModelConfig.shared.localRuntime.cerebras.validation.model
        try await validateChatCompletionAPIKey(
            apiKey: sanitized,
            url: URL(string: "https://api.cerebras.ai/v1/chat/completions")!,
            model: model,
            service: "Cerebras key validation"
        )
    }

    func validateGeminiAPIKey(_ geminiAPIKey: String) async throws {
        let sanitized = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            throw LocalAIServiceError.missingGeminiKey
        }

        let stage = ModelConfig.shared.localRuntime.google.validation
        let systemPrompt = "Reply with exactly OK."
        let userPrompt = "Respond with OK."
        let requestBody = makeGeminiGenerateContentBody(
            systemPrompt: systemPrompt,
            history: [],
            currentUserPrompt: userPrompt,
            images: [],
            responseSchema: nil,
            stage: stage
        )

        let startedAt = Date()
        let serviceSlug = "gemini_key_validation"
        DebugLog.providerEvent(
            phase: "start",
            service: serviceSlug,
            model: stage.model,
            metadata: "purpose=api_key_validation",
            payloadPreview: """
            system:
            \(systemPrompt)

            user:
            \(userPrompt)
            """
        )

        let (data, response) = try await performGeminiRequest(
            apiKey: sanitized,
            requestBody: requestBody,
            model: stage.model,
            service: "Gemini key validation"
        )
        let rawBody = rawBodyText(from: data)
        do {
            try validate(response: response, data: data, service: "Gemini key validation")
        } catch {
            DebugLog.providerFailure(
                service: serviceSlug,
                model: stage.model,
                metadata: "duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                error: error.localizedDescription,
                payloadPreview: rawBody
            )
            throw error
        }

        let extracted = try extractedResponseText(from: data, service: "Gemini key validation")
        DebugLog.providerEvent(
            phase: "success",
            service: serviceSlug,
            model: stage.model,
            metadata: "duration_ms=\(durationMS(since: startedAt)) purpose=api_key_validation reply_chars=\(extracted.text.count)",
            payloadPreview: extracted.text
        )
    }

    func transcribe(
        audioURL: URL,
        groqAPIKey: String,
        logContext: LocalRequestLogContext? = nil,
        extraMetadata: String = ""
    ) async throws -> String {
        guard !groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.missingGroqKey
        }

        let model = ModelConfig.shared.localRuntime.groq.transcription.model
        let startedAt = Date()

        let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(groqAPIKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        var body = Data()
        body.appendFormField(named: "model", value: model, boundary: boundary)
        body.appendFormField(named: "temperature", value: "0", boundary: boundary)
        body.appendFormField(named: "response_format", value: "verbose_json", boundary: boundary)
        body.appendFileField(named: "file", filename: audioURL.lastPathComponent, mimeType: "audio/m4a", data: audioData, boundary: boundary)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        DebugLog.providerEvent(
            phase: "start",
            service: "groq_transcription",
            model: model,
            metadata: joinedMetadata(
                logContext?.metadata,
                "file=\(audioURL.lastPathComponent) bytes=\(audioData.count)",
                extraMetadata
            ),
            payloadPreview: "response_format=verbose_json temperature=0"
        )

        do {
            let (data, response) = try await session.data(for: request)
            do {
                try validate(response: response, data: data, service: "Groq transcription")
            } catch {
                DebugLog.providerFailure(
                    service: "groq_transcription",
                    model: model,
                    metadata: joinedMetadata(
                        logContext?.metadata,
                        "duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                        extraMetadata
                    ),
                    error: error.localizedDescription,
                    payloadPreview: String(data: data, encoding: .utf8)
                )
                throw error
            }

            let payload = try JSONDecoder().decode(GroqTranscriptionPayload.self, from: data)
            let sanitized = GroqTranscriptionSanitizer.sanitize(payload)
            let transcript = sanitized.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let removedTrailingText = sanitized.removedTrailingText, let reason = sanitized.reason {
                DebugLog.runtime(
                    "groq_transcription_sanitized request_id=\(logContext?.requestId ?? "none") thread_id=\(logContext?.threadId ?? "none") reason=\(reason) removed_text=\(shortPreview(removedTrailingText))"
                )
            }
            DebugLog.providerEvent(
                phase: "success",
                service: "groq_transcription",
                model: model,
                metadata: joinedMetadata(
                    logContext?.metadata,
                    "duration_ms=\(durationMS(since: startedAt)) transcript_chars=\(transcript.count) transcript_preview=\(shortPreview(transcript)) language=\(payload.language ?? "none") segment_count=\(payload.segments?.count ?? 0)",
                    extraMetadata
                ),
                payloadPreview: transcript
            )
            return transcript
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "groq_transcription",
                model: model,
                metadata: joinedMetadata(
                    logContext?.metadata,
                    "duration_ms=\(durationMS(since: startedAt))",
                    extraMetadata
                ),
                error: error.localizedDescription
            )
            throw error
        }
    }

    func extractScreenContext(
        images: [LocalImageInput],
        groqAPIKey: String,
        myElsonMarkdown: String,
        logContext: LocalRequestLogContext
    ) async throws -> LocalScreenContext {
        guard !images.isEmpty else {
            return .none
        }
        guard !groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.missingGroqKey
        }

        let stage = ModelConfig.shared.localRuntime.groq.ocr
        let model = stage.model
        let startedAt = Date()

        let systemPrompt = ElsonPromptCatalog.screenExtractorSystemPrompt(
            wordsGlossaryMarkdown: MyElsonDocument.wordsGlossaryMarkdown(from: myElsonMarkdown)
        )
        let userPrompt = ElsonPromptCatalog.screenExtractorUserPrompt()

        var userContent: [[String: Any]] = [
            [
                "type": "text",
                "text": userPrompt
            ]
        ]

        userContent.append(contentsOf: images.map { image in
            let dataURL = "data:\(image.mime);base64,\(image.data.base64EncodedString())"
            return [
                "type": "image_url",
                "image_url": [
                    "url": dataURL
                ]
            ]
        })

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
            "temperature": stage.temperature ?? 0.1,
            "top_p": stage.topP ?? 1,
            "stream": false,
            "response_format": [
                "type": "json_object"
            ],
        ]

        let url = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(groqAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let requestPreview = """
        system:
        \(systemPrompt)

        user:
        \(userPrompt)
        images: \(images.map(\.name).joined(separator: ", "))
        """
        DebugLog.providerEvent(
            phase: "start",
            service: "groq_screen_extraction",
            model: model,
            metadata: "\(logContext.metadata) images=\(images.count)",
            payloadPreview: requestPreview
        )

        do {
            let (data, response) = try await session.data(for: request)
            let rawBody = rawBodyText(from: data)
            do {
                try validate(response: response, data: data, service: "Groq screen extraction")
            } catch {
                DebugLog.providerFailure(
                    service: "groq_screen_extraction",
                    model: model,
                    metadata: "\(logContext.metadata) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                    error: error.localizedDescription,
                    payloadPreview: rawBody
                )
                throw error
            }
            DebugLog.providerEvent(
                phase: "http_response",
                service: "groq_screen_extraction",
                model: model,
                metadata: "\(logContext.metadata) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                payloadPreview: rawBody
            )

            let extracted = try extractedResponseText(from: data, service: "Groq screen extraction")
            DebugLog.providerEvent(
                phase: "parse_extracted",
                service: "groq_screen_extraction",
                model: model,
                metadata: "\(logContext.metadata) duration_ms=\(durationMS(since: startedAt)) source=\(extracted.source)",
                payloadPreview: extracted.text
            )
            guard let jsonData = extractJSONData(from: extracted.text) else {
                let error = LocalAIServiceError.invalidResponse("Groq screen extraction")
                DebugLog.providerFailure(
                    service: "groq_screen_extraction",
                    model: model,
                    metadata: "\(logContext.metadata) duration_ms=\(durationMS(since: startedAt)) step=extract_json source=\(extracted.source)",
                    error: error.localizedDescription,
                    payloadPreview: extracted.text
                )
                throw error
            }

            let screenResponse = try JSONDecoder().decode(LocalScreenExtractionResponse.self, from: jsonData)
            let screenText = screenResponse.screenText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let screenDescription = screenResponse.screenDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasScreenContext = !(screenText?.isEmpty ?? true) || !(screenDescription?.isEmpty ?? true)
            let context = LocalScreenContext(
                hasScreenContext: hasScreenContext,
                screenText: screenText?.nilIfEmpty,
                screenDescription: screenDescription?.nilIfEmpty
            )
            DebugLog.providerEvent(
                phase: "success",
                service: "groq_screen_extraction",
                model: model,
                metadata: "\(logContext.metadata) duration_ms=\(durationMS(since: startedAt)) has_screen_context=\(context.hasScreenContext) screen_text_preview=\(shortPreview(context.screenText)) screen_description_preview=\(shortPreview(context.screenDescription))",
                payloadPreview: extracted.text
            )
            return context
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "groq_screen_extraction",
                model: model,
                metadata: "duration_ms=\(durationMS(since: startedAt))",
                error: error.localizedDescription
            )
            throw error
        }
    }

    func runTranscriptAgent(
        request envelope: ElsonRequestEnvelope,
        provider: LocalModelProvider,
        cerebrasAPIKey: String,
        geminiAPIKey: String
    ) async throws -> String {
        switch provider {
        case .google:
            return try await runGeminiTranscriptAgent(
                request: envelope,
                geminiAPIKey: geminiAPIKey
            )
        case .cerebras:
            return try await runCerebrasTranscriptAgent(
                request: envelope,
                cerebrasAPIKey: cerebrasAPIKey
            )
        }
    }

    private func runCerebrasTranscriptAgent(
        request envelope: ElsonRequestEnvelope,
        cerebrasAPIKey: String
    ) async throws -> String {
        guard !cerebrasAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.missingCerebrasKey
        }

        let fallbackTranscript = (envelope.rawTranscript ?? envelope.enhancedTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackTranscript.isEmpty else { return "" }

        let stage = ModelConfig.shared.localRuntime.cerebras.transcriptAgent
        let model = stage.model
        let startedAt = Date()
        let attachmentSummary = attachmentSummary(from: envelope.attachments)
        let systemPrompt = ElsonPromptCatalog.transcriptAgentSystemPrompt(
            transcriptAgentPrompt: envelope.transcriptAgentPrompt,
            includeConversationHistory: envelope.surface == "chat"
        )
        let userPrompt = ElsonPromptCatalog.transcriptAgentUserPrompt(
            envelope: envelope,
            attachmentSummary: attachmentSummary
        )

        let url = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(cerebrasAPIKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messages = ElsonPromptCatalog.cerebrasMessages(
            systemPrompt: systemPrompt,
            includeConversationHistory: envelope.surface == "chat",
            history: envelope.conversationHistory,
            currentUserPrompt: userPrompt
        )
        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": stage.temperature ?? 0.2,
        ]
        if let topP = stage.topP {
            payload["top_p"] = topP
        }
        if let thinkingLevel = stage.thinkingLevel, !thinkingLevel.isEmpty {
            payload["reasoning_effort"] = thinkingLevel
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let requestPreview = prettyJSONString(from: messages) ?? """
        system:
        \(systemPrompt)

        user:
        \(userPrompt)
        """
        DebugLog.providerEvent(
            phase: "start",
            service: "cerebras_transcript_agent",
            model: model,
            metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) raw_chars=\(fallbackTranscript.count) has_screen_context=\(envelope.screenContext.hasScreenContext)",
            payloadPreview: requestPreview
        )

        do {
            let (data, response) = try await session.data(for: urlRequest)
            let rawBody = rawBodyText(from: data)
            do {
                try validate(response: response, data: data, service: "Cerebras Transcript Agent")
            } catch {
                DebugLog.providerFailure(
                    service: "cerebras_transcript_agent",
                    model: model,
                    metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                    error: error.localizedDescription,
                    payloadPreview: rawBody
                )
                throw error
            }

            let extracted = try extractedResponseText(from: data, service: "Cerebras Transcript Agent")
            let formatted = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallbackTranscript
            DebugLog.providerEvent(
                phase: "success",
                service: "cerebras_transcript_agent",
                model: model,
                metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) output_chars=\(formatted.count) output_preview=\(shortPreview(formatted))",
                payloadPreview: formatted
            )
            return formatted
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "cerebras_transcript_agent",
                model: model,
                metadata: "provider=cerebras duration_ms=\(durationMS(since: startedAt))",
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func runGeminiTranscriptAgent(
        request envelope: ElsonRequestEnvelope,
        geminiAPIKey: String
    ) async throws -> String {
        guard !geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.missingGeminiKey
        }

        let fallbackTranscript = (envelope.rawTranscript ?? envelope.enhancedTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackTranscript.isEmpty else { return "" }

        let stage = ModelConfig.shared.localRuntime.google.transcriptAgent
        let model = stage.model
        let startedAt = Date()
        let attachmentSummary = attachmentSummary(from: envelope.attachments)
        let systemPrompt = ElsonPromptCatalog.transcriptAgentSystemPrompt(
            transcriptAgentPrompt: envelope.transcriptAgentPrompt,
            includeConversationHistory: envelope.surface == "chat"
        )
        let userPrompt = ElsonPromptCatalog.transcriptAgentUserPrompt(
            envelope: envelope,
            attachmentSummary: attachmentSummary
        )
        let images = imageInputs(from: envelope.attachments)
        let requestBody = makeGeminiGenerateContentBody(
            systemPrompt: systemPrompt,
            history: envelope.surface == "chat" ? envelope.conversationHistory : [],
            currentUserPrompt: userPrompt,
            images: images,
            responseSchema: nil,
            stage: stage
        )

        DebugLog.providerEvent(
            phase: "start",
            service: "gemini_transcript_agent",
            model: model,
            metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) raw_chars=\(fallbackTranscript.count) has_screen_context=\(envelope.screenContext.hasScreenContext) images=\(images.count)",
            payloadPreview: """
            system:
            \(systemPrompt)

            history_messages: \(envelope.surface == "chat" ? envelope.conversationHistory.count : 0)
            images: \(images.map(\.name).joined(separator: ", ").nilIfEmpty ?? "None")

            user:
            \(userPrompt)
            """
        )

        do {
            let (data, response) = try await performGeminiRequest(
                apiKey: geminiAPIKey,
                requestBody: requestBody,
                model: model,
                service: "Gemini Transcript Agent"
            )
            let rawBody = rawBodyText(from: data)
            do {
                try validate(response: response, data: data, service: "Gemini Transcript Agent")
            } catch {
                DebugLog.providerFailure(
                    service: "gemini_transcript_agent",
                    model: model,
                    metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                    error: error.localizedDescription,
                    payloadPreview: rawBody
                )
                throw error
            }

            let extracted = try extractedResponseText(from: data, service: "Gemini Transcript Agent")
            let formatted = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallbackTranscript
            DebugLog.providerEvent(
                phase: "success",
                service: "gemini_transcript_agent",
                model: model,
                metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) output_chars=\(formatted.count) output_preview=\(shortPreview(formatted))",
                payloadPreview: formatted
            )
            return formatted
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "gemini_transcript_agent",
                model: model,
                metadata: "provider=google duration_ms=\(durationMS(since: startedAt))",
                error: error.localizedDescription
            )
            throw error
        }
    }

    func format(
        request: LocalFormattingRequest,
        cerebrasAPIKey: String
    ) async throws -> String {
        guard !cerebrasAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.missingCerebrasKey
        }

        let model = ModelConfig.shared.config.cerebras.enhancement
        let startedAt = Date()

        let systemPrompt = ElsonPromptCatalog.localFormattingSystemPrompt(
            transcriptAgentPrompt: request.transcriptAgentPrompt,
            mode: request.mode,
            extraContextMarkdown: request.extraContextMarkdown,
            includeConversationHistory: request.surface == "chat"
        )
        let userPrompt = ElsonPromptCatalog.localFormattingUserPrompt(request: request)

        let url = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(cerebrasAPIKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messages = ElsonPromptCatalog.cerebrasMessages(
            systemPrompt: systemPrompt,
            includeConversationHistory: request.surface == "chat",
            history: request.conversationHistory,
            currentUserPrompt: userPrompt
        )
        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.2,
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let requestPreview = prettyJSONString(from: messages) ?? """
        system:
        \(systemPrompt)

        user:
        \(userPrompt)
        """
        DebugLog.providerEvent(
            phase: "start",
            service: "cerebras_local_synthesis",
            model: model,
            metadata: "request_id=\(request.requestId) thread_id=\(request.threadId) surface=\(request.surface) input_source=\(request.inputSource) mode=\(request.mode) transcript_chars=\(request.enhancedTranscript.count) has_screen_context=\(request.screenContext.hasScreenContext)",
            payloadPreview: requestPreview
        )

        do {
            let (data, response) = try await session.data(for: urlRequest)
            let rawBody = rawBodyText(from: data)
            do {
                try validate(response: response, data: data, service: "Cerebras local synthesis")
            } catch {
                DebugLog.providerFailure(
                    service: "cerebras_local_synthesis",
                    model: model,
                    metadata: "request_id=\(request.requestId) thread_id=\(request.threadId) surface=\(request.surface) input_source=\(request.inputSource) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                    error: error.localizedDescription,
                    payloadPreview: rawBody
                )
                throw error
            }
            DebugLog.providerEvent(
                phase: "http_response",
                service: "cerebras_local_synthesis",
                model: model,
                metadata: "request_id=\(request.requestId) thread_id=\(request.threadId) surface=\(request.surface) input_source=\(request.inputSource) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                payloadPreview: rawBody
            )

            let extracted = try extractedResponseText(from: data, service: "Cerebras local synthesis")
            DebugLog.providerEvent(
                phase: "parse_extracted",
                service: "cerebras_local_synthesis",
                model: model,
                metadata: "request_id=\(request.requestId) thread_id=\(request.threadId) surface=\(request.surface) input_source=\(request.inputSource) duration_ms=\(durationMS(since: startedAt)) source=\(extracted.source)",
                payloadPreview: extracted.text
            )
            let formatted = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? request.enhancedTranscript
            DebugLog.providerEvent(
                phase: "success",
                service: "cerebras_local_synthesis",
                model: model,
                metadata: "request_id=\(request.requestId) thread_id=\(request.threadId) surface=\(request.surface) input_source=\(request.inputSource) duration_ms=\(durationMS(since: startedAt)) output_chars=\(formatted.count) output_preview=\(shortPreview(formatted))",
                payloadPreview: formatted
            )
            return formatted
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "cerebras_local_synthesis",
                model: model,
                metadata: "duration_ms=\(durationMS(since: startedAt))",
                error: error.localizedDescription
            )
            throw error
        }
    }

    func generateHistorySummaryTitle(
        text: String,
        rawTranscript: String?,
        source: String,
        replyMode: String?,
        provider: LocalModelProvider,
        cerebrasAPIKey: String,
        geminiAPIKey: String
    ) async throws -> String {
        switch provider {
        case .google:
            return try await runGeminiHistorySummaryTitle(
                text: text,
                rawTranscript: rawTranscript,
                source: source,
                replyMode: replyMode,
                geminiAPIKey: geminiAPIKey
            )
        case .cerebras:
            return try await runCerebrasHistorySummaryTitle(
                text: text,
                rawTranscript: rawTranscript,
                source: source,
                replyMode: replyMode,
                cerebrasAPIKey: cerebrasAPIKey
            )
        }
    }

    func runWorkingAgent(
        request envelope: ElsonRequestEnvelope,
        provider: LocalModelProvider,
        cerebrasAPIKey: String,
        geminiAPIKey: String
    ) async throws -> AgentDecision {
        switch provider {
        case .google:
            return try await runGeminiWorkingAgent(
                request: envelope,
                geminiAPIKey: geminiAPIKey
            )
        case .cerebras:
            return try await runCerebrasWorkingAgent(
                request: envelope,
                cerebrasAPIKey: cerebrasAPIKey
            )
        }
    }

    func runPromptLearning(
        feedbackEntry: FeedbackEntry,
        subject: FeedbackSubject,
        transcriptPrompt: String,
        workingAgentPrompt: String,
        geminiAPIKey: String
    ) async throws -> PromptLearningResult {
        let sanitizedKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedKey.isEmpty else {
            throw LocalAIServiceError.missingGeminiKey
        }

        let model = "gemini-3.1-pro-preview"
        let startedAt = Date()
        let systemPrompt = ElsonPromptCatalog.promptLearningSystemPrompt()
        let userPrompt = ElsonPromptCatalog.promptLearningUserPrompt(
            feedbackEntry: feedbackEntry,
            subject: subject,
            transcriptPrompt: transcriptPrompt,
            workingAgentPrompt: workingAgentPrompt
        )
        let requestBody: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": userPrompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.1,
                "responseMimeType": "application/json",
                "responseJsonSchema": promptLearningResponseSchema()
            ]
        ]

        DebugLog.providerEvent(
            phase: "start",
            service: "gemini_prompt_learning",
            model: model,
            metadata: "provider=google request_id=\(feedbackEntry.requestId) actual_route=\(feedbackEntry.actualRoute) reply_mode=\(feedbackEntry.replyMode)",
            payloadPreview: userPrompt
        )

        do {
            let (data, response) = try await performGeminiRequest(
                apiKey: sanitizedKey,
                requestBody: requestBody,
                model: model,
                service: "Gemini Prompt Learning"
            )
            let rawBody = rawBodyText(from: data)
            do {
                try validate(response: response, data: data, service: "Gemini Prompt Learning")
            } catch {
                DebugLog.providerFailure(
                    service: "gemini_prompt_learning",
                    model: model,
                    metadata: "provider=google request_id=\(feedbackEntry.requestId) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                    error: error.localizedDescription,
                    payloadPreview: rawBody
                )
                throw error
            }

            let extracted = try extractedResponseText(from: data, service: "Gemini Prompt Learning")
            guard let jsonData = extractJSONData(from: extracted.text) else {
                let error = LocalAIServiceError.invalidResponse("Gemini Prompt Learning")
                DebugLog.providerFailure(
                    service: "gemini_prompt_learning",
                    model: model,
                    metadata: "provider=google request_id=\(feedbackEntry.requestId) duration_ms=\(durationMS(since: startedAt)) step=extract_json source=\(extracted.source)",
                    error: error.localizedDescription,
                    payloadPreview: extracted.text
                )
                throw error
            }

            let result = normalizedPromptLearningResult(from: jsonData)
            DebugLog.providerEvent(
                phase: "success",
                service: "gemini_prompt_learning",
                model: model,
                metadata: "provider=google request_id=\(feedbackEntry.requestId) duration_ms=\(durationMS(since: startedAt)) decision=\(result.decision.rawValue) updated_prompt_chars=\(result.updatedPrompt?.count ?? 0) reason=\(result.reason)",
                payloadPreview: extracted.text
            )
            return result
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "gemini_prompt_learning",
                model: model,
                metadata: "provider=google request_id=\(feedbackEntry.requestId) duration_ms=\(durationMS(since: startedAt))",
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func runCerebrasHistorySummaryTitle(
        text: String,
        rawTranscript: String?,
        source: String,
        replyMode: String?,
        cerebrasAPIKey: String
    ) async throws -> String {
        guard !cerebrasAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.missingCerebrasKey
        }

        let stage = ModelConfig.shared.localRuntime.cerebras.validation
        let model = stage.model
        let startedAt = Date()
        let systemPrompt = ElsonPromptCatalog.historySummarySystemPrompt()
        let userPrompt = ElsonPromptCatalog.historySummaryUserPrompt(
            text: text,
            rawTranscript: rawTranscript,
            source: source,
            replyMode: replyMode
        )
        let url = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(cerebrasAPIKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messages = ElsonPromptCatalog.cerebrasMessages(
            systemPrompt: systemPrompt,
            includeConversationHistory: false,
            history: [],
            currentUserPrompt: userPrompt
        )
        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0,
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        DebugLog.providerEvent(
            phase: "start",
            service: "cerebras_history_summary",
            model: model,
            metadata: "provider=cerebras source=\(source) reply_mode=\(replyMode ?? "none")",
            payloadPreview: userPrompt
        )

        do {
            let (data, response) = try await session.data(for: urlRequest)
            let rawBody = rawBodyText(from: data)
            do {
                try validate(response: response, data: data, service: "Cerebras History Summary")
            } catch {
                DebugLog.providerFailure(
                    service: "cerebras_history_summary",
                    model: model,
                    metadata: "provider=cerebras duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                    error: error.localizedDescription,
                    payloadPreview: rawBody
                )
                throw error
            }

            let extracted = try extractedResponseText(from: data, service: "Cerebras History Summary")
            let summary = normalizedHistorySummaryTitle(extracted.text, fallbackSource: source)
            DebugLog.providerEvent(
                phase: "success",
                service: "cerebras_history_summary",
                model: model,
                metadata: "provider=cerebras duration_ms=\(durationMS(since: startedAt)) output=\(summary)",
                payloadPreview: extracted.text
            )
            return summary
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "cerebras_history_summary",
                model: model,
                metadata: "provider=cerebras duration_ms=\(durationMS(since: startedAt))",
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func runGeminiHistorySummaryTitle(
        text: String,
        rawTranscript: String?,
        source: String,
        replyMode: String?,
        geminiAPIKey: String
    ) async throws -> String {
        guard !geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.missingGeminiKey
        }

        let stage = ModelConfig.shared.localRuntime.google.validation
        let model = stage.model
        let startedAt = Date()
        let systemPrompt = ElsonPromptCatalog.historySummarySystemPrompt()
        let userPrompt = ElsonPromptCatalog.historySummaryUserPrompt(
            text: text,
            rawTranscript: rawTranscript,
            source: source,
            replyMode: replyMode
        )
        let requestBody = makeGeminiGenerateContentBody(
            systemPrompt: systemPrompt,
            history: [],
            currentUserPrompt: userPrompt,
            images: [],
            responseSchema: nil,
            stage: stage
        )

        DebugLog.providerEvent(
            phase: "start",
            service: "gemini_history_summary",
            model: model,
            metadata: "provider=google source=\(source) reply_mode=\(replyMode ?? "none")",
            payloadPreview: userPrompt
        )

        do {
            let (data, response) = try await performGeminiRequest(
                apiKey: geminiAPIKey,
                requestBody: requestBody,
                model: model,
                service: "Gemini History Summary"
            )
            let rawBody = rawBodyText(from: data)
            do {
                try validate(response: response, data: data, service: "Gemini History Summary")
            } catch {
                DebugLog.providerFailure(
                    service: "gemini_history_summary",
                    model: model,
                    metadata: "provider=google duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                    error: error.localizedDescription,
                    payloadPreview: rawBody
                )
                throw error
            }

            let extracted = try extractedResponseText(from: data, service: "Gemini History Summary")
            let summary = normalizedHistorySummaryTitle(extracted.text, fallbackSource: source)
            DebugLog.providerEvent(
                phase: "success",
                service: "gemini_history_summary",
                model: model,
                metadata: "provider=google duration_ms=\(durationMS(since: startedAt)) output=\(summary)",
                payloadPreview: extracted.text
            )
            return summary
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "gemini_history_summary",
                model: model,
                metadata: "provider=google duration_ms=\(durationMS(since: startedAt))",
                error: error.localizedDescription
            )
            throw error
        }
    }

    func runWorkingAgent(
        request envelope: ElsonRequestEnvelope,
        cerebrasAPIKey: String
    ) async throws -> AgentDecision {
        try await runWorkingAgent(
            request: envelope,
            provider: .cerebras,
            cerebrasAPIKey: cerebrasAPIKey,
            geminiAPIKey: ""
        )
    }

    func runWordsCorrection(
        seed: PostResponseCorrectionSeed,
        provider: LocalModelProvider,
        cerebrasAPIKey: String,
        geminiAPIKey: String
    ) async throws -> WordsCorrectionResult {
        switch provider {
        case .google:
            return try await runGeminiWordsCorrection(
                seed: seed,
                geminiAPIKey: geminiAPIKey
            )
        case .cerebras:
            return try await runCerebrasWordsCorrection(
                seed: seed,
                cerebrasAPIKey: cerebrasAPIKey
            )
        }
    }

    private func runCerebrasWordsCorrection(
        seed: PostResponseCorrectionSeed,
        cerebrasAPIKey: String
    ) async throws -> WordsCorrectionResult {
        guard !cerebrasAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.missingCerebrasKey
        }

        let envelope = seed.request
        let stage = ModelConfig.shared.localRuntime.cerebras.workingAgent
        let model = stage.model
        let startedAt = Date()
        let attachmentSummary = attachmentSummary(from: envelope.attachments)
        let systemPrompt = ElsonPromptCatalog.wordsCorrectionSystemPrompt(
            workingAgentPrompt: envelope.workingAgentPrompt,
            includeConversationHistory: envelope.surface == "chat"
        )
        let userPrompt = ElsonPromptCatalog.wordsCorrectionUserPrompt(
            envelope: envelope,
            assistantReplyText: seed.assistantReplyText,
            attachmentSummary: attachmentSummary
        )

        let url = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(cerebrasAPIKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messages = ElsonPromptCatalog.cerebrasMessages(
            systemPrompt: systemPrompt,
            includeConversationHistory: envelope.surface == "chat",
            history: envelope.conversationHistory,
            currentUserPrompt: userPrompt
        )
        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": stage.temperature ?? 0.1,
            "response_format": [
                "type": "json_object"
            ],
        ]
        if let topP = stage.topP {
            payload["top_p"] = topP
        }
        if let thinkingLevel = stage.thinkingLevel, !thinkingLevel.isEmpty {
            payload["reasoning_effort"] = thinkingLevel
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        DebugLog.providerEvent(
            phase: "start",
            service: "cerebras_words_correction",
            model: model,
            metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) attachments=\(envelope.attachments.count)",
            payloadPreview: """
            system:
            \(systemPrompt)

            user:
            \(userPrompt)
            """
        )

        do {
            let (data, response) = try await session.data(for: urlRequest)
            let rawBody = rawBodyText(from: data)
            do {
                try validate(response: response, data: data, service: "Words Correction")
            } catch {
                DebugLog.providerFailure(
                    service: "cerebras_words_correction",
                    model: model,
                    metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                    error: error.localizedDescription,
                    payloadPreview: rawBody
                )
                throw error
            }

            let extracted = try extractedResponseText(from: data, service: "Words Correction")
            guard let jsonData = extractJSONData(from: extracted.text) else {
                let error = LocalAIServiceError.invalidResponse("Words Correction")
                DebugLog.providerFailure(
                    service: "cerebras_words_correction",
                    model: model,
                    metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) duration_ms=\(durationMS(since: startedAt)) step=extract_json source=\(extracted.source)",
                    error: error.localizedDescription,
                    payloadPreview: extracted.text
                )
                throw error
            }

            let result = normalizedWordsCorrectionResult(from: jsonData)
            DebugLog.providerEvent(
                phase: "success",
                service: "cerebras_words_correction",
                model: model,
                metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) duration_ms=\(durationMS(since: startedAt)) patch_present=\(!(result.patch?.isEmpty ?? true)) reason=\(result.reason)",
                payloadPreview: extracted.text
            )
            return result
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "cerebras_words_correction",
                model: model,
                metadata: "provider=cerebras duration_ms=\(durationMS(since: startedAt))",
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func runGeminiWordsCorrection(
        seed: PostResponseCorrectionSeed,
        geminiAPIKey: String
    ) async throws -> WordsCorrectionResult {
        guard !geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.missingGeminiKey
        }

        let envelope = seed.request
        let stage = ModelConfig.shared.localRuntime.google.workingAgent
        let model = stage.model
        let startedAt = Date()
        let attachmentSummary = attachmentSummary(from: envelope.attachments)
        let systemPrompt = ElsonPromptCatalog.wordsCorrectionSystemPrompt(
            workingAgentPrompt: envelope.workingAgentPrompt,
            includeConversationHistory: envelope.surface == "chat"
        )
        let userPrompt = ElsonPromptCatalog.wordsCorrectionUserPrompt(
            envelope: envelope,
            assistantReplyText: seed.assistantReplyText,
            attachmentSummary: attachmentSummary
        )
        let images = imageInputs(from: envelope.attachments)
        let requestBody = makeGeminiGenerateContentBody(
            systemPrompt: systemPrompt,
            history: envelope.surface == "chat" ? envelope.conversationHistory : [],
            currentUserPrompt: userPrompt,
            images: images,
            responseSchema: wordsCorrectionResponseSchema(),
            stage: stage
        )

        DebugLog.providerEvent(
            phase: "start",
            service: "gemini_words_correction",
            model: model,
            metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) attachments=\(envelope.attachments.count) images=\(images.count)",
            payloadPreview: """
            system:
            \(systemPrompt)

            history_messages: \(envelope.surface == "chat" ? envelope.conversationHistory.count : 0)
            images: \(images.map(\.name).joined(separator: ", ").nilIfEmpty ?? "None")

            user:
            \(userPrompt)
            """
        )

        do {
            let (data, response) = try await performGeminiRequest(
                apiKey: geminiAPIKey,
                requestBody: requestBody,
                model: model,
                service: "Gemini Words Correction"
            )
            let rawBody = rawBodyText(from: data)
            do {
                try validate(response: response, data: data, service: "Gemini Words Correction")
            } catch {
                DebugLog.providerFailure(
                    service: "gemini_words_correction",
                    model: model,
                    metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                    error: error.localizedDescription,
                    payloadPreview: rawBody
                )
                throw error
            }

            let extracted = try extractedResponseText(from: data, service: "Gemini Words Correction")
            guard let jsonData = extractJSONData(from: extracted.text) else {
                let error = LocalAIServiceError.invalidResponse("Gemini Words Correction")
                DebugLog.providerFailure(
                    service: "gemini_words_correction",
                    model: model,
                    metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) duration_ms=\(durationMS(since: startedAt)) step=extract_json source=\(extracted.source)",
                    error: error.localizedDescription,
                    payloadPreview: extracted.text
                )
                throw error
            }

            let result = normalizedWordsCorrectionResult(from: jsonData)
            DebugLog.providerEvent(
                phase: "success",
                service: "gemini_words_correction",
                model: model,
                metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) duration_ms=\(durationMS(since: startedAt)) patch_present=\(!(result.patch?.isEmpty ?? true)) reason=\(result.reason)",
                payloadPreview: extracted.text
            )
            return result
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "gemini_words_correction",
                model: model,
                metadata: "provider=google duration_ms=\(durationMS(since: startedAt))",
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func runCerebrasWorkingAgent(
        request envelope: ElsonRequestEnvelope,
        cerebrasAPIKey: String
    ) async throws -> AgentDecision {
        guard !cerebrasAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.missingCerebrasKey
        }

        let stage = ModelConfig.shared.localRuntime.cerebras.workingAgent
        let model = stage.model
        let startedAt = Date()

        let attachmentSummary = envelope.attachments.isEmpty
            ? "None"
            : envelope.attachments.map { attachment in
                "\(attachment.kind) | \(attachment.name) | \(attachment.mime) | source=\(attachment.source)"
            }.joined(separator: "\n")

        let systemPrompt = ElsonPromptCatalog.workingAgentSystemPrompt(
            workingAgentPrompt: envelope.workingAgentPrompt,
            includeConversationHistory: envelope.surface == "chat"
        )
        let userPrompt = ElsonPromptCatalog.workingAgentUserPrompt(
            envelope: envelope,
            attachmentSummary: attachmentSummary
        )

        let url = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(cerebrasAPIKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messages = ElsonPromptCatalog.cerebrasMessages(
            systemPrompt: systemPrompt,
            includeConversationHistory: envelope.surface == "chat",
            history: envelope.conversationHistory,
            currentUserPrompt: userPrompt
        )
        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": stage.temperature ?? 0.1,
            "response_format": [
                "type": "json_object"
            ],
        ]
        if let topP = stage.topP {
            payload["top_p"] = topP
        }
        if let thinkingLevel = stage.thinkingLevel, !thinkingLevel.isEmpty {
            payload["reasoning_effort"] = thinkingLevel
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let requestPreview = prettyJSONString(from: messages) ?? """
        system:
        \(systemPrompt)

        user:
        \(userPrompt)
        """
        DebugLog.providerEvent(
            phase: "start",
            service: "cerebras_working_agent",
            model: model,
            metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) mode_hint=\(envelope.modeHint) has_screen_context=\(envelope.screenContext.hasScreenContext) attachments=\(envelope.attachments.count)",
            payloadPreview: requestPreview
        )

        do {
            let (data, response) = try await session.data(for: urlRequest)
            let rawBody = rawBodyText(from: data)
            do {
                try validate(response: response, data: data, service: "Working Agent")
            } catch {
                DebugLog.providerFailure(
                    service: "cerebras_working_agent",
                    model: model,
                    metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                    error: error.localizedDescription,
                    payloadPreview: rawBody
                )
                throw error
            }
            DebugLog.providerEvent(
                phase: "http_response",
                service: "cerebras_working_agent",
                model: model,
                metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                payloadPreview: rawBody
            )

            let extracted = try extractedResponseText(from: data, service: "Working Agent")
            DebugLog.providerEvent(
                phase: "parse_extracted",
                service: "cerebras_working_agent",
                model: model,
                metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) source=\(extracted.source)",
                payloadPreview: extracted.text
            )
            guard let jsonData = extractJSONData(from: extracted.text) else {
                let error = LocalAIServiceError.invalidResponse("Working Agent")
                DebugLog.providerFailure(
                    service: "cerebras_working_agent",
                    model: model,
                    metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) step=extract_json source=\(extracted.source)",
                    error: error.localizedDescription,
                    payloadPreview: extracted.text
                )
                throw error
            }

            let decision = normalizedAgentDecision(from: jsonData)
            DebugLog.providerEvent(
                phase: "response",
                service: "cerebras_working_agent",
                model: model,
                metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) raw_preview=\(shortPreview(extracted.text))",
                payloadPreview: extracted.text
            )
            DebugLog.providerEvent(
                phase: "decision",
                service: "cerebras_working_agent",
                model: model,
                metadata: "provider=cerebras request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) outcome_type=\(decision.outcomeType.rawValue) actions=\(decision.localActions.map(\.type).joined(separator: ",")) reply_preview=\(shortPreview(decision.replyText)) patch_present=\(!(decision.myElsonPatch?.isEmpty ?? true)) reason=\(decision.reason)",
                payloadPreview: """
                raw_response:
                \(extracted.text)

                normalized_decision:
                outcome_type=\(decision.outcomeType.rawValue)
                local_actions=\(decision.localActions.map(\.type))
                reason=\(decision.reason)
                """
            )

            return decision
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "cerebras_working_agent",
                model: model,
                metadata: "provider=cerebras duration_ms=\(durationMS(since: startedAt))",
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func runGeminiWorkingAgent(
        request envelope: ElsonRequestEnvelope,
        geminiAPIKey: String
    ) async throws -> AgentDecision {
        guard !geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIServiceError.missingGeminiKey
        }

        let stage = ModelConfig.shared.localRuntime.google.workingAgent
        let model = stage.model
        let startedAt = Date()
        let attachmentSummary = envelope.attachments.isEmpty
            ? "None"
            : envelope.attachments.map { attachment in
                "\(attachment.kind) | \(attachment.name) | \(attachment.mime) | source=\(attachment.source)"
            }.joined(separator: "\n")
        let systemPrompt = ElsonPromptCatalog.workingAgentSystemPrompt(
            workingAgentPrompt: envelope.workingAgentPrompt,
            includeConversationHistory: envelope.surface == "chat"
        )
        let userPrompt = ElsonPromptCatalog.workingAgentUserPrompt(
            envelope: envelope,
            attachmentSummary: attachmentSummary
        )
        let images = imageInputs(from: envelope.attachments)
        let requestBody = makeGeminiGenerateContentBody(
            systemPrompt: systemPrompt,
            history: envelope.surface == "chat" ? envelope.conversationHistory : [],
            currentUserPrompt: userPrompt,
            images: images,
            responseSchema: workingAgentResponseSchema(),
            stage: stage
        )

        DebugLog.providerEvent(
            phase: "start",
            service: "gemini_working_agent",
            model: model,
            metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) mode_hint=\(envelope.modeHint) has_screen_context=\(envelope.screenContext.hasScreenContext) attachments=\(envelope.attachments.count) images=\(images.count)",
            payloadPreview: """
            system:
            \(systemPrompt)

            history_messages: \(envelope.surface == "chat" ? envelope.conversationHistory.count : 0)
            images: \(images.map(\.name).joined(separator: ", ").nilIfEmpty ?? "None")

            user:
            \(userPrompt)
            """
        )

        do {
            let (data, response) = try await performGeminiRequest(
                apiKey: geminiAPIKey,
                requestBody: requestBody,
                model: model,
                service: "Gemini Working Agent"
            )
            let rawBody = rawBodyText(from: data)
            do {
                try validate(response: response, data: data, service: "Gemini Working Agent")
            } catch {
                DebugLog.providerFailure(
                    service: "gemini_working_agent",
                    model: model,
                    metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                    error: error.localizedDescription,
                    payloadPreview: rawBody
                )
                throw error
            }
            DebugLog.providerEvent(
                phase: "http_response",
                service: "gemini_working_agent",
                model: model,
                metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                payloadPreview: rawBody
            )

            let extracted = try extractedResponseText(from: data, service: "Gemini Working Agent")
            DebugLog.providerEvent(
                phase: "parse_extracted",
                service: "gemini_working_agent",
                model: model,
                metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) source=\(extracted.source)",
                payloadPreview: extracted.text
            )
            guard let jsonData = extractJSONData(from: extracted.text) else {
                let error = LocalAIServiceError.invalidResponse("Gemini Working Agent")
                DebugLog.providerFailure(
                    service: "gemini_working_agent",
                    model: model,
                    metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) step=extract_json source=\(extracted.source)",
                    error: error.localizedDescription,
                    payloadPreview: extracted.text
                )
                throw error
            }

            let decision = normalizedAgentDecision(from: jsonData)
            DebugLog.providerEvent(
                phase: "response",
                service: "gemini_working_agent",
                model: model,
                metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) duration_ms=\(durationMS(since: startedAt)) raw_preview=\(shortPreview(extracted.text))",
                payloadPreview: extracted.text
            )
            DebugLog.providerEvent(
                phase: "decision",
                service: "gemini_working_agent",
                model: model,
                metadata: "provider=google request_id=\(envelope.requestId) thread_id=\(envelope.threadId) surface=\(envelope.surface) input_source=\(envelope.inputSource) outcome_type=\(decision.outcomeType.rawValue) actions=\(decision.localActions.map(\.type).joined(separator: ",")) reply_preview=\(shortPreview(decision.replyText)) patch_present=\(!(decision.myElsonPatch?.isEmpty ?? true)) reason=\(decision.reason)",
                payloadPreview: """
                raw_response:
                \(extracted.text)

                normalized_decision:
                outcome_type=\(decision.outcomeType.rawValue)
                local_actions=\(decision.localActions.map(\.type))
                reason=\(decision.reason)
                """
            )

            return decision
        } catch let error as LocalAIServiceError {
            throw error
        } catch {
            DebugLog.providerFailure(
                service: "gemini_working_agent",
                model: model,
                metadata: "provider=google duration_ms=\(durationMS(since: startedAt))",
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func validate(response: URLResponse, data: Data, service: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LocalAIServiceError.invalidResponse(service)
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = parsedServiceErrorText(from: data) ?? (String(data: data, encoding: .utf8) ?? "Unknown error")
            throw LocalAIServiceError.serviceFailure(service, http.statusCode, text)
        }
    }

    private func validateChatCompletionAPIKey(
        apiKey: String,
        url: URL,
        model: String,
        service: String
    ) async throws {
        let startedAt = Date()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "messages": ElsonPromptCatalog.apiKeyValidationMessages(),
            "model": model,
            "temperature": 0,
            "top_p": 1,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let serviceSlug = service.replacingOccurrences(of: " ", with: "_").lowercased()

        DebugLog.providerEvent(
            phase: "start",
            service: serviceSlug,
            model: model,
            metadata: "purpose=api_key_validation"
        )

        let (data, response) = try await session.data(for: request)
        do {
            try validate(response: response, data: data, service: service)
        } catch {
            DebugLog.providerFailure(
                service: serviceSlug,
                model: model,
                metadata: "duration_ms=\(durationMS(since: startedAt)) status=\(statusCode(from: response) ?? -1)",
                error: error.localizedDescription,
                payloadPreview: String(data: data, encoding: .utf8)
            )
            throw error
        }

        let completion = try JSONDecoder().decode(CerebrasCompletionResponse.self, from: data)
        guard !completion.choices.isEmpty else {
            let error = LocalAIServiceError.invalidResponse(service)
            DebugLog.providerFailure(
                service: serviceSlug,
                model: model,
                metadata: "duration_ms=\(durationMS(since: startedAt)) reason=missing_validation_choice",
                error: error.localizedDescription,
                payloadPreview: String(data: data, encoding: .utf8)
            )
            throw error
        }

        let reply = (try? extractedResponseText(from: data, service: service))?.text ?? ""

        DebugLog.providerEvent(
            phase: "success",
            service: serviceSlug,
            model: model,
            metadata: "duration_ms=\(durationMS(since: startedAt)) purpose=api_key_validation reply_chars=\(reply.count)"
        )
    }

    private func parsedServiceErrorText(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        if let message = object["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        return nil
    }

    private func extractJSONData(from content: String) -> Data? {
        if let directData = content.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: directData)) != nil {
            return directData
        }

        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}") else {
            return nil
        }

        let jsonString = String(content[start...end])
        return jsonString.data(using: .utf8)
    }

    private func extractedResponseText(from data: Data, service: String) throws -> ExtractedResponseText {
        if let completion = try? JSONDecoder().decode(CerebrasCompletionResponse.self, from: data),
           let extracted = completion.choices.compactMap(extractedResponseText(from:)).first {
            return extracted
        }

        if let object = try? JSONSerialization.jsonObject(with: data),
           let extracted = extractedResponseText(fromJSONObject: object) {
            return extracted
        }

        throw LocalAIServiceError.invalidResponse(service)
    }

    private func extractedResponseText(from choice: CerebrasCompletionResponse.Choice) -> ExtractedResponseText? {
        if let content = choice.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            return ExtractedResponseText(text: content, source: "choices[0].message.content")
        }

        if let text = choice.message?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return ExtractedResponseText(text: text, source: "choices[0].message.text")
        }

        if let choiceText = choice.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !choiceText.isEmpty {
            return ExtractedResponseText(text: choiceText, source: "choices[0].text")
        }

        if let reasoning = choice.message?.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reasoning.isEmpty {
            return ExtractedResponseText(text: reasoning, source: "choices[0].message.reasoning")
        }

        return nil
    }

    private func extractedResponseText(fromJSONObject value: Any) -> ExtractedResponseText? {
        for preferredKey in ["content", "text", "output_text", "reasoning"] {
            if let extracted = findStringValue(forKey: preferredKey, in: value, path: "$") {
                return extracted
            }
        }
        return nil
    }

    private func findStringValue(forKey key: String, in value: Any, path: String) -> ExtractedResponseText? {
        if let dictionary = value as? [String: Any] {
            if let stringValue = dictionary[key] as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return ExtractedResponseText(text: trimmed, source: "\(path).\(key)")
                }
            }

            for (childKey, childValue) in dictionary {
                if let extracted = findStringValue(forKey: key, in: childValue, path: "\(path).\(childKey)") {
                    return extracted
                }
            }
        }

        if let array = value as? [Any] {
            for (index, item) in array.enumerated() {
                if let extracted = findStringValue(forKey: key, in: item, path: "\(path)[\(index)]") {
                    return extracted
                }
            }
        }

        return nil
    }

    private func normalizedAudioDeciderRoute(_ value: String?, allowFullAgent: Bool) -> AudioDeciderRoute {
        let normalized: AudioDeciderRoute = switch value?.lowercased() {
        case AudioDeciderRoute.fullAgent.rawValue:
            .fullAgent
        default:
            .directTranscript
        }

        if normalized == .fullAgent, !allowFullAgent {
            return .directTranscript
        }

        return normalized
    }

    private func normalizedAudioDeciderThreadDecision(
        _ value: String?,
        defaultValue: AudioDeciderThreadDecision
    ) -> AudioDeciderThreadDecision {
        switch value?.lowercased() {
        case AudioDeciderThreadDecision.continueCurrentThread.rawValue:
            return .continueCurrentThread
        case AudioDeciderThreadDecision.startNewThread.rawValue:
            return .startNewThread
        default:
            return defaultValue
        }
    }

    private func normalizedAudioDeciderReplyRelation(_ value: String?) -> AudioDeciderReplyRelation {
        switch value?.lowercased() {
        case AudioDeciderReplyRelation.replyToLastAssistant.rawValue:
            return .replyToLastAssistant
        case AudioDeciderReplyRelation.replyToLastUser.rawValue:
            return .replyToLastUser
        default:
            return .none
        }
    }

    private func normalizedReplyConfidence(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value < 0 { return 0 }
        if value > 1 { return 1 }
        return value
    }

    private func defaultAudioDeciderReason(for route: AudioDeciderRoute) -> String {
        switch route {
        case .directTranscript:
            return "Direct transcript return."
        case .fullAgent:
            return "Requires Working Agent."
        }
    }

    private func normalizedOutcomeType(_ value: String?) -> AgentOutcomeType {
        switch value?.lowercased() {
        case AgentOutcomeType.reply.rawValue:
            return .reply
        case AgentOutcomeType.note.rawValue:
            return .note
        case AgentOutcomeType.reminder.rawValue:
            return .reminder
        case AgentOutcomeType.myElsonUpdate.rawValue:
            return .myElsonUpdate
        default:
            return .transcript
        }
    }

    private func normalizedAgentDecision(from jsonData: Data) -> AgentDecision {
        let rawDecision = (try? JSONDecoder().decode(LocalAgentDecisionResponse.self, from: jsonData))
            ?? LocalAgentDecisionResponse(
                outcomeType: nil,
                replyText: nil,
                localActions: nil,
                myElsonPatch: nil,
                reason: nil
            )

        return AgentDecision(
            outcomeType: normalizedOutcomeType(rawDecision.outcomeType),
            replyText: rawDecision.replyText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            localActions: (rawDecision.localActions ?? []).map { AgentLocalAction(type: $0.type, text: $0.text) },
            myElsonPatch: rawDecision.myElsonPatch,
            reason: rawDecision.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Embedded agent decision."
        )
    }

    private func normalizedWordsCorrectionResult(from jsonData: Data) -> WordsCorrectionResult {
        let rawDecision = (try? JSONDecoder().decode(LocalWordsCorrectionResponse.self, from: jsonData))
            ?? LocalWordsCorrectionResponse(
                decision: nil,
                words: nil,
                removeWords: nil,
                replaceWords: nil,
                reason: nil
            )

        let decision = rawDecision.decision?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "no_change"
        let patch = MyElsonPatch(
            words: rawDecision.words ?? [],
            removeWords: rawDecision.removeWords ?? [],
            replaceWords: rawDecision.replaceWords ?? []
        )

        guard decision == "update_words", !patch.isEmpty else {
            return WordsCorrectionResult(
                patch: nil,
                reason: rawDecision.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No words update needed."
            )
        }

        return WordsCorrectionResult(
            patch: patch,
            reason: rawDecision.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Words glossary updated."
        )
    }

    func normalizedPromptLearningResult(from jsonData: Data) -> PromptLearningResult {
        let rawDecision = (try? JSONDecoder().decode(LocalPromptLearningResponse.self, from: jsonData))
            ?? LocalPromptLearningResponse(decision: nil, updatedPrompt: nil, reason: nil)

        let decision: PromptLearningDecision
        switch rawDecision.decision?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case PromptLearningDecision.updateTranscriptPrompt.rawValue:
            decision = .updateTranscriptPrompt
        case PromptLearningDecision.updateWorkingAgentPrompt.rawValue:
            decision = .updateWorkingAgentPrompt
        default:
            decision = .noLearning
        }

        let updatedPrompt = rawDecision.updatedPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        if decision == .noLearning {
            return PromptLearningResult(
                decision: .noLearning,
                updatedPrompt: nil,
                reason: rawDecision.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No prompt update needed."
            )
        }

        guard let updatedPrompt else {
            return PromptLearningResult(
                decision: .noLearning,
                updatedPrompt: nil,
                reason: "Prompt learning declined because no updated prompt was returned."
            )
        }

        return PromptLearningResult(
            decision: decision,
            updatedPrompt: updatedPrompt,
            reason: rawDecision.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Prompt updated from feedback."
        )
    }

    private func promptLearningResponseSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "decision": [
                    "type": "string",
                    "enum": [
                        PromptLearningDecision.noLearning.rawValue,
                        PromptLearningDecision.updateTranscriptPrompt.rawValue,
                        PromptLearningDecision.updateWorkingAgentPrompt.rawValue,
                    ]
                ],
                "updated_prompt": [
                    "type": ["string", "null"]
                ],
                "reason": [
                    "type": "string"
                ]
            ],
            "required": ["decision", "updated_prompt", "reason"]
        ]
    }

    private func performGeminiRequest(
        apiKey: String,
        requestBody: [String: Any],
        model: String,
        service: String
    ) async throws -> (Data, URLResponse) {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        return try await session.data(for: request)
    }

    private func makeGeminiGenerateContentBody(
        systemPrompt: String,
        history: [ElsonConversationTurnPayload],
        currentUserPrompt: String,
        images: [LocalImageInput],
        responseSchema: [String: Any]?,
        stage: ModelStageConfig
    ) -> [String: Any] {
        var contents: [[String: Any]] = history.map { turn in
            [
                "role": turn.role == .assistant ? "model" : "user",
                "parts": [
                    ["text": turn.content]
                ]
            ]
        }

        var currentParts: [[String: Any]] = images.map { image in
            [
                "inlineData": [
                    "mimeType": image.mime,
                    "data": image.data.base64EncodedString()
                ]
            ]
        }
        currentParts.append(["text": currentUserPrompt])
        contents.append([
            "role": "user",
            "parts": currentParts
        ])

        var generationConfig: [String: Any] = [:]
        if let temperature = stage.temperature {
            generationConfig["temperature"] = temperature
        }
        if let topP = stage.topP {
            generationConfig["topP"] = topP
        }
        if let topK = stage.topK {
            generationConfig["topK"] = topK
        }
        if let thinkingLevel = geminiThinkingLevel(for: stage) {
            generationConfig["thinkingConfig"] = [
                "thinkingLevel": thinkingLevel
            ]
        }
        if let responseSchema {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseJsonSchema"] = responseSchema
        }

        var body: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],
            "contents": contents
        ]
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
        }
        return body
    }

    private func normalizedHistorySummaryTitle(_ rawTitle: String, fallbackSource: String) -> String {
        let fallback = fallbackSource.trimmingCharacters(in: .whitespacesAndNewlines).capitalized.nilIfEmpty ?? "History"
        let flattened = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = flattened.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’•:;-").union(.whitespacesAndNewlines))
        let words = trimmed
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .map(String.init)
        let normalized = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? fallback : normalized
    }

    private func geminiThinkingLevel(for stage: ModelStageConfig) -> String? {
        guard let rawThinkingLevel = stage.thinkingLevel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawThinkingLevel.isEmpty,
              rawThinkingLevel.lowercased() != "none"
        else {
            return nil
        }

        let normalizedModel = stage.model.lowercased()
        guard normalizedModel.hasPrefix("gemini-3") else {
            return nil
        }

        return rawThinkingLevel
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

    private func joinedMetadata(_ parts: String?...) -> String {
        parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func workingAgentResponseSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "outcome_type": [
                    "type": "string",
                    "enum": AgentOutcomeType.allCases.map(\.rawValue)
                ],
                "reply_text": [
                    "type": "string"
                ],
                "local_actions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "type": ["type": "string"],
                            "text": ["type": ["string", "null"]]
                        ],
                        "required": ["type"]
                    ]
                ],
                "myelson_patch": [
                    "type": "object",
                    "properties": [
                        "identity_and_profile": ["type": "array", "items": ["type": "string"]],
                        "preferences": ["type": "array", "items": ["type": "string"]],
                        "words": ["type": "array", "items": ["type": "string"]],
                        "notes": ["type": "array", "items": ["type": "string"]],
                        "reminders": ["type": "array", "items": ["type": "string"]],
                        "open_loops": ["type": "array", "items": ["type": "string"]],
                        "remove_identity_and_profile": ["type": "array", "items": ["type": "string"]],
                        "remove_preferences": ["type": "array", "items": ["type": "string"]],
                        "remove_words": ["type": "array", "items": ["type": "string"]],
                        "remove_notes": ["type": "array", "items": ["type": "string"]],
                        "remove_reminders": ["type": "array", "items": ["type": "string"]],
                        "remove_open_loops": ["type": "array", "items": ["type": "string"]],
                        "replace_identity_and_profile": [
                            "type": "array",
                            "items": replaceOperationSchema()
                        ],
                        "replace_preferences": [
                            "type": "array",
                            "items": replaceOperationSchema()
                        ],
                        "replace_words": [
                            "type": "array",
                            "items": replaceOperationSchema()
                        ],
                        "replace_notes": [
                            "type": "array",
                            "items": replaceOperationSchema()
                        ],
                        "replace_reminders": [
                            "type": "array",
                            "items": replaceOperationSchema()
                        ],
                        "replace_open_loops": [
                            "type": "array",
                            "items": replaceOperationSchema()
                        ]
                    ],
                    "required": [
                        "identity_and_profile",
                        "preferences",
                        "words",
                        "notes",
                        "reminders",
                        "open_loops",
                        "remove_identity_and_profile",
                        "remove_preferences",
                        "remove_words",
                        "remove_notes",
                        "remove_reminders",
                        "remove_open_loops",
                        "replace_identity_and_profile",
                        "replace_preferences",
                        "replace_words",
                        "replace_notes",
                        "replace_reminders",
                        "replace_open_loops"
                    ]
                ],
                "reason": [
                    "type": "string"
                ]
            ],
            "required": ["outcome_type", "reply_text", "local_actions", "myelson_patch", "reason"]
        ]
    }

    private func wordsCorrectionResponseSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "decision": [
                    "type": "string",
                    "enum": ["no_change", "update_words"]
                ],
                "words": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "remove_words": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "replace_words": [
                    "type": "array",
                    "items": replaceOperationSchema()
                ],
                "reason": [
                    "type": "string"
                ]
            ],
            "required": ["decision", "words", "remove_words", "replace_words", "reason"]
        ]
    }

    private func durationMS(since startedAt: Date) -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1000)
    }

    private func replaceOperationSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "from": ["type": "string"],
                "to": ["type": "string"]
            ],
            "required": ["from", "to"]
        ]
    }

    private func statusCode(from response: URLResponse) -> Int? {
        (response as? HTTPURLResponse)?.statusCode
    }

    private func shortPreview(_ value: String?, limit: Int = 180) -> String {
        guard let value else { return "none" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "none" }
        let collapsed = trimmed.replacingOccurrences(of: "\n", with: " ")
        guard collapsed.count > limit else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<end]) + "…"
    }

    private func rawBodyText(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "<non-utf8 body bytes=\(data.count)>"
    }

    private func prettyJSONString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}

enum LocalAIServiceError: LocalizedError {
    case missingGroqKey
    case missingCerebrasKey
    case missingGeminiKey
    case invalidResponse(String)
    case serviceFailure(String, Int, String)

    var errorDescription: String? {
        switch self {
        case .missingGroqKey:
            return "Missing Groq API key."
        case .missingCerebrasKey:
            return "Missing Cerebras API key."
        case .missingGeminiKey:
            return "Missing Gemini API key."
        case let .invalidResponse(service):
            return "\(service) returned an invalid response."
        case let .serviceFailure(service, code, text):
            return "\(service) failed (\(code)): \(text)"
        }
    }
}

private struct LocalAgentDecisionResponse: Decodable {
    struct Action: Decodable {
        let type: String
        let text: String?
    }

    let outcomeType: String?
    let replyText: String?
    let localActions: [Action]?
    let myElsonPatch: MyElsonPatch?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case outcomeType = "outcome_type"
        case replyText = "reply_text"
        case localActions = "local_actions"
        case myElsonPatch = "myelson_patch"
        case reason
    }
}

private struct LocalAudioIntentResponse: Decodable {
    let route: String?
    let threadDecision: String?
    let replyRelation: String?
    let replyConfidence: Double?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case route
        case threadDecision = "thread_decision"
        case replyRelation = "reply_relation"
        case replyConfidence = "reply_confidence"
        case reason
    }
}

private struct LocalScreenExtractionResponse: Decodable {
    let screenText: String?
    let screenDescription: String?

    enum CodingKeys: String, CodingKey {
        case screenText = "screen_text"
        case screenDescription = "screen_description"
    }
}

private struct LocalWordsCorrectionResponse: Decodable {
    let decision: String?
    let words: [String]?
    let removeWords: [String]?
    let replaceWords: [MyElsonReplaceOperation]?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case decision
        case words
        case removeWords = "remove_words"
        case replaceWords = "replace_words"
        case reason
    }
}

private struct LocalPromptLearningResponse: Decodable {
    let decision: String?
    let updatedPrompt: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case decision
        case updatedPrompt = "updated_prompt"
        case reason
    }
}

private struct CerebrasCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let text: String?
            let reasoning: String?
        }

        let message: Message?
        let text: String?
    }

    let choices: [Choice]
}

private struct ExtractedResponseText {
    let text: String
    let source: String
}

private extension String {
    var nonEmptyOrPlaceholder: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "None" : trimmed
    }

    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Data {
    mutating func appendFormField(named name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFileField(named name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
