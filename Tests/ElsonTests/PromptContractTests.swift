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

    func testLocalEnhancerPromptLoadsFromPromptConfig() {
        let prompt = LocalTranscriptEnhancerPromptBuilder.transcriptEnhancerPrompt(transcript: "  Hallo Welt  ")

        XCTAssertEqual(
            prompt.systemPrompt,
            PromptConfig.shared.string("local_gemma_transcript_enhancer_system_prompt")
        )
        XCTAssertEqual(prompt.userPrompt, "Hallo Welt")
        XCTAssertLessThan(prompt.systemPrompt.count, 100)
        XCTAssertFalse(prompt.systemPrompt.localizedCaseInsensitiveContains("screen"))
        XCTAssertFalse(prompt.systemPrompt.localizedCaseInsensitiveContains("image"))
    }

    func testAPIKeyValidationMessagesLoadFromPromptConfig() {
        let messages = ElsonPromptCatalog.apiKeyValidationMessages()

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.first?["content"], "Reply with exactly OK.")
        XCTAssertEqual(messages.last?["role"], "user")
        XCTAssertEqual(messages.last?["content"], "Respond with OK.")
    }

    func testRuntimePromptInstructionsStayOutOfSwiftSources() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let checkedFiles = [
            "Elson/Runtime/ElsonPromptCatalog.swift",
            "Elson/Runtime/LocalProcessingServices.swift",
            "Elson/Runtime/LocalAIService.swift",
        ]
        let forbiddenPhrases = [
            "Clean up this transcript. Preserve language",
            "You improve Elson.ai prompts from user feedback.",
            "You write ultra-short history card titles",
            "Extract OCR-style text and a concise scene description",
            "Transcribe the audio first, then clean the transcript faithfully.",
            "Reply with exactly OK.",
            "Respond with OK.",
        ]

        for relativePath in checkedFiles {
            let contents = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for phrase in forbiddenPhrases {
                XCTAssertFalse(contents.contains(phrase), "\(relativePath) hardcodes prompt phrase: \(phrase)")
            }
        }
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
