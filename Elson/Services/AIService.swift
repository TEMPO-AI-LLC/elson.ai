import Foundation
import SwiftUI

@MainActor
final class AIService: ObservableObject {
    private var currentProvider: APIProvider = .openai
    private var providerConfig: ProviderConfig = OpenAIConfig()
    
    @Published var isProcessing = false
    
    func setProvider(_ provider: APIProvider) {
        self.currentProvider = provider
        self.providerConfig = ProviderConfigFactory.create(provider)
        print("🤖 DEBUG: Switched to \(provider.displayName) provider")
    }
    
    // MARK: - Transcription
    
    func transcribeAudio(_ audioURL: URL, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw APIError.missingAPIKey
        }
        
        let cleanedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        print("🤖 DEBUG: Transcribing audio using \(currentProvider.displayName) (\(providerConfig.transcriptionModel))")
        
        // Handle Google's special transcription process
        if currentProvider == .google {
            let googleConfig = (providerConfig as? GoogleConfig) ?? GoogleConfig()
            // Google requires file upload first, then transcription
            let fileURI = try await googleConfig.uploadFileForTranscription(audioURL: audioURL, apiKey: cleanedAPIKey)
            print("🤖 DEBUG: Google file uploaded with URI: \(fileURI)")
            
            let transcribedText = try await googleConfig.transcribeWithFileURI(fileURI, apiKey: cleanedAPIKey)
            print("🤖 DEBUG: Successfully transcribed \(transcribedText.count) characters using \(currentProvider.displayName)")
            return transcribedText
        }
        
        // Standard transcription for OpenAI and Groq
        let request = try providerConfig.transcriptionRequest(audioURL: audioURL, apiKey: cleanedAPIKey)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("🤖 DEBUG: Transcription API Error (\(currentProvider.displayName)): \(errorText)")
            throw APIError.apiError(httpResponse.statusCode, errorText)
        }
        
        do {
            let transcribedText = try providerConfig.parseTranscriptionResponse(data: data)
            print("🤖 DEBUG: Successfully transcribed \(transcribedText.count) characters using \(currentProvider.displayName)")
            return transcribedText
        } catch {
            print("🤖 DEBUG: Failed to parse transcription response from \(currentProvider.displayName): \(error)")
            print("🤖 DEBUG: Response data: \(String(data: data, encoding: .utf8) ?? "nil")")
            throw APIError.decodingError(error.localizedDescription)
        }
    }
    
    // MARK: - Text Enhancement
    
    func enhanceText(_ text: String, context: String, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw APIError.missingAPIKey
        }
        
        let cleanedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        print("🤖 DEBUG: Enhancing text using \(currentProvider.displayName) (\(providerConfig.enhancementModel))")
        
        let request = try providerConfig.enhancementRequest(text: text, context: context, apiKey: cleanedAPIKey)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("🤖 DEBUG: Enhancement API Error (\(currentProvider.displayName)): \(errorText)")
            throw APIError.apiError(httpResponse.statusCode, errorText)
        }
        
        do {
            let enhancedText = try providerConfig.parseEnhancementResponse(data: data)
            let cleanedText = stripQuotes(from: enhancedText)
            print("🤖 DEBUG: Successfully enhanced text using \(currentProvider.displayName)")
            return cleanedText
        } catch {
            print("🤖 DEBUG: Failed to parse enhancement response from \(currentProvider.displayName): \(error)")
            print("🤖 DEBUG: Response data: \(String(data: data, encoding: .utf8) ?? "nil")")
            throw APIError.decodingError(error.localizedDescription)
        }
    }
    
    // MARK: - Combined Process
    
    func processAudio(_ audioURL: URL, context: String, apiKey: String, screenshotJPEGData: [Data] = []) async throws -> String {
        isProcessing = true
        
        defer {
            isProcessing = false
        }
        
        print("🤖 DEBUG: Processing audio using \(currentProvider.displayName)")
        
        let cleanedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if currentProvider == .google {
            let googleConfig = (providerConfig as? GoogleConfig) ?? GoogleConfig()
            let fileURI = try await googleConfig.uploadFileForTranscription(audioURL: audioURL, apiKey: cleanedAPIKey)
            print("🤖 DEBUG: Google file uploaded with URI: \(fileURI)")

            let (transcript, enhancedText) = try await transcribeAndEnhanceWithGoogle(
                audioFileURI: fileURI,
                context: context,
                apiKey: cleanedAPIKey,
                screenshotJPEGData: screenshotJPEGData
            )

            print("🤖 DEBUG: Transcribed text (\(transcript.count) chars): \(transcript.prefix(100))...")
            print("🤖 DEBUG: Enhanced text (\(enhancedText.count) chars): \(enhancedText.prefix(100))...")
            return enhancedText
        }

        // Step 1: Transcribe audio
        let transcribedText = try await transcribeAudio(audioURL, apiKey: cleanedAPIKey)
        print("🤖 DEBUG: Transcribed text (\(transcribedText.count) chars): \(transcribedText.prefix(100))...")
        
        // Step 2: Enhance text
        let enhancedText = try await enhanceText(transcribedText, context: context, apiKey: cleanedAPIKey)
        print("🤖 DEBUG: Enhanced text (\(enhancedText.count) chars): \(enhancedText.prefix(100))...")
        
        return enhancedText
    }

    private func transcribeAndEnhanceWithGoogle(
        audioFileURI: String,
        context: String,
        apiKey: String,
        screenshotJPEGData: [Data]
    ) async throws -> (transcript: String, enhancedText: String) {
        let googleConfig = (providerConfig as? GoogleConfig) ?? GoogleConfig()
        let url = URL(string: "\(googleConfig.baseURL)/models/\(googleConfig.transcriptionModel):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var parts: [[String: Any]] = [
            [
                "file_data": [
                    "mime_type": "audio/m4a",
                    "file_uri": audioFileURI
                ]
            ]
        ]

        if !screenshotJPEGData.isEmpty {
            for data in screenshotJPEGData {
                parts.append([
                    "inline_data": [
                        "mime_type": "image/jpeg",
                        "data": data.base64EncodedString()
                    ]
                ])
            }
        }

        let prompt = ElsonPromptCatalog.googleCombinedTranscriptionUserPrompt(context: context)

        parts.append(["text": prompt])

        let requestBody: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": ElsonPromptCatalog.googleCombinedTranscriptionSystemInstruction()]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": parts
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseJsonSchema": [
                    "type": "object",
                    "properties": [
                        "transcript": ["type": "string"],
                        "enhanced_text": ["type": "string"]
                    ],
                    "required": ["transcript", "enhanced_text"]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.apiError(httpResponse.statusCode, errorText)
        }

        let text = try googleConfig.parseEnhancementResponse(data: data)
        guard let jsonData = text.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let transcript = obj["transcript"] as? String,
              let enhanced = obj["enhanced_text"] as? String else {
            return (transcript: text, enhancedText: text)
        }

        return (transcript: transcript, enhancedText: enhanced)
    }


    // MARK: - Chat

    func chat(systemPrompt: String, messages: [ChatMessage], threadID: String, apiKey: String) async throws -> String {
        try await completeChat(
            systemPrompt: systemPrompt,
            messages: messages,
            threadID: threadID,
            apiKey: apiKey,
            responseFormat: .text,
            temperature: 1
        )
    }

    enum ResponseFormat {
        case text
        case jsonObject
    }

    func completeChat(
        systemPrompt: String,
        messages: [ChatMessage],
        threadID: String,
        apiKey: String,
        model: String? = nil,
        responseFormat: ResponseFormat? = nil,
        temperature: Double? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw APIError.missingAPIKey
        }

        let system = """
        \(systemPrompt)

        ThreadID: \(threadID)
        """

        switch currentProvider {
        case .google:
            return try await chatWithGoogle(
                systemPrompt: system,
                messages: messages,
                apiKey: apiKey,
                responseFormat: responseFormat,
                temperature: temperature
            )
        case .openai, .groq:
            return try await chatWithOpenAICompatible(
                systemPrompt: system,
                messages: messages,
                threadID: threadID,
                apiKey: apiKey,
                model: model,
                responseFormat: responseFormat,
                temperature: temperature
            )
        }
    }

    func completeVision(
        systemPrompt: String,
        userPrompt: String,
        imageJPEGData: [Data],
        threadID: String,
        apiKey: String,
        model: String? = nil,
        responseFormat: ResponseFormat? = nil,
        temperature: Double? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw APIError.missingAPIKey
        }

        switch currentProvider {
        case .google:
            return try await visionWithGoogle(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                imageJPEGData: imageJPEGData,
                apiKey: apiKey,
                model: model ?? providerConfig.visionModel,
                responseFormat: responseFormat,
                temperature: temperature
            )
        case .openai, .groq:
            return try await visionWithOpenAICompatible(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                imageJPEGData: imageJPEGData,
                apiKey: apiKey,
                model: model ?? providerConfig.visionModel,
                responseFormat: responseFormat,
                temperature: temperature
            )
        }
    }

    private func chatWithOpenAICompatible(
        systemPrompt: String,
        messages: [ChatMessage],
        threadID: String,
        apiKey: String,
        model: String? = nil,
        responseFormat: ResponseFormat? = nil,
        temperature: Double? = nil
    ) async throws -> String {
        let url = URL(string: "\(providerConfig.baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payloadMessages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]

        payloadMessages.append(contentsOf: messages.map { message in
            let role: String
            switch message.role {
            case .system: role = "system"
            case .user: role = "user"
            case .assistant: role = "assistant"
            }
            return ["role": role, "content": message.content]
        })

        var requestBody: [String: Any] = [
            "model": model ?? providerConfig.enhancementModel,
            "messages": payloadMessages,
            "temperature": temperature ?? 1,
            "top_p": 1,
            "stream": false,
            "user": threadID
        ]

        if let responseFormat {
            switch responseFormat {
            case .text:
                break
            case .jsonObject:
                requestBody["response_format"] = ["type": "json_object"]
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.apiError(httpResponse.statusCode, errorText)
        }

        struct ChatResponse: Codable {
            let choices: [ChatChoice]
        }

        struct ChatChoice: Codable {
            let message: ChatMessageResponse
        }

        struct ChatMessageResponse: Codable {
            let content: String
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chatResponse.choices.first?.message.content else {
            throw APIError.noResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chatWithGoogle(
        systemPrompt: String,
        messages: [ChatMessage],
        apiKey: String,
        responseFormat: ResponseFormat? = nil,
        temperature: Double? = nil
    ) async throws -> String {
        let url = URL(string: "\(providerConfig.baseURL)/models/\(providerConfig.enhancementModel):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let contents: [[String: Any]] = messages.compactMap { message -> [String: Any]? in
            switch message.role {
            case .system:
                return nil
            case .user:
                return ["role": "user", "parts": [["text": message.content]]]
            case .assistant:
                return ["role": "model", "parts": [["text": message.content]]]
            }
        }

        var requestBody: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],
            "contents": contents
        ]

        var generationConfig: [String: Any] = [:]
        if let temperature {
            generationConfig["temperature"] = temperature
        }
        if let responseFormat {
            switch responseFormat {
            case .text:
                break
            case .jsonObject:
                generationConfig["responseMimeType"] = "application/json"
            }
        }
        if !generationConfig.isEmpty {
            requestBody["generationConfig"] = generationConfig
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.apiError(httpResponse.statusCode, errorText)
        }

        return try providerConfig.parseEnhancementResponse(data: data)
    }

    private func visionWithOpenAICompatible(
        systemPrompt: String,
        userPrompt: String,
        imageJPEGData: [Data],
        apiKey: String,
        model: String,
        responseFormat: ResponseFormat? = nil,
        temperature: Double? = nil
    ) async throws -> String {
        let url = URL(string: "\(providerConfig.baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var userContent: [[String: Any]] = [
            ["type": "text", "text": userPrompt]
        ]
        userContent.append(contentsOf: imageJPEGData.map { data in
            let imageURL = "data:image/jpeg;base64,\(data.base64EncodedString())"
            return ["type": "image_url", "image_url": ["url": imageURL]]
        })

        let messages: [[String: Any]] = [
            [
                "role": "system",
                "content": systemPrompt
            ],
            [
                "role": "user",
                "content": userContent
            ]
        ]

        var requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": temperature ?? 0.2,
            "top_p": 1,
            "stream": false
        ]

        if let responseFormat {
            switch responseFormat {
            case .text:
                break
            case .jsonObject:
                requestBody["response_format"] = ["type": "json_object"]
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.apiError(httpResponse.statusCode, errorText)
        }

        struct ChatResponse: Codable {
            let choices: [ChatChoice]
        }

        struct ChatChoice: Codable {
            let message: ChatMessageResponse
        }

        struct ChatMessageResponse: Codable {
            let content: String
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw APIError.noResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func visionWithGoogle(
        systemPrompt: String,
        userPrompt: String,
        imageJPEGData: [Data],
        apiKey: String,
        model: String,
        responseFormat: ResponseFormat? = nil,
        temperature: Double? = nil
    ) async throws -> String {
        let url = URL(string: "\(providerConfig.baseURL)/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var parts: [[String: Any]] = imageJPEGData.map { data in
            [
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": data.base64EncodedString()
                ]
            ]
        }
        parts.append(["text": userPrompt])

        var requestBody: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": parts
                ]
            ]
        ]

        var generationConfig: [String: Any] = [:]
        if let temperature {
            generationConfig["temperature"] = temperature
        }
        if let responseFormat {
            switch responseFormat {
            case .text:
                break
            case .jsonObject:
                generationConfig["responseMimeType"] = "application/json"
            }
        }
        if !generationConfig.isEmpty {
            requestBody["generationConfig"] = generationConfig
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.apiError(httpResponse.statusCode, errorText)
        }

        return try providerConfig.parseEnhancementResponse(data: data)
    }
    
    // MARK: - Text Cleanup
    
    private func stripQuotes(from text: String) -> String {
        var cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove quotes from beginning and end
        let quotesToRemove = ["\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]
        
        for quote in quotesToRemove {
            if cleanedText.hasPrefix(quote) && cleanedText.hasSuffix(quote) && cleanedText.count > 2 {
                cleanedText = String(cleanedText.dropFirst().dropLast())
                cleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return cleanedText
    }
}
