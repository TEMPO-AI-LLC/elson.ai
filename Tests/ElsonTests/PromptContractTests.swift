import XCTest
@testable import Elson

final class PromptContractTests: XCTestCase {
    func testTranscriptPromptRemovesKnownOverdirectivePhrases() {
        let prompt = ElsonPromptCatalog.defaultTranscriptAgentPrompt.lowercased()

        XCTAssertFalse(prompt.contains("business-ready"))
        XCTAssertFalse(prompt.contains("make implicit lists explicit"))
        XCTAssertFalse(prompt.contains("separate context from request"))
        XCTAssertFalse(prompt.contains("reply draft"))
        XCTAssertFalse(prompt.contains("draft replies"))
        XCTAssertFalse(prompt.contains("drafted text"))
        XCTAssertTrue(prompt.contains("return only the final text"))
        XCTAssertTrue(prompt.contains("apply spoken self-corrections strictly"))
        XCTAssertTrue(prompt.contains("do not add bullets"))
        XCTAssertTrue(prompt.contains("treat screen and attachment context as spelling and disambiguation support"))
    }

    func testWorkingAgentPromptIsAnswerActionFirst() {
        let prompt = ElsonPromptCatalog.workingAgentSystemPrompt(
            workingAgentPrompt: ElsonPromptCatalog.defaultWorkingAgentPrompt,
            includeConversationHistory: false
        ).lowercased()

        XCTAssertTrue(prompt.contains("bounded local executor"))
        XCTAssertTrue(prompt.contains("supported outcomes"))
        XCTAssertTrue(prompt.contains("use `reply`"))
        XCTAssertTrue(prompt.contains("use `transcript` only when no supported working-agent capability fits"))
        XCTAssertTrue(prompt.contains("relevant clipboard material"))
        XCTAssertTrue(prompt.contains("placeholder instructions"))
        XCTAssertTrue(prompt.contains("current-turn reply work"))
    }

    func testEnhancementPromptsNoLongerInheritIntentPromptLanguage() {
        let structured = ElsonPromptCatalog.structuredEnhancementSystemPrompt(context: "test").lowercased()
        let combined = ElsonPromptCatalog.googleCombinedTranscriptionSystemInstruction().lowercased()

        XCTAssertFalse(structured.contains("intent agent"))
        XCTAssertFalse(combined.contains("intent agent"))
        XCTAssertTrue(structured.contains("faithful transcript cleanup assistant"))
        XCTAssertTrue(combined.contains("faithful cleanup assistant"))
        XCTAssertFalse(structured.contains("draft"))
        XCTAssertFalse(combined.contains("draft"))
    }

    func testPromptLearningPromptIncludesBothPromptSurfacesAndFeedback() {
        let feedbackEntry = FeedbackEntry(
            rating: .bad,
            note: "Too opinionated",
            expectedRouteOverride: "direct_transcript",
            actualRoute: "full_agent",
            requestId: "req-1",
            threadId: "thread-1",
            createdAt: .init(timeIntervalSince1970: 10),
            rawTranscript: "analyse this",
            processedText: "Here is a very specific audit",
            replyMode: "reply",
            sourceSurface: "chat"
        )
        let subject = FeedbackSubject(
            requestId: "req-1",
            threadId: "thread-1",
            rawTranscript: "analyse this",
            processedText: "Here is a very specific audit",
            replyMode: "reply",
            actualRoute: "full_agent",
            sourceSurface: "chat",
            routingSource: "explicit_mode",
            forcedRouteReason: nil,
            debugReason: "debug",
            visibleOutputSource: "working_agent_path",
            hasScreenContext: true
        )

        let prompt = ElsonPromptCatalog.promptLearningUserPrompt(
            feedbackEntry: feedbackEntry,
            subject: subject,
            transcriptPrompt: "TRANSCRIPT PROMPT",
            workingAgentPrompt: "WORKING PROMPT"
        )

        XCTAssertTrue(prompt.contains("current_transcript_prompt"))
        XCTAssertTrue(prompt.contains("current_working_agent_prompt"))
        XCTAssertTrue(prompt.contains("Too opinionated"))
        XCTAssertTrue(prompt.contains("full_agent"))
    }
}
