import Foundation

struct WorkingAgentTransport: RuntimeTransport {
    func send(_ request: ElsonRequestEnvelope, config: ElsonLocalConfig) async throws -> ElsonResponseEnvelope {
        let decision = try await LocalAIService().runWorkingAgent(
            request: request,
            provider: .google,
            cerebrasAPIKey: config.cerebrasAPIKey,
            geminiAPIKey: config.geminiAPIKey
        )

        let updatedMyElsonMarkdown: String? = {
            guard let patch = decision.myElsonPatch, !patch.isEmpty else { return nil }
            let current = MyElsonDocument.normalizedMarkdown(from: request.myElsonMarkdown)
            let merged = MyElsonDocument(markdown: current).merged(with: patch).renderedMarkdown
            return merged == current ? nil : merged
        }()

        let displayText = defaultDisplayText(for: decision, fallbackTranscript: request.enhancedTranscript)
        let clipboardText = clipboardText(for: decision, displayText: displayText)
        let actions = decision.localActions.map { action in
            var args: [String: String] = [:]
            if let text = action.text {
                args["text"] = text
            }
            return ElsonAction(type: action.type, args: args)
        }

        return ElsonResponseEnvelope(
            replyMode: decision.outcomeType.rawValue,
            displayText: displayText,
            clipboardText: clipboardText,
            actions: actions,
            requiresConfirmation: false,
            threadReset: false,
            debugReason: decision.reason,
            threadId: request.threadId,
            messageId: nil,
            sessionKey: nil,
            updatedMyElsonMarkdown: updatedMyElsonMarkdown
        )
    }

    private func defaultDisplayText(for decision: AgentDecision, fallbackTranscript: String) -> String {
        let trimmed = decision.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        switch decision.outcomeType {
        case .transcript:
            let fallback = fallbackTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? "OK" : fallback
        case .reply:
            return "OK"
        case .note:
            return "Noted."
        case .reminder:
            return "Reminder saved."
        case .myElsonUpdate:
            return "Updated MyElson."
        }
    }

    private func clipboardText(for decision: AgentDecision, displayText: String) -> String {
        let explicitPasteText = decision.localActions
            .first(where: { $0.type == "paste_text" })?
            .text?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !explicitPasteText.isEmpty {
            return explicitPasteText
        }

        switch decision.outcomeType {
        case .transcript:
            let finalizedText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            return finalizedText == "OK" ? "" : finalizedText
        case .reply:
            let replyText = decision.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !replyText.isEmpty {
                return replyText
            }
            let fallback = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback == "OK" ? "" : fallback
        case .note, .reminder, .myElsonUpdate:
            return ""
        }
    }
}
