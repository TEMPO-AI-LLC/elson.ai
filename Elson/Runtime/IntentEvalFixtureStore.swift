import Foundation

struct IntentEvalFixtureAttachmentManifest: Codable, Sendable {
    let kind: String
    let name: String
    let mime: String
    let source: String
    let relativePath: String?
    let byteCount: Int?
    let saved: Bool

    enum CodingKeys: String, CodingKey {
        case kind
        case name
        case mime
        case source
        case relativePath = "relative_path"
        case byteCount = "byte_count"
        case saved
    }
}

struct IntentEvalFixtureManifest: Codable, Sendable {
    let schemaVersion: Int
    let id: String
    let createdAt: String
    let surface: String
    let inputSource: String
    let modeHint: String
    let expectedRoute: String?
    let expectedThreadDecision: String?
    let expectedReplyRelation: String?
    let rawTranscript: String?
    let conversationHistory: [ElsonConversationTurnPayload]
    let clipboardText: String?
    let screenText: String?
    let screenDescription: String?
    let appContext: ElsonAppContextPayload
    let continuationContext: ElsonContinuationContextPayload?
    let myElsonMarkdown: String
    let intentAgentPrompt: String
    let transcriptAgentPrompt: String
    let workingAgentPrompt: String
    let systemPrompt: String
    let userPrompt: String
    let audioDeciderProvider: String
    let model: String
    let temperature: Double?
    let topP: Double?
    let topK: Int?
    let thinkingLevel: String?
    let fullAgentAllowed: Bool
    let providerAPIURL: String
    let requestPayloadRelativePath: String?
    let attachments: [IntentEvalFixtureAttachmentManifest]
    let hasRealAttachments: Bool
    let fixtureCompleteness: String
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case createdAt = "created_at"
        case surface
        case inputSource = "input_source"
        case modeHint = "mode_hint"
        case expectedRoute = "expected_route"
        case expectedThreadDecision = "expected_thread_decision"
        case expectedReplyRelation = "expected_reply_relation"
        case rawTranscript = "raw_transcript"
        case conversationHistory = "conversation_history"
        case clipboardText = "clipboard_text"
        case screenText = "screen_text"
        case screenDescription = "screen_description"
        case appContext = "app_context"
        case continuationContext = "continuation_context"
        case myElsonMarkdown = "my_elson_markdown"
        case intentAgentPrompt = "intent_agent_prompt"
        case transcriptAgentPrompt = "transcript_agent_prompt"
        case workingAgentPrompt = "working_agent_prompt"
        case systemPrompt = "system_prompt"
        case userPrompt = "user_prompt"
        case audioDeciderProvider = "audio_decider_provider"
        case model
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case thinkingLevel = "thinking_level"
        case fullAgentAllowed = "full_agent_allowed"
        case providerAPIURL = "provider_api_url"
        case requestPayloadRelativePath = "request_payload_relative_path"
        case attachments
        case hasRealAttachments = "has_real_attachments"
        case fixtureCompleteness = "fixture_completeness"
        case notes
    }
}

actor IntentEvalFixtureStore {
    static let shared = IntentEvalFixtureStore()

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func captureIntentFixture(
        envelope: ElsonRequestEnvelope,
        provider: LocalModelProvider,
        stage: ModelStageConfig,
        allowFullAgent: Bool,
        systemPrompt: String,
        userPrompt: String,
        requestPayloadData: Data,
        providerAPIURL: String
    ) {
        do {
            let fixtureDirectory = fixtureDirectoryURL(for: envelope)
            let attachmentsDirectory = fixtureDirectory.appendingPathComponent("attachments", isDirectory: true)
            try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)

            let attachmentManifests = try saveAttachments(
                envelope.attachments,
                into: attachmentsDirectory
            )
            let requestPayloadPath = fixtureDirectory.appendingPathComponent("request-payload.json")
            try requestPayloadData.write(to: requestPayloadPath, options: [.atomic])

            let hasRealAttachments = attachmentManifests.contains { $0.saved && $0.relativePath != nil }
            let fixtureCompleteness = attachmentManifests.contains(where: { !$0.saved })
                ? "partial"
                : "complete"

            let manifest = IntentEvalFixtureManifest(
                schemaVersion: 3,
                id: envelope.requestId,
                createdAt: envelope.timestamps.capturedAt,
                surface: envelope.surface,
                inputSource: envelope.inputSource,
                modeHint: envelope.modeHint,
                expectedRoute: nil,
                expectedThreadDecision: nil,
                expectedReplyRelation: nil,
                rawTranscript: envelope.rawTranscript,
                conversationHistory: envelope.conversationHistory,
                clipboardText: envelope.clipboardText,
                screenText: envelope.screenContext.screenText,
                screenDescription: envelope.screenContext.screenDescription,
                appContext: envelope.appContext,
                continuationContext: envelope.continuationContext,
                myElsonMarkdown: envelope.myElsonMarkdown,
                intentAgentPrompt: envelope.intentAgentPrompt,
                transcriptAgentPrompt: envelope.transcriptAgentPrompt,
                workingAgentPrompt: envelope.workingAgentPrompt,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                audioDeciderProvider: provider.rawValue,
                model: stage.model,
                temperature: stage.temperature,
                topP: stage.topP,
                topK: stage.topK,
                thinkingLevel: stage.thinkingLevel,
                fullAgentAllowed: allowFullAgent,
                providerAPIURL: providerAPIURL,
                requestPayloadRelativePath: "request-payload.json",
                attachments: attachmentManifests,
                hasRealAttachments: hasRealAttachments,
                fixtureCompleteness: fixtureCompleteness,
                notes: nil
            )

            let manifestURL = fixtureDirectory.appendingPathComponent("manifest.json")
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: manifestURL, options: [.atomic])

            DebugLog.runtime(
                "intent_eval_fixture_saved request_id=\(envelope.requestId) provider=\(provider.rawValue) fixture_path=\(fixtureDirectory.path) attachments=\(attachmentManifests.count) completeness=\(fixtureCompleteness)"
            )
        } catch {
            DebugLog.runtimeError(
                "intent_eval_fixture_save_failed request_id=\(envelope.requestId) provider=\(provider.rawValue) error=\(error.localizedDescription)"
            )
        }
    }

    private func fixtureDirectoryURL(for envelope: ElsonRequestEnvelope) -> URL {
        let datePrefix = String(envelope.timestamps.capturedAt.prefix(10))
        return fixtureRootURL()
            .appendingPathComponent(datePrefix, isDirectory: true)
            .appendingPathComponent(envelope.requestId, isDirectory: true)
    }

    private func fixtureRootURL() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("Evals", isDirectory: true)
            .appendingPathComponent("intent-fixtures", isDirectory: true)
    }

    private func saveAttachments(
        _ attachments: [ElsonAttachmentPayload],
        into directory: URL
    ) throws -> [IntentEvalFixtureAttachmentManifest] {
        try attachments.enumerated().map { index, attachment in
            guard let data = decodeDataRef(attachment.dataRef) else {
                return IntentEvalFixtureAttachmentManifest(
                    kind: attachment.kind,
                    name: attachment.name,
                    mime: attachment.mime,
                    source: attachment.source,
                    relativePath: nil,
                    byteCount: nil,
                    saved: false
                )
            }

            let filename = uniqueAttachmentFilename(
                for: attachment,
                index: index + 1
            )
            let relativePath = "attachments/\(filename)"
            let destination = directory.appendingPathComponent(filename)
            try data.write(to: destination, options: [.atomic])

            return IntentEvalFixtureAttachmentManifest(
                kind: attachment.kind,
                name: attachment.name,
                mime: attachment.mime,
                source: attachment.source,
                relativePath: relativePath,
                byteCount: data.count,
                saved: true
            )
        }
    }

    private func uniqueAttachmentFilename(
        for attachment: ElsonAttachmentPayload,
        index: Int
    ) -> String {
        let rawBase = URL(fileURLWithPath: attachment.name).deletingPathExtension().lastPathComponent
        let base = nonEmpty(sanitizeFilename(rawBase)) ?? "attachment-\(index)"
        let ext = nonEmpty(URL(fileURLWithPath: attachment.name).pathExtension)
            ?? defaultExtension(for: attachment.mime)
            ?? "bin"
        return "\(index)-\(base).\(ext)"
    }

    private func sanitizeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed
    }

    private func defaultExtension(for mime: String) -> String? {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        case "image/heic":
            return "heic"
        case "application/pdf":
            return "pdf"
        case "text/plain":
            return "txt"
        default:
            return mime.lowercased().split(separator: "/").last.map(String.init)
        }
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func decodeDataRef(_ dataRef: String) -> Data? {
        guard let separator = dataRef.range(of: "base64,") else {
            return nil
        }
        return Data(base64Encoded: String(dataRef[separator.upperBound...]))
    }
}
