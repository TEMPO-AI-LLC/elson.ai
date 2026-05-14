import Foundation

struct LocalDirectTransport: RuntimeTransport {
    func send(_ request: ElsonRequestEnvelope, config: ElsonLocalConfig) async throws -> ElsonResponseEnvelope {
        let formatted = try await LocalProcessingRouter.runTranscriptAgent(
            request: request,
            config: config,
            hostedProvider: .cerebras
        )

        return ElsonResponseEnvelope(
            replyMode: "transcript",
            displayText: formatted,
            clipboardText: formatted,
            actions: [],
            requiresConfirmation: false,
            threadReset: false,
            debugReason: "Transcript Agent direct transcript.",
            threadId: request.threadId,
            messageId: nil,
            sessionKey: nil,
            updatedMyElsonMarkdown: nil
        )
    }
}
