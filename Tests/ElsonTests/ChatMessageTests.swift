import Foundation
import XCTest
@testable import Elson

final class ChatMessageTests: XCTestCase {
    func testChatMessageRoundTripPreservesInsertedText() throws {
        let thread = ChatThread(
            id: "thread-1",
            messages: [
                ChatMessage(
                    role: .assistant,
                    content: "I drafted the reply.",
                    insertedText: "Hello Patricia,\n\nHere is the final email.",
                    feedbackSubject: nil
                )
            ]
        )

        let data = try JSONEncoder().encode(thread)
        let decoded = try JSONDecoder().decode(ChatThread.self, from: data)

        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages.first?.insertedText, "Hello Patricia,\n\nHere is the final email.")
    }

    func testChatMessageDecodeWithoutInsertedTextRemainsBackwardCompatible() throws {
        let payload = """
        {
          "id": "\(UUID().uuidString)",
          "role": "assistant",
          "content": "Legacy message",
          "style": "text",
          "attachments": [],
          "showsAttachmentChip": false
        }
        """

        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(payload.utf8))

        XCTAssertEqual(decoded.content, "Legacy message")
        XCTAssertNil(decoded.insertedText)
    }
}
