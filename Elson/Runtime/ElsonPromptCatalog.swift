import Foundation

enum ElsonPromptCatalog {
    static var defaultIntentAgentPrompt: String {
        PromptConfig.shared.string(
            "default_intent_agent_prompt",
            replacements: sharedPromptReplacements()
        )
    }

    static var defaultWorkingAgentPrompt: String {
        PromptConfig.shared.string(
            "default_working_agent_prompt",
            replacements: sharedPromptReplacements()
        )
    }

    static var defaultTranscriptAgentPrompt: String {
        PromptConfig.shared.string(
            "default_transcript_agent_prompt",
            replacements: sharedPromptReplacements()
        )
    }

    private static var workingAgentCapabilityContract: String {
        PromptConfig.shared.string("working_agent_capability_contract")
    }

    private static var sharedAgentGroundRules: String {
        PromptConfig.shared.string("shared_agent_ground_rules")
    }

    private static var conversationContinuationRules: String {
        PromptConfig.shared.string("conversation_continuation_rules")
    }

    private static var chatHistoryDeveloperPrompt: String {
        PromptConfig.shared.string("chat_history_developer_prompt")
    }

    static func normalizedIntentAgentPrompt(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultIntentAgentPrompt }
        return trimmed
    }

    static func normalizedWorkingAgentPrompt(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultWorkingAgentPrompt }
        return trimmed
    }

    static func normalizedTranscriptAgentPrompt(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultTranscriptAgentPrompt }
        return trimmed
    }

    static func migratedPriorAgentPrompt(_ priorAgentPrompt: String?) -> String? {
        guard let priorAgentPrompt else { return nil }
        let trimmed = priorAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func wordsGlossaryText(from markdown: String) -> String {
        let glossary = MyElsonDocument.wordsGlossaryMarkdown(from: markdown)
        return glossary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "None" : glossary
    }

    static func screenExtractorSystemPrompt(intentAgentPrompt: String, wordsGlossaryMarkdown: String) -> String {
        taskSystemPrompt(
            basePrompt: intentAgentPrompt,
            taskInstructions: PromptConfig.shared.string(
                "screen_extractor_task",
                replacements: [
                    "words_glossary": nonEmptyOrPlaceholder(wordsGlossaryMarkdown)
                ]
            ),
            includeConversationHistory: false
        )
    }

    static func screenExtractorUserPrompt() -> String {
        "Extract OCR-style text and a concise scene description from these current-turn screenshots."
    }

    static func intentAgentSystemPrompt(
        intentAgentPrompt: String,
        includeConversationHistory: Bool
    ) -> String {
        taskSystemPrompt(
            basePrompt: intentAgentPrompt,
            taskInstructions: PromptConfig.shared.string(
                "intent_agent_task",
                replacements: [
                    "working_agent_capability_contract": workingAgentCapabilityContract
                ]
            ),
            includeConversationHistory: includeConversationHistory
        )
    }

    static func intentAgentUserPrompt(
        envelope: ElsonRequestEnvelope,
        attachmentSummary: String,
        fullAgentAllowed: Bool
    ) -> String {
        """
        mode_hint: \(envelope.modeHint)
        full_agent_allowed: \(fullAgentAllowed ? "true" : "false")
        surface: \(envelope.surface)
        input_source: \(envelope.inputSource)
        transcript_snippet_count: \(envelope.transcriptSnippetCount.map { String($0) } ?? "None")

        frontmost_app_name: \(nonEmptyOrPlaceholder(envelope.appContext.frontmostAppName))
        frontmost_app_bundle_id: \(nonEmptyOrPlaceholder(envelope.appContext.frontmostAppBundleId))
        frontmost_window_title: \(nonEmptyOrPlaceholder(envelope.appContext.frontmostWindowTitle))

        continuation_context:
        \(continuationContextText(envelope.continuationContext))

        words_glossary:
        \(wordsGlossaryText(from: envelope.myElsonMarkdown))

        clipboard_text:
        \(nonEmptyOrPlaceholder(envelope.clipboardText))

        screen_text:
        \(nonEmptyOrPlaceholder(envelope.screenContext.screenText))

        screen_description:
        \(nonEmptyOrPlaceholder(envelope.screenContext.screenDescription))

        attachments:
        \(attachmentSummary)

        raw_transcript:
        \(nonEmptyOrPlaceholder(envelope.rawTranscript))
        """
    }

    static func transcriptAgentSystemPrompt(
        transcriptAgentPrompt: String,
        includeConversationHistory: Bool
    ) -> String {
        taskSystemPrompt(
            basePrompt: transcriptAgentPrompt,
            taskInstructions: PromptConfig.shared.string("transcript_agent_task"),
            includeConversationHistory: includeConversationHistory
        )
    }

    static func transcriptAgentUserPrompt(
        envelope: ElsonRequestEnvelope,
        attachmentSummary: String
    ) -> String {
        """
        surface: \(envelope.surface)
        input_source: \(envelope.inputSource)
        transcript_snippet_count: \(envelope.transcriptSnippetCount.map { String($0) } ?? "None")

        continuation_context:
        \(continuationContextText(envelope.continuationContext))

        words_glossary:
        \(wordsGlossaryText(from: envelope.myElsonMarkdown))

        clipboard_text:
        \(nonEmptyOrPlaceholder(envelope.clipboardText))

        screen_text:
        \(nonEmptyOrPlaceholder(envelope.screenContext.screenText))

        screen_description:
        \(nonEmptyOrPlaceholder(envelope.screenContext.screenDescription))

        attachments:
        \(attachmentSummary)

        raw_transcript:
        \(nonEmptyOrPlaceholder(envelope.rawTranscript ?? envelope.enhancedTranscript))
        """
    }

    static func localFormattingSystemPrompt(
        intentAgentPrompt: String,
        mode: String,
        extraContextMarkdown: String,
        includeConversationHistory: Bool
    ) -> String {
        let transcriptRules = PromptConfig.shared.string("local_formatting_transcript_rules")

        let modeInstructions: String = switch mode {
        case "clarity":
            PromptConfig.shared.string("local_formatting_mode_clarity")
        case "llm-friendly":
            PromptConfig.shared.string("local_formatting_mode_llm_friendly")
        default:
            PromptConfig.shared.string("local_formatting_mode_default")
        }

        let contextBlock = extraContextMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordsGlossary = wordsGlossaryText(from: extraContextMarkdown)
        let taskInstructions = contextBlock.isEmpty
            ? """
            \(modeInstructions)
            \(transcriptRules)

            Words glossary:
            \(wordsGlossary)
            """
            : """
            \(modeInstructions)
            \(transcriptRules)

            Words glossary:
            \(wordsGlossary)

            Additional Elson.ai context, preferences, and custom words:
            \(contextBlock)
            """

        return taskSystemPrompt(
            basePrompt: intentAgentPrompt,
            taskInstructions: taskInstructions,
            includeConversationHistory: includeConversationHistory
        )
    }

    static func localFormattingUserPrompt(request: LocalFormattingRequest) -> String {
        """
        surface: \(request.surface)
        input_source: \(request.inputSource)

        clipboard_text:
        \(nonEmptyOrPlaceholder(request.clipboardText))

        screen_text:
        \(nonEmptyOrPlaceholder(request.screenContext.screenText))

        screen_description:
        \(nonEmptyOrPlaceholder(request.screenContext.screenDescription))

        attachments:
        \(request.attachmentSummaryText)

        transcript_snippet_count: \(request.transcriptSnippetCount.map { String($0) } ?? "None")

        raw_transcript:
        \(nonEmptyOrPlaceholder(request.rawTranscript))

        current_transcript:
        \(request.enhancedTranscript)
        """
    }

    static func workingAgentSystemPrompt(
        workingAgentPrompt: String,
        includeConversationHistory: Bool
    ) -> String {
        taskSystemPrompt(
            basePrompt: workingAgentPrompt,
            taskInstructions: PromptConfig.shared.string(
                "working_agent_task",
                replacements: [
                    "working_agent_capability_contract": workingAgentCapabilityContract
                ]
            ),
            includeConversationHistory: includeConversationHistory
        )
    }

    static func workingAgentUserPrompt(
        envelope: ElsonRequestEnvelope,
        attachmentSummary: String
    ) -> String {
        """
        mode_hint: \(envelope.modeHint)
        surface: \(envelope.surface)
        input_source: \(envelope.inputSource)
        transcript_snippet_count: \(envelope.transcriptSnippetCount.map { String($0) } ?? "None")

        local_date_time: \(envelope.systemContext.localDateTime)
        local_date: \(envelope.systemContext.localDate)
        local_time: \(envelope.systemContext.localTime)
        timezone: \(envelope.systemContext.timezone)

        frontmost_app_name: \(nonEmptyOrPlaceholder(envelope.appContext.frontmostAppName))
        frontmost_app_bundle_id: \(nonEmptyOrPlaceholder(envelope.appContext.frontmostAppBundleId))
        frontmost_window_title: \(nonEmptyOrPlaceholder(envelope.appContext.frontmostWindowTitle))

        continuation_context:
        \(continuationContextText(envelope.continuationContext))

        words_glossary:
        \(wordsGlossaryText(from: envelope.myElsonMarkdown))

        clipboard_text:
        \(nonEmptyOrPlaceholder(envelope.clipboardText))

        screen_text:
        \(nonEmptyOrPlaceholder(envelope.screenContext.screenText))

        screen_description:
        \(nonEmptyOrPlaceholder(envelope.screenContext.screenDescription))

        attachments:
        \(attachmentSummary)

        skills_enabled:
        \(envelope.selectedSkill == nil ? "false" : "true")

        selected_skill_context:
        \(nonEmptyOrPlaceholder(envelope.selectedSkill?.promptContext))

        myelson_markdown:
        \(nonEmptyOrPlaceholder(envelope.myElsonMarkdown))

        current_transcript:
        \(envelope.enhancedTranscript)

        raw_transcript:
        \(nonEmptyOrPlaceholder(envelope.rawTranscript))
        """
    }

    static func wordsCorrectionSystemPrompt(
        workingAgentPrompt: String,
        includeConversationHistory: Bool
    ) -> String {
        taskSystemPrompt(
            basePrompt: workingAgentPrompt,
            taskInstructions: PromptConfig.shared.string("words_correction_task"),
            includeConversationHistory: includeConversationHistory
        )
    }

    static func wordsCorrectionUserPrompt(
        envelope: ElsonRequestEnvelope,
        assistantReplyText: String,
        attachmentSummary: String
    ) -> String {
        """
        mode_hint: \(envelope.modeHint)
        surface: \(envelope.surface)
        input_source: \(envelope.inputSource)

        words_glossary:
        \(wordsGlossaryText(from: envelope.myElsonMarkdown))

        screen_text:
        \(nonEmptyOrPlaceholder(envelope.screenContext.screenText))

        screen_description:
        \(nonEmptyOrPlaceholder(envelope.screenContext.screenDescription))

        attachments:
        \(attachmentSummary)

        assistant_reply_text:
        \(nonEmptyOrPlaceholder(assistantReplyText))

        current_transcript:
        \(envelope.enhancedTranscript)

        raw_transcript:
        \(nonEmptyOrPlaceholder(envelope.rawTranscript))
        """
    }

    static func apiKeyValidationMessages() -> [[String: String]] {
        [
            [
                "role": "system",
                "content": "Reply with exactly OK."
            ],
            [
                "role": "user",
                "content": "Respond with OK."
            ]
        ]
    }

    static func structuredEnhancementSystemPrompt(context: String) -> String {
        """
        You are Elson.ai's faithful transcript cleanup assistant.

        User's context: \(context)

        Instructions:
        1. Fix grammar, punctuation, and spelling errors.
        2. Preserve the user's exact intent, tone, and scope.
        3. Do not add recommendations, structure, or implied detail that the user did not say.
        4. Apply explicit transformations only if the user clearly asked for them.
        5. Return valid JSON with an "enhanced_text" field containing the cleaned text.
        """
    }

    static func structuredEnhancementUserPrompt(text: String) -> String {
        "Clean this transcribed text faithfully and return JSON with enhanced_text only: \"\(text)\""
    }

    static func looseEnhancementUserPrompt(text: String, context: String) -> String {
        """
        You are Elson.ai's faithful transcript cleanup assistant.

        User's context: \(context)

        Instructions:
        1. Fix grammar, punctuation, and spelling errors.
        2. Preserve the user's exact intent, tone, and scope.
        3. Do not add recommendations, structure, or implied detail that the user did not say.
        4. Apply explicit transformations only if the user clearly asked for them.
        5. Return only the cleaned text, with no additional formatting or explanation.

        Transcribed text to clean: "\(text)"
        """
    }

    static func googleCombinedTranscriptionSystemInstruction() -> String {
        """
        You are Elson.ai's transcription and faithful cleanup assistant.
        """
    }

    static func googleCombinedTranscriptionUserPrompt(context: String) -> String {
        """
        Transcribe the audio first, then clean the transcript faithfully.

        Context from the user:
        \(context)

        Output MUST be valid JSON with exactly these keys:
        - transcript (string)
        - enhanced_text (string)
        """
    }

    static func promptLearningSystemPrompt() -> String {
        """
        You improve Elson.ai prompts from user feedback.

        Goal:
        - Make transcript cleanup more faithful.
        - Make working-agent behavior more answer/action-first.
        - Keep edits minimal and precise.

        Rules:
        - Return valid JSON only.
        - Choose exactly one decision:
          - no_learning
          - update_transcript_prompt
          - update_working_agent_prompt
        - Update only one prompt at a time.
        - Never rewrite both prompts in one response.
        - Prefer no_learning unless the feedback clearly reveals a prompt flaw.
        - Do not broaden capabilities.
        - Do not make the transcript prompt more creative.
        - Do not remove explicit transformation support from the transcript prompt.
        - Keep transcript fallback available in the working-agent prompt, but de-emphasized.
        """
    }

    static func promptLearningUserPrompt(
        feedbackEntry: FeedbackEntry,
        subject: FeedbackSubject,
        transcriptPrompt: String,
        workingAgentPrompt: String
    ) -> String {
        """
        feedback:
        rating: \(feedbackEntry.rating.rawValue)
        note: \(nonEmptyOrPlaceholder(feedbackEntry.note))
        expected_route_override: \(nonEmptyOrPlaceholder(feedbackEntry.expectedRouteOverride))

        output_context:
        request_id: \(subject.requestId)
        thread_id: \(nonEmptyOrPlaceholder(subject.threadId))
        actual_route: \(subject.actualRoute)
        reply_mode: \(subject.replyMode)
        source_surface: \(subject.sourceSurface)
        routing_source: \(subject.routingSource)
        forced_route_reason: \(nonEmptyOrPlaceholder(subject.forcedRouteReason))
        debug_reason: \(subject.debugReason)
        visible_output_source: \(subject.visibleOutputSource)
        has_screen_context: \(subject.hasScreenContext ? "true" : "false")

        raw_transcript:
        \(nonEmptyOrPlaceholder(subject.rawTranscript))

        processed_output:
        \(subject.processedText)

        current_transcript_prompt:
        \(transcriptPrompt)

        current_working_agent_prompt:
        \(workingAgentPrompt)
        """
    }

    static func historySummarySystemPrompt() -> String {
        """
        You write ultra-short history card titles for Elson.ai.

        Rules:
        - Return plain text only.
        - Prefer exactly two words. One word is acceptable only when a second word would be awkward.
        - Never exceed two words.
        - Preserve the user's language.
        - No quotes, no markdown, no labels, no punctuation unless the word itself requires it.
        - Focus on the core intent or topic, not the UI source.
        """
    }

    static func historySummaryUserPrompt(
        text: String,
        rawTranscript: String?,
        source: String,
        replyMode: String?
    ) -> String {
        """
        Create the shortest useful history title for this entry.

        Source:
        \(nonEmptyOrPlaceholder(source))

        Reply mode:
        \(nonEmptyOrPlaceholder(replyMode))

        Final text:
        \(nonEmptyOrPlaceholder(text))

        Original transcript:
        \(nonEmptyOrPlaceholder(rawTranscript))
        """
    }

    static func cerebrasMessages(
        systemPrompt: String,
        includeConversationHistory: Bool,
        history: [ElsonConversationTurnPayload],
        currentUserPrompt: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]

        messages.append(
            contentsOf: history.map { turn in
                [
                    "role": turn.role.rawValue,
                    "content": turn.content
                ] as [String: Any]
            }
        )
        messages.append(["role": "user", "content": currentUserPrompt])

        return messages
    }

    private static func taskSystemPrompt(
        basePrompt: String,
        taskInstructions: String,
        includeConversationHistory: Bool
    ) -> String {
        let prompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = taskInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = includeConversationHistory ? conversationContinuationRules : nil
        let chatHistoryGuidance = includeConversationHistory ? chatHistoryDeveloperPrompt : nil
        return [prompt, task, history, chatHistoryGuidance]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func sharedPromptReplacements(
        extra: [String: String] = [:]
    ) -> [String: String] {
        var values: [String: String] = [
            "working_agent_capability_contract": workingAgentCapabilityContract,
            "shared_agent_ground_rules": sharedAgentGroundRules
        ]
        for (key, value) in extra {
            values[key] = value
        }
        return values
    }

    private static func nonEmptyOrPlaceholder(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "None" : trimmed
    }

    private static func nonEmptyOrPlaceholder(_ value: Bool?) -> String {
        guard let value else { return "None" }
        return value ? "true" : "false"
    }

    private static func nonEmptyOrPlaceholder(_ value: Double?) -> String {
        guard let value else { return "None" }
        return String(format: "%.2f", value)
    }

    private static func continuationContextText(_ context: ElsonContinuationContextPayload?) -> String {
        guard let context else { return "None" }

        return """
        candidate_thread_id: \(nonEmptyOrPlaceholder(context.candidateThreadId))
        minutes_since_last_turn: \(nonEmptyOrPlaceholder(context.minutesSinceLastTurn))
        last_turn_created_at: \(nonEmptyOrPlaceholder(context.lastTurnCreatedAt))
        last_message_role: \(nonEmptyOrPlaceholder(context.lastMessageRole))
        last_user_message: \(nonEmptyOrPlaceholder(context.lastUserMessage))
        last_assistant_message: \(nonEmptyOrPlaceholder(context.lastAssistantMessage))
        last_reply_mode: \(nonEmptyOrPlaceholder(context.lastReplyMode))
        current_frontmost_app_name: \(nonEmptyOrPlaceholder(context.currentFrontmostAppName))
        current_frontmost_app_bundle_id: \(nonEmptyOrPlaceholder(context.currentFrontmostAppBundleId))
        current_frontmost_window_title: \(nonEmptyOrPlaceholder(context.currentFrontmostWindowTitle))
        previous_frontmost_app_name: \(nonEmptyOrPlaceholder(context.previousFrontmostAppName))
        previous_frontmost_app_bundle_id: \(nonEmptyOrPlaceholder(context.previousFrontmostAppBundleId))
        previous_frontmost_window_title: \(nonEmptyOrPlaceholder(context.previousFrontmostWindowTitle))
        same_frontmost_app: \(nonEmptyOrPlaceholder(context.sameFrontmostApp))
        same_frontmost_window_title: \(nonEmptyOrPlaceholder(context.sameFrontmostWindowTitle))
        last_output_was_auto_pasted: \(nonEmptyOrPlaceholder(context.lastOutputWasAutoPasted))
        """
    }
}
