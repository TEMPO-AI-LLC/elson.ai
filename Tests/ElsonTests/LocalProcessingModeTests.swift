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
        XCTAssertNotEqual(settings.firstIncompleteInstallOnboardingStep, .apiKeys)

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

        var hostedConfig = ElsonLocalConfig.default
        hostedConfig.runtimeMode = .hosted
        XCTAssertEqual(LocalProcessingRouter.audioBackend(for: hostedConfig), .groq)
        XCTAssertEqual(LocalProcessingRouter.llmBackend(for: hostedConfig), .hostedProviders)
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
}
