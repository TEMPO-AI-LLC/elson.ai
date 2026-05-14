import Foundation
import XCTest
@testable import Elson

final class PromptLearningTests: XCTestCase {
    func testNormalizedPromptLearningResultAllowsTranscriptUpdate() {
        let payload = """
        {
          "decision": "update_transcript_prompt",
          "updated_prompt": "new transcript prompt",
          "reason": "feedback indicates over-interpretation"
        }
        """

        let result = LocalAIService().normalizedPromptLearningResult(
            from: Data(payload.utf8)
        )

        XCTAssertEqual(result.decision, .updateTranscriptPrompt)
        XCTAssertEqual(result.updatedPrompt, "new transcript prompt")
    }

    func testNormalizedPromptLearningResultAllowsWorkingAgentUpdate() {
        let payload = """
        {
          "decision": "update_working_agent_prompt",
          "updated_prompt": "new working prompt",
          "reason": "agent should answer directly"
        }
        """

        let result = LocalAIService().normalizedPromptLearningResult(
            from: Data(payload.utf8)
        )

        XCTAssertEqual(result.decision, .updateWorkingAgentPrompt)
        XCTAssertEqual(result.updatedPrompt, "new working prompt")
    }

    func testNormalizedPromptLearningResultFallsBackToNoLearningWithoutPrompt() {
        let payload = """
        {
          "decision": "update_transcript_prompt",
          "updated_prompt": null,
          "reason": "not enough signal"
        }
        """

        let result = LocalAIService().normalizedPromptLearningResult(
            from: Data(payload.utf8)
        )

        XCTAssertEqual(result.decision, .noLearning)
        XCTAssertNil(result.updatedPrompt)
    }

    func testFeedbackSubjectDerivedFromLastOutputSnapshot() {
        let snapshot = LastOutputSnapshot(
            processedText: "cleaned text",
            rawTranscript: "raw text",
            replyMode: "reply",
            sourceSurface: "chat",
            requestId: "req-1",
            threadId: "thread-1",
            actualRoute: "full_agent",
            routingSource: "explicit_mode",
            forcedRouteReason: nil,
            debugReason: "debug",
            visibleOutputSource: "working_agent_path",
            hasScreenContext: true
        )

        let subject = snapshot.feedbackSubject

        XCTAssertEqual(subject.requestId, "req-1")
        XCTAssertEqual(subject.actualRoute, "full_agent")
        XCTAssertEqual(subject.processedText, "cleaned text")
        XCTAssertEqual(subject.rawTranscript, "raw text")
    }
}
