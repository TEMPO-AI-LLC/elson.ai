import Foundation
import XCTest
@testable import Elson

final class LocalProcessingModeTests: XCTestCase {
    private var tempDirectory: URL!
    private var savedDefaults: [String: Any?] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("elson-local-processing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        ElsonLocalConfigStore.setTestingOverrides(
            appSupportConfigURL: tempDirectory.appendingPathComponent("local-config.json"),
            workspaceFolderURL: tempDirectory.appendingPathComponent("workspace", isDirectory: true)
        )

        let keys = [
            "runtime_mode",
            "did_complete_onboarding",
            "completed_onboarding_app_version",
            "did_complete_interaction_model_onboarding",
            "did_complete_processing_onboarding",
            "local_processor_model_id",
            "local_processor_warmup_in_flight_model_id",
            "did_complete_folder_onboarding",
            "did_complete_transcript_shortcut_onboarding",
            "did_complete_agent_shortcut_onboarding",
        ]
        savedDefaults = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDownWithError() throws {
        for (key, value) in savedDefaults {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        ElsonLocalConfigStore.clearTestingOverrides()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testOnboardingProcessingRequirementsAreModeSpecific() {
        let settings = AppSettings()
        settings.didCompleteInteractionModelOnboarding = true
        settings.groqAPIKey = ""
        settings.cerebrasAPIKey = ""
        settings.geminiAPIKey = ""

        settings.runtimeMode = .local
        settings.didCompleteProcessingOnboarding = true
        XCTAssertTrue(settings.hasRequiredAPIKeys)
        XCTAssertEqual(settings.firstIncompleteInstallOnboardingStep, .apiKeys)

        settings.runtimeMode = .hosted
        XCTAssertFalse(settings.hasRequiredAPIKeys)
        XCTAssertEqual(settings.firstIncompleteInstallOnboardingStep, .apiKeys)

        settings.groqAPIKey = "groq"
        settings.cerebrasAPIKey = "cerebras"
        settings.geminiAPIKey = "gemini"
        XCTAssertTrue(settings.hasRequiredAPIKeys)
        XCTAssertNotEqual(settings.firstIncompleteInstallOnboardingStep, .apiKeys)
    }

    @MainActor
    func testMakeLocalConfigPersistsRuntimeMode() {
        let settings = AppSettings()
        settings.runtimeMode = .hosted

        XCTAssertEqual(settings.makeLocalConfig().runtimeMode, .hosted)
        XCTAssertEqual(
            ElsonLocalConfigStore.shared.load(includeWorkingDirectorySources: false).runtimeMode,
            .hosted
        )
    }

    func testLocalAndCloudRoutesSelectExpectedBackends() {
        var localConfig = ElsonLocalConfig.default
        localConfig.runtimeMode = .local
        XCTAssertEqual(LocalProcessingRouter.audioBackend(for: localConfig), .fluidAudio)
        XCTAssertEqual(LocalProcessingRouter.llmBackend(for: localConfig), .gemma4Swift)
        XCTAssertTrue(LocalProcessingRouter.audioTranscriber(for: localConfig) is FluidAudioTranscriber)

        var hostedConfig = ElsonLocalConfig.default
        hostedConfig.runtimeMode = .hosted
        XCTAssertEqual(LocalProcessingRouter.audioBackend(for: hostedConfig), .groq)
        XCTAssertEqual(LocalProcessingRouter.llmBackend(for: hostedConfig), .hostedProviders)
        XCTAssertTrue(LocalProcessingRouter.audioTranscriber(for: hostedConfig) is LocalAIService)
    }

    func testProcessingProfilesKeepLocalEnhancerTextOnlyAndAgentMultimodal() {
        let localTranscript = LocalProcessingRouter.contextProfile(runtimeMode: .local, mode: .transcription)
        XCTAssertFalse(localTranscript.shouldPrefetchScreenContext)
        XCTAssertFalse(localTranscript.shouldResolveScreenContext(for: .transcriptEnhancer))
        XCTAssertFalse(localTranscript.shouldPassImagesToTranscriptEnhancer)

        let localAgent = LocalProcessingRouter.contextProfile(runtimeMode: .local, mode: .agent)
        XCTAssertTrue(localAgent.shouldPrefetchScreenContext)
        XCTAssertTrue(localAgent.shouldResolveScreenContext(for: .workingAgent))
        XCTAssertTrue(localAgent.shouldPassImagesToWorkingAgent)

        let hostedTranscript = LocalProcessingRouter.contextProfile(runtimeMode: .hosted, mode: .transcription)
        XCTAssertTrue(hostedTranscript.shouldPrefetchScreenContext)
        XCTAssertTrue(hostedTranscript.shouldResolveScreenContext(for: .transcriptEnhancer))
        XCTAssertTrue(hostedTranscript.shouldPassImagesToTranscriptEnhancer)
    }

    func testLocalTranscriptEnhancerRequestStripsContext() {
        let request = makeEnvelope()
        let localRequest = LocalProcessingRouter.localTranscriptEnhancerRequest(from: request)

        XCTAssertEqual(localRequest.rawTranscript, request.rawTranscript)
        XCTAssertEqual(localRequest.enhancedTranscript, request.enhancedTranscript)
        XCTAssertTrue(localRequest.attachments.isEmpty)
        XCTAssertTrue(localRequest.conversationHistory.isEmpty)
        XCTAssertFalse(localRequest.screenContext.hasScreenContext)
        XCTAssertNil(localRequest.screenContext.screenText)
        XCTAssertNil(localRequest.clipboardText)
        XCTAssertEqual(localRequest.myElsonMarkdown, "")
        XCTAssertEqual(localRequest.transcriptAgentPrompt, "")
    }

    func testLocalGemmaTranscriptEnhancerPromptIsShortAndTranscriptOnly() {
        let prompt = LocalGemmaPromptBuilder.transcriptEnhancerPrompt(transcript: "  Hallo Welt  ")

        XCTAssertEqual(prompt.userPrompt, "Hallo Welt")
        XCTAssertLessThan(prompt.systemPrompt.count, 100)
        XCTAssertFalse(prompt.systemPrompt.localizedCaseInsensitiveContains("screen"))
        XCTAssertFalse(prompt.systemPrompt.localizedCaseInsensitiveContains("image"))
        XCTAssertGreaterThanOrEqual(prompt.maxTokens, 180)
    }

    func testRuntimeModeCodableRoundTrip() throws {
        var config = ElsonLocalConfig.default
        config.runtimeMode = .hosted

        let decoded = try JSONDecoder().decode(
            ElsonLocalConfig.self,
            from: JSONEncoder().encode(config)
        )

        XCTAssertEqual(decoded.runtimeMode, .hosted)
    }

    func testGemmaWorkingAgentJSONNormalizationRemainsCompatible() throws {
        let output = """
        <|channel|>thought<|message|>internal<|end|>
        {
          "outcome_type": "reply",
          "reply_text": " Done ",
          "local_actions": [
            { "type": "paste_text", "text": "Paste me" }
          ],
          "reason": "Gemma JSON"
        }
        """

        let service = LocalAIService()
        let jsonData = try XCTUnwrap(service.extractJSONData(from: output))
        let decision = service.normalizedAgentDecision(from: jsonData)

        XCTAssertEqual(decision.outcomeType, .reply)
        XCTAssertEqual(decision.replyText, "Done")
        XCTAssertEqual(decision.localActions.first?.type, "paste_text")
        XCTAssertEqual(decision.localActions.first?.text, "Paste me")
        XCTAssertEqual(decision.reason, "Gemma JSON")
    }

    private func makeEnvelope() -> ElsonRequestEnvelope {
        ElsonRequestEnvelope(
            requestId: "request",
            threadId: "thread",
            surface: "chat",
            inputSource: "audio",
            modeHint: InteractionMode.transcription.rawValue,
            rawTranscript: "raw transcript",
            enhancedTranscript: "raw transcript",
            transcriptSnippetCount: 1,
            transcriptChunkTimings: [],
            myElsonMarkdown: "memory",
            transcriptAgentPrompt: "cloud prompt",
            workingAgentPrompt: "agent prompt",
            selectionNote: "selection",
            clipboardText: "clipboard",
            attachments: [
                ElsonAttachmentPayload(
                    kind: "image",
                    name: "screen.jpg",
                    mime: "image/jpeg",
                    source: "auto",
                    dataRef: "data:image/jpeg;base64,abc"
                ),
            ],
            conversationHistory: [
                ElsonConversationTurnPayload(role: .user, content: "previous"),
            ],
            screenContext: ElsonScreenContextPayload(
                hasScreenContext: true,
                screenText: "screen text",
                screenDescription: "screen description"
            ),
            timestamps: ElsonTimestampsPayload(
                capturedAt: "2026-05-14T12:00:00Z",
                selectionNoteAt: nil,
                clipboardAt: nil,
                attachmentsAt: nil
            ),
            appContext: ElsonAppContextPayload(
                frontmostAppName: "Safari",
                frontmostAppBundleId: "com.apple.Safari",
                frontmostWindowTitle: "Example"
            ),
            continuationContext: nil,
            systemContext: ElsonSystemContextPayload(
                localDateTime: "2026-05-14 12:00:00",
                localDate: "2026-05-14",
                localTime: "12:00:00",
                timezone: "Europe/Amsterdam"
            ),
            selectedSkill: nil
        )
    }
}
