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
        XCTAssertEqual(LocalProcessingRouter.llmBackend(for: localConfig), .localModels)
        XCTAssertTrue(LocalProcessingRouter.audioTranscriber(for: localConfig) is FluidAudioTranscriber)
        XCTAssertEqual(LocalProcessorStatus.transcriptEnhancerModel.id, "mlx-community/gemma-4-e2b-it-4bit")
        XCTAssertEqual(LocalProcessorStatus.gemmaModel, .e2b4bit)
        XCTAssertEqual(LocalProcessorStatus.ocrModel.id, "mlx-community/LightOnOCR-1B-1025-4bit")
        XCTAssertEqual(
            LocalProcessorStatus.activeLLMModelIDs,
            [
                LocalProcessorStatus.gemmaModel.rawValue,
                LocalProcessorStatus.ocrModel.id,
            ]
        )
        XCTAssertFalse(LocalProcessorStatus.activeLLMModelIDs.contains("prism-ml/Ternary-Bonsai-8B-mlx-2bit"))
        XCTAssertFalse(LocalProcessorStatus.activeLLMModelIDs.contains("mlx-community/gemma-4-e4b-it-4bit"))
        XCTAssertFalse(LocalProcessorStatus.activeLLMModelIDs.contains("mlx-community/GLM-OCR-8bit"))

        var hostedConfig = ElsonLocalConfig.default
        hostedConfig.runtimeMode = .hosted
        XCTAssertEqual(LocalProcessingRouter.audioBackend(for: hostedConfig), .groq)
        XCTAssertEqual(LocalProcessingRouter.llmBackend(for: hostedConfig), .hostedProviders)
        XCTAssertTrue(LocalProcessingRouter.audioTranscriber(for: hostedConfig) is LocalAIService)
    }

    func testProcessingProfilesKeepLocalEnhancerOCRTextAndAgentMultimodal() {
        let localTranscript = LocalProcessingRouter.contextProfile(runtimeMode: .local, mode: .transcription)
        XCTAssertTrue(localTranscript.shouldPrefetchScreenContext)
        XCTAssertTrue(localTranscript.shouldResolveScreenContext(for: .transcriptEnhancer))
        XCTAssertTrue(localTranscript.shouldResolveScreenContext(for: .shortcutPrefetch))
        XCTAssertFalse(localTranscript.shouldPassImagesToTranscriptEnhancer)
        XCTAssertEqual(localTranscript.transcriptEnhancerProfileName, "local_ocr_text")

        let localAgent = LocalProcessingRouter.contextProfile(runtimeMode: .local, mode: .agent)
        XCTAssertTrue(localAgent.shouldPrefetchScreenContext)
        XCTAssertTrue(localAgent.shouldResolveScreenContext(for: .shortcutPrefetch))
        XCTAssertTrue(localAgent.shouldResolveScreenContext(for: .workingAgent))
        XCTAssertTrue(localAgent.shouldPassImagesToWorkingAgent)

        let hostedTranscript = LocalProcessingRouter.contextProfile(runtimeMode: .hosted, mode: .transcription)
        XCTAssertTrue(hostedTranscript.shouldPrefetchScreenContext)
        XCTAssertTrue(hostedTranscript.shouldResolveScreenContext(for: .transcriptEnhancer))
        XCTAssertTrue(hostedTranscript.shouldPassImagesToTranscriptEnhancer)
        XCTAssertEqual(hostedTranscript.transcriptEnhancerProfileName, "cloud_full_context")
    }

    func testLocalCommandWarmupTargetsAreModeSpecific() {
        var localConfig = ElsonLocalConfig.default
        localConfig.runtimeMode = .local

        XCTAssertEqual(
            LocalProcessingRouter.commandWarmupTarget(for: localConfig, mode: .transcription),
            .transcriptEnhancer
        )
        XCTAssertEqual(
            LocalProcessingRouter.commandWarmupTarget(for: localConfig, mode: .agent),
            .workingAgent
        )

        var hostedConfig = ElsonLocalConfig.default
        hostedConfig.runtimeMode = .hosted
        XCTAssertEqual(
            LocalProcessingRouter.commandWarmupTarget(for: hostedConfig, mode: .transcription),
            .none
        )
        XCTAssertEqual(
            LocalProcessingRouter.commandWarmupTarget(for: hostedConfig, mode: .agent),
            .none
        )
    }

    func testLocalTranscriptEnhancerRequestKeepsOCRTextAndStripsHeavyContext() {
        let request = makeEnvelope()
        let localRequest = LocalProcessingRouter.localTranscriptEnhancerRequest(from: request)

        XCTAssertEqual(localRequest.rawTranscript, request.rawTranscript)
        XCTAssertEqual(localRequest.enhancedTranscript, request.enhancedTranscript)
        XCTAssertEqual(localRequest.transcriptSnippetCount, request.transcriptSnippetCount)
        XCTAssertEqual(localRequest.transcriptChunkTimings, request.transcriptChunkTimings)
        XCTAssertNil(localRequest.continuationContext)
        XCTAssertTrue(localRequest.attachments.isEmpty)
        XCTAssertTrue(localRequest.conversationHistory.isEmpty)
        XCTAssertTrue(localRequest.screenContext.hasScreenContext)
        XCTAssertEqual(localRequest.screenContext.screenText, "screen text")
        XCTAssertNil(localRequest.screenContext.screenDescription)
        XCTAssertNil(localRequest.clipboardText)
        XCTAssertEqual(localRequest.myElsonMarkdown, "## Words\n- Teerling\n- Elson.ai")
        XCTAssertEqual(localRequest.transcriptAgentPrompt, "")
    }

    func testLocalTranscriptEnhancerPromptIsShortAndPlainTextWithoutOCR() {
        let prompt = LocalTranscriptEnhancerPromptBuilder.transcriptEnhancerPrompt(transcript: "  raw transcript  ")

        XCTAssertTrue(prompt.userPrompt.contains("raw_transcript:"))
        XCTAssertTrue(prompt.userPrompt.contains("raw transcript"))
        XCTAssertTrue(prompt.systemPrompt.localizedCaseInsensitiveContains("local Transcript assistant"))
        XCTAssertTrue(prompt.systemPrompt.localizedCaseInsensitiveContains("translate"))
        XCTAssertTrue(prompt.systemPrompt.localizedCaseInsensitiveContains("reply, email, or message"))
        XCTAssertTrue(prompt.userPrompt.contains("screen_text:"))
        XCTAssertFalse(prompt.userPrompt.contains("screen_description"))
        XCTAssertGreaterThanOrEqual(prompt.maxTokens, 160)
        XCTAssertLessThanOrEqual(prompt.maxTokens, 900)
    }

    func testLocalTranscriptEnhancerPromptCanCarryOCRRuntimeData() {
        let prompt = LocalTranscriptEnhancerPromptBuilder.transcriptEnhancerPrompt(
            transcript: "  raw transcript  ",
            screenContext: ElsonScreenContextPayload(
                hasScreenContext: true,
                screenText: "visible text",
                screenDescription: "visible layout"
            )
        )

        XCTAssertTrue(prompt.userPrompt.contains("raw_transcript:"))
        XCTAssertTrue(prompt.userPrompt.contains("raw transcript"))
        XCTAssertTrue(prompt.userPrompt.contains("screen_text:"))
        XCTAssertTrue(prompt.userPrompt.contains("visible text"))
        XCTAssertFalse(prompt.userPrompt.contains("screen_description"))
        XCTAssertFalse(prompt.userPrompt.contains("visible layout"))
        XCTAssertLessThanOrEqual(prompt.maxTokens, 900)
    }

    func testLocalTranscriptEnhancerPromptCarriesLeanContext() {
        let request = LocalProcessingRouter.localTranscriptEnhancerRequest(from: makeEnvelope())
        let prompt = LocalTranscriptEnhancerPromptBuilder.transcriptEnhancerPrompt(request: request)

        XCTAssertTrue(prompt.userPrompt.contains("raw_transcript:"))
        XCTAssertTrue(prompt.userPrompt.contains("raw transcript"))
        XCTAssertTrue(prompt.userPrompt.contains("transcript_snippet_count: 1"))
        XCTAssertTrue(prompt.userPrompt.contains("transcript_chunk_timing:"))
        XCTAssertTrue(prompt.userPrompt.contains("chunk 1, snippet 1"))
        XCTAssertTrue(prompt.userPrompt.contains("audio=0-5s"))
        XCTAssertTrue(prompt.userPrompt.contains("local_date_time: 2026-05-14 12:00:00"))
        XCTAssertTrue(prompt.userPrompt.contains("local_date: 2026-05-14"))
        XCTAssertTrue(prompt.userPrompt.contains("local_time: 12:00:00"))
        XCTAssertTrue(prompt.userPrompt.contains("timezone: Europe/Amsterdam"))
        XCTAssertTrue(prompt.userPrompt.contains("words_glossary:"))
        XCTAssertTrue(prompt.userPrompt.contains("Teerling"))
        XCTAssertTrue(prompt.userPrompt.contains("screen_text:"))
        XCTAssertTrue(prompt.userPrompt.contains("screen text"))
        XCTAssertFalse(prompt.userPrompt.contains("screen_description"))
        XCTAssertFalse(prompt.userPrompt.contains("clipboard"))
        XCTAssertFalse(prompt.userPrompt.contains("myelson_markdown"))
        XCTAssertFalse(prompt.userPrompt.contains("attachments:"))
    }

    func testLocalWorkingAgentPromptUsesLeanLocalContext() {
        let prompt = ElsonPromptCatalog.localWorkingAgentUserPrompt(
            envelope: makeEnvelope(),
            attachmentSummary: "image | screen.jpg | image/jpeg | source=auto"
        )

        XCTAssertTrue(prompt.contains("raw_transcript:"))
        XCTAssertTrue(prompt.contains("raw transcript"))
        XCTAssertTrue(prompt.contains("transcript_snippet_count: 1"))
        XCTAssertTrue(prompt.contains("transcript_chunk_timing:"))
        XCTAssertTrue(prompt.contains("chunk 1, snippet 1"))
        XCTAssertTrue(prompt.contains("audio=0-5s"))
        XCTAssertTrue(prompt.contains("local_date_time: 2026-05-14 12:00:00"))
        XCTAssertTrue(prompt.contains("frontmost_app_name: Safari"))
        XCTAssertTrue(prompt.contains("frontmost_app_bundle_id: com.apple.Safari"))
        XCTAssertTrue(prompt.contains("frontmost_window_title: Example"))
        XCTAssertTrue(prompt.contains("words_glossary:"))
        XCTAssertTrue(prompt.contains("clipboard_text:"))
        XCTAssertTrue(prompt.contains("clipboard"))
        XCTAssertTrue(prompt.contains("attachments:"))
        XCTAssertTrue(prompt.contains("image | screen.jpg | image/jpeg | source=auto"))
        XCTAssertTrue(prompt.contains("skills_enabled:"))
        XCTAssertTrue(prompt.contains("myelson_markdown:"))
        XCTAssertFalse(prompt.contains("mode_hint:"))
        XCTAssertFalse(prompt.contains("input_source:"))
        XCTAssertFalse(prompt.contains("screen_text:"))
        XCTAssertFalse(prompt.contains("screen_description:"))
        XCTAssertFalse(prompt.contains("current_transcript:"))
    }

    func testLocalProcessorCopyListsSharedGemmaOnce() {
        let detail = LocalProcessorStatus.current().detail

        XCTAssertEqual(
            detail,
            "FluidAudio v3 auto. Gemma 4 E2B handles Transcript + Agent. LightOnOCR extracts screen text. Total ~4.6 GB."
        )
        XCTAssertEqual(LocalProcessorStatus.sharedGemmaDisplayName, "Gemma 4 E2B (4-bit) (Transcript + Agent)")
        XCTAssertEqual(LocalProcessorStatus.ocrScreenTextDisplayName, "LightOnOCR 1B (4-bit) (screen text)")
    }

    func testDefaultLocalConfigEnablesTranscriptOCR() {
        XCTAssertTrue(ElsonLocalConfig.default.transcriptScreenOCR)
    }

    func testChatMessageRowsDoNotExposeInlineFeedbackControls() throws {
        let componentsSource = try repoSource("Elson/Views/ThreadHistoryComponents.swift")
        let windowSource = try repoSource("Elson/Views/ThreadHistoryWindowView.swift")

        XCTAssertFalse(componentsSource.contains("InlineFeedbackComposer"))
        XCTAssertFalse(componentsSource.contains("MessageFeedbackButton"))
        XCTAssertFalse(componentsSource.contains("onSubmitFeedback"))
        XCTAssertFalse(windowSource.contains("onSubmitFeedback"))
        XCTAssertTrue(try repoSource("Elson/Views/FeedbackPanelView.swift").contains("submitFeedback"))
    }

    func testTranscriptWarmupStartsOCRAndGemmaIndependently() throws {
        let source = try repoSource("Elson/Runtime/LocalProcessingServices.swift")

        XCTAssertTrue(source.contains("async let ocrWarmup"))
        XCTAssertTrue(source.contains("async let gemmaWarmup"))
        XCTAssertTrue(source.contains("stage=lighton_ocr_load_failed continued=true"))
        XCTAssertTrue(source.contains("stage=transcript_llm_load_started"))
    }

    func testEnhancerLogsSplitPrepareAndGenerationTiming() throws {
        let source = try repoSource("Elson/Runtime/LocalProcessingServices.swift")

        XCTAssertTrue(source.contains("total_enhancer_ms"))
        XCTAssertTrue(source.contains("gemma_prepare_wait_ms"))
        XCTAssertTrue(source.contains("gemma_generation_ms"))
        XCTAssertTrue(source.contains("ocr_prepare_wait_ms"))
        XCTAssertTrue(source.contains("ocr_generation_ms"))
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
            transcriptChunkTimings: [
                ElsonTranscriptChunkTimingPayload(
                    index: 0,
                    transcriptSnippetIndex: 0,
                    audioStartSeconds: 0,
                    audioEndSeconds: 5,
                    asrPayloadStartSeconds: 0,
                    asrPayloadEndSeconds: 5,
                    overlapStartSeconds: nil,
                    overlapEndSeconds: nil,
                    overlapDurationSeconds: 0,
                    keptTranscriptStartSeconds: 0,
                    keptTranscriptEndSeconds: 5
                )
            ],
            myElsonMarkdown: """
            ## Words
            - Teerling
            - Elson.ai
            """,
            transcriptAgentPrompt: ElsonPromptCatalog.defaultTranscriptAgentPrompt,
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

    private func repoSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
