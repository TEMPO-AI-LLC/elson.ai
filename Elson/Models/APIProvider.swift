import Foundation

// MARK: - API Provider Types

enum APIProvider: String, CaseIterable, Codable {
    case openai = "OpenAI"
    case groq = "Groq"
    case google = "Google"
    
    var displayName: String {
        return rawValue
    }
    
    var baseURL: String {
        switch self {
        case .openai:
            return "https://api.openai.com/v1"
        case .groq:
            return "https://api.groq.com/openai/v1"
        case .google:
            return "https://generativelanguage.googleapis.com/v1beta"
        }
    }
}

// MARK: - Provider Configuration Protocol

protocol ProviderConfig {
    var provider: APIProvider { get }
    var baseURL: String { get }
    var transcriptionModel: String { get }
    var enhancementModel: String { get }
    var visionModel: String { get }
    var validationModel: String { get }
    
    func transcriptionRequest(audioURL: URL, apiKey: String) throws -> URLRequest
    func enhancementRequest(text: String, context: String, apiKey: String) throws -> URLRequest
    func validationRequest(apiKey: String) throws -> URLRequest
    func parseTranscriptionResponse(data: Data) throws -> String
    func parseEnhancementResponse(data: Data) throws -> String
    func parseValidationResponse(data: Data) throws -> Bool
}

// MARK: - OpenAI Configuration

struct OpenAIConfig: ProviderConfig {
    let provider: APIProvider = .openai
    let baseURL: String = "https://api.openai.com/v1"
    var transcriptionModel: String { ModelConfig.shared.config.openai.transcription }
    var enhancementModel: String { ModelConfig.shared.config.openai.enhancement }
    var visionModel: String { ModelConfig.shared.config.openai.vision }
    var validationModel: String { ModelConfig.shared.config.openai.validation }
    
    func transcriptionRequest(audioURL: URL, apiKey: String) throws -> URLRequest {
        let url = URL(string: "\(baseURL)/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Create multipart form data
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add model parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(transcriptionModel)\r\n".data(using: .utf8)!)
        
        // Add file parameter
        let audioData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        return request
    }
    
    func enhancementRequest(text: String, context: String, apiKey: String) throws -> URLRequest {
        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messages = [
            [
                "role": "system",
                "content": ElsonPromptCatalog.structuredEnhancementSystemPrompt(context: context)
            ],
            [
                "role": "user",
                "content": ElsonPromptCatalog.structuredEnhancementUserPrompt(text: text)
            ]
        ]
        
        let requestBody = [
            "model": enhancementModel,
            "messages": messages,
            "response_format": ["type": "json_object"]
        ] as [String: Any]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        return request
    }
    
    func validationRequest(apiKey: String) throws -> URLRequest {
        // Validate key with a model-agnostic endpoint.
        // Using chat/completions here can fail even for valid keys if the chosen validation model
        // isn't compatible with the endpoint (e.g. Responses-only models).
        let url = URL(string: "\(baseURL)/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }


    
    func parseTranscriptionResponse(data: Data) throws -> String {
        struct TranscriptionResponse: Codable {
            let text: String
        }
        
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return response.text
    }
    
    func parseEnhancementResponse(data: Data) throws -> String {
        struct ChatResponse: Codable {
            let choices: [ChatChoice]
        }
        
        struct ChatChoice: Codable {
            let message: ChatMessage
        }
        
        struct ChatMessage: Codable {
            let content: String
        }
        
        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let messageContent = chatResponse.choices.first?.message.content else {
            throw APIError.noResponse
        }
        
        // Parse the JSON response to extract enhanced text
        if let jsonData = messageContent.data(using: .utf8),
           let jsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let enhancedText = jsonObject["enhanced_text"] as? String {
            return enhancedText
        } else {
            // Fallback: return the content directly if JSON parsing fails
            return messageContent
        }
    }
    
    func parseValidationResponse(data: Data) throws -> Bool {
        struct ModelsResponse: Codable {
            struct Model: Codable {
                let id: String
            }

            let data: [Model]
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return !decoded.data.isEmpty
    }
}

// MARK: - Groq Configuration

struct GroqConfig: ProviderConfig {
    let provider: APIProvider = .groq
    let baseURL: String = "https://api.groq.com/openai/v1"
    var transcriptionModel: String { ModelConfig.shared.config.groq.transcription }
    var enhancementModel: String { ModelConfig.shared.config.groq.enhancement }
    var visionModel: String { ModelConfig.shared.config.groq.vision }
    var validationModel: String { ModelConfig.shared.config.groq.validation }
    
    func transcriptionRequest(audioURL: URL, apiKey: String) throws -> URLRequest {
        let url = URL(string: "\(baseURL)/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Create multipart form data
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add model parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(transcriptionModel)\r\n".data(using: .utf8)!)
        
        // Add temperature parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n".data(using: .utf8)!)
        body.append("0\r\n".data(using: .utf8)!)
        
        // Add response_format parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("verbose_json\r\n".data(using: .utf8)!)
        
        // Add file parameter
        let audioData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        return request
    }
    
    func enhancementRequest(text: String, context: String, apiKey: String) throws -> URLRequest {
        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messages = [
            [
                "role": "user",
                "content": ElsonPromptCatalog.looseEnhancementUserPrompt(
                    text: text,
                    context: context
                )
            ]
        ]
        
        let requestBody = [
            "model": enhancementModel,
            "messages": messages,
            "temperature": 0.2,
            "top_p": 1
        ] as [String: Any]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        return request
    }
    
    func validationRequest(apiKey: String) throws -> URLRequest {
        let url = URL(string: "\(baseURL)/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }
    
    func parseTranscriptionResponse(data: Data) throws -> String {
        let payload = try JSONDecoder().decode(GroqTranscriptionPayload.self, from: data)
        return GroqTranscriptionSanitizer.sanitize(payload).text
    }
    
    func parseEnhancementResponse(data: Data) throws -> String {
        struct ChatResponse: Codable {
            let choices: [ChatChoice]
        }
        
        struct ChatChoice: Codable {
            let message: ChatMessage
        }
        
        struct ChatMessage: Codable {
            let content: String
        }
        
        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let messageContent = chatResponse.choices.first?.message.content else {
            throw APIError.noResponse
        }
        
        return messageContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func parseValidationResponse(data: Data) throws -> Bool {
        struct ModelsResponse: Codable {
            struct Model: Codable {
                let id: String
            }

            let data: [Model]
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return !decoded.data.isEmpty
    }
}

// MARK: - Google Configuration

struct GoogleConfig: ProviderConfig {
    let provider: APIProvider = .google
    let baseURL: String = "https://generativelanguage.googleapis.com/v1beta"
    var transcriptionModel: String { ModelConfig.shared.config.google.transcription }
    var enhancementModel: String { ModelConfig.shared.config.google.enhancement }
    var visionModel: String { ModelConfig.shared.config.google.vision }
    var validationModel: String { ModelConfig.shared.config.google.validation }
    
    func transcriptionRequest(audioURL: URL, apiKey: String) throws -> URLRequest {
        // Google uses a 2-step process: upload file, then transcribe
        // This is handled in a custom implementation
        throw APIError.encodingError("Google transcription requires custom file upload handling")
    }
    
    func enhancementRequest(text: String, context: String, apiKey: String) throws -> URLRequest {
        let url = URL(string: "\(baseURL)/models/\(enhancementModel):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody = [
            "contents": [
                [
                    "parts": [
                        [
                            "text": ElsonPromptCatalog.looseEnhancementUserPrompt(
                                text: text,
                                context: context
                            )
                        ]
                    ]
                ]
            ]
        ] as [String: Any]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        return request
    }
    
    func validationRequest(apiKey: String) throws -> URLRequest {
        let url = URL(string: "\(baseURL)/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }
    
    func parseTranscriptionResponse(data: Data) throws -> String {
        struct GoogleResponse: Codable {
            let candidates: [Candidate]
        }
        
        struct Candidate: Codable {
            let content: Content
        }
        
        struct Content: Codable {
            let parts: [Part]
        }
        
        struct Part: Codable {
            let text: String
        }
        
        let response = try JSONDecoder().decode(GoogleResponse.self, from: data)
        guard let text = response.candidates.first?.content.parts.first?.text else {
            throw APIError.noResponse
        }
        return text
    }
    
    func parseEnhancementResponse(data: Data) throws -> String {
        struct GoogleResponse: Codable {
            let candidates: [Candidate]
        }
        
        struct Candidate: Codable {
            let content: Content
        }
        
        struct Content: Codable {
            let parts: [Part]
        }
        
        struct Part: Codable {
            let text: String
        }
        
        let response = try JSONDecoder().decode(GoogleResponse.self, from: data)
        guard let text = response.candidates.first?.content.parts.first?.text else {
            throw APIError.noResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func parseValidationResponse(data: Data) throws -> Bool {
        struct ModelsResponse: Codable {
            struct Model: Codable {
                let name: String
            }

            let models: [Model]
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return !decoded.models.isEmpty
    }
    
    // MARK: - Custom Google Methods
    
    func uploadFileForTranscription(audioURL: URL, apiKey: String) async throws -> String {
        let audioData = try Data(contentsOf: audioURL)
        let mimeType = "audio/m4a" // Assuming m4a format
        let numBytes = audioData.count

        let uploadURL = URL(string: "\(baseURL.replacingOccurrences(of: "v1beta", with: "upload/v1beta"))/files")!
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        uploadRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        uploadRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.setValue("\(numBytes)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        uploadRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        uploadRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let metadata = ["file": ["display_name": "AUDIO"]]
        uploadRequest.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (uploadData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
        guard let httpUploadResponse = uploadResponse as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(httpUploadResponse.statusCode) else {
            let errorText = String(data: uploadData, encoding: .utf8) ?? "Unknown error"
            throw APIError.apiError(httpUploadResponse.statusCode, errorText)
        }
        guard let uploadURLString = httpUploadResponse.value(forHTTPHeaderField: "x-goog-upload-url") else {
            let errorText = String(data: uploadData, encoding: .utf8) ?? "Missing x-goog-upload-url"
            throw APIError.apiError(httpUploadResponse.statusCode, errorText)
        }

        let fileUploadURL = URL(string: uploadURLString)!
        var fileRequest = URLRequest(url: fileUploadURL)
        fileRequest.httpMethod = "POST"
        fileRequest.setValue("\(numBytes)", forHTTPHeaderField: "Content-Length")
        fileRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        fileRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        fileRequest.httpBody = audioData

        let (fileData, fileResponse) = try await URLSession.shared.data(for: fileRequest)
        guard let httpFileResponse = fileResponse as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(httpFileResponse.statusCode) else {
            let errorText = String(data: fileData, encoding: .utf8) ?? "Unknown error"
            throw APIError.apiError(httpFileResponse.statusCode, errorText)
        }

        struct FileUploadResponse: Codable {
            let file: FileInfo
        }

        struct FileInfo: Codable {
            let uri: String
        }

        let decoded = try JSONDecoder().decode(FileUploadResponse.self, from: fileData)
        return decoded.file.uri
    }

    
    func transcribeWithFileURI(_ fileURI: String, apiKey: String) async throws -> String {
        let url = URL(string: "\(baseURL)/models/\(transcriptionModel):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody = [
            "contents": [
                [
                    "parts": [
                        [
                            "text": "Transcribe this audio clip"
                        ],
                        [
                            "file_data": [
                                "mime_type": "audio/m4a",
                                "file_uri": fileURI
                            ]
                        ]
                    ]
                ]
            ]
        ] as [String: Any]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.apiError(httpResponse.statusCode, errorText)
        }
        
        return try parseTranscriptionResponse(data: data)
    }
}

// MARK: - Provider Factory

struct ProviderConfigFactory {
    static func create(_ provider: APIProvider) -> ProviderConfig {
        switch provider {
        case .openai:
            return OpenAIConfig()
        case .groq:
            return GroqConfig()
        case .google:
            return GoogleConfig()
        }
    }
}

// MARK: - Error Types

enum APIError: Error, LocalizedError {
    case invalidProvider
    case missingAPIKey
    case cloudModeRequiresEEBuild
    case cloudAgentRequired
    case invalidResponse
    case apiError(Int, String)
    case fileError(String)
    case encodingError(String)
    case decodingError(String)
    case noResponse
    
    var errorDescription: String? {
        switch self {
        case .invalidProvider:
            return "Invalid API provider selected"
        case .missingAPIKey:
            return "API key is missing"
        case .cloudModeRequiresEEBuild:
            return "Cloud mode is not available."
        case .cloudAgentRequired:
            return "Agent mode is available in Cloud Mode only"
        case .invalidResponse:
            return "Invalid response from API"
        case .apiError(let code, let message):
            return "API Error (\(code)): \(message)"
        case .fileError(let error):
            return "File error: \(error)"
        case .encodingError(let error):
            return "Encoding error: \(error)"
        case .decodingError(let error):
            return "Decoding error: \(error)"
        case .noResponse:
            return "No response received from API"
        }
    }
}
