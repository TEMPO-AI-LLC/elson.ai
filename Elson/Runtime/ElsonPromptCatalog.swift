import Foundation

enum ElsonPromptCatalog {
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

    private static var screenExtractorBasePrompt: String {
        PromptConfig.shared.string("screen_extractor_base_prompt")
    }

    static func screenExtractorSystemPrompt(wordsGlossaryMarkdown: String) -> String {
        [
            screenExtractorBasePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            PromptConfig.shared.string(
                "screen_extractor_task",
                replacements: [
                    "words_glossary": nonEmptyOrPlaceholder(wordsGlossaryMarkdown)
                ]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .joined(separator: "\n\n")
    }

    static func screenExtractorUserPrompt() -> String {
        PromptConfig.shared.string("screen_extractor_user_prompt")
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
        PromptConfig.shared.string(
            "transcript_agent_user_prompt",
            replacements: [
                "surface": envelope.surface,
                "input_source": envelope.inputSource,
                "transcript_snippet_count": envelope.transcriptSnippetCount.map { String($0) } ?? "None",
                "transcript_chunk_timing": transcriptChunkTimingText(envelope.transcriptChunkTimings),
                "continuation_context": continuationContextText(envelope.continuationContext),
                "words_glossary": wordsGlossaryText(from: envelope.myElsonMarkdown),
                "clipboard_text": nonEmptyOrPlaceholder(envelope.clipboardText),
                "screen_text": nonEmptyOrPlaceholder(envelope.screenContext.screenText),
                "screen_description": nonEmptyOrPlaceholder(envelope.screenContext.screenDescription),
                "attachments": attachmentSummary,
                "raw_transcript": nonEmptyOrPlaceholder(envelope.rawTranscript ?? envelope.enhancedTranscript),
            ]
        )
    }

    static func localFormattingSystemPrompt(
        transcriptAgentPrompt: String,
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
        let taskInstructions = PromptConfig.shared.string(
            contextBlock.isEmpty ? "local_formatting_system_task" : "local_formatting_system_task_with_context",
            replacements: [
                "mode_instructions": modeInstructions,
                "transcript_rules": transcriptRules,
                "words_glossary": wordsGlossary,
                "context_block": contextBlock,
            ]
        )

        return taskSystemPrompt(
            basePrompt: transcriptAgentPrompt,
            taskInstructions: taskInstructions,
            includeConversationHistory: includeConversationHistory
        )
    }

    static func localFormattingUserPrompt(request: LocalFormattingRequest) -> String {
        PromptConfig.shared.string(
            "local_formatting_user_prompt",
            replacements: [
                "surface": request.surface,
                "input_source": request.inputSource,
                "clipboard_text": nonEmptyOrPlaceholder(request.clipboardText),
                "screen_text": nonEmptyOrPlaceholder(request.screenContext.screenText),
                "screen_description": nonEmptyOrPlaceholder(request.screenContext.screenDescription),
                "attachments": request.attachmentSummaryText,
                "transcript_snippet_count": request.transcriptSnippetCount.map { String($0) } ?? "None",
                "transcript_chunk_timing": transcriptChunkTimingText(request.transcriptChunkTimings),
                "raw_transcript": nonEmptyOrPlaceholder(request.rawTranscript),
                "current_transcript": request.enhancedTranscript,
            ]
        )
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
        PromptConfig.shared.string(
            "working_agent_user_prompt",
            replacements: envelopeReplacements(envelope, attachmentSummary: attachmentSummary)
        )
    }

    static func localWorkingAgentUserPrompt(
        envelope: ElsonRequestEnvelope,
        attachmentSummary: String
    ) -> String {
        PromptConfig.shared.string(
            "local_working_agent_user_prompt",
            replacements: localWorkingAgentReplacements(envelope, attachmentSummary: attachmentSummary)
        )
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
        var replacements = envelopeReplacements(envelope, attachmentSummary: attachmentSummary)
        replacements["assistant_reply_text"] = nonEmptyOrPlaceholder(assistantReplyText)
        return PromptConfig.shared.string(
            "words_correction_user_prompt",
            replacements: replacements
        )
    }

    static func apiKeyValidationMessages() -> [[String: String]] {
        PromptConfig.shared.messages("api_key_validation_messages")
    }

    static func structuredEnhancementSystemPrompt(context: String) -> String {
        PromptConfig.shared.string(
            "structured_enhancement_system_prompt",
            replacements: ["context": context]
        )
    }

    static func structuredEnhancementUserPrompt(text: String) -> String {
        PromptConfig.shared.string(
            "structured_enhancement_user_prompt",
            replacements: ["text": text]
        )
    }

    static func looseEnhancementUserPrompt(text: String, context: String) -> String {
        PromptConfig.shared.string(
            "loose_enhancement_user_prompt",
            replacements: [
                "context": context,
                "text": text,
            ]
        )
    }

    static func googleCombinedTranscriptionSystemInstruction() -> String {
        PromptConfig.shared.string("google_combined_transcription_system_instruction")
    }

    static func googleCombinedTranscriptionUserPrompt(context: String) -> String {
        PromptConfig.shared.string(
            "google_combined_transcription_user_prompt",
            replacements: ["context": context]
        )
    }

    static func promptLearningSystemPrompt() -> String {
        PromptConfig.shared.string("prompt_learning_system_prompt")
    }

    static func promptLearningUserPrompt(
        feedbackEntry: FeedbackEntry,
        subject: FeedbackSubject,
        transcriptPrompt: String,
        workingAgentPrompt: String
    ) -> String {
        PromptConfig.shared.string(
            "prompt_learning_user_prompt",
            replacements: [
                "feedback_rating": feedbackEntry.rating.rawValue,
                "feedback_note": nonEmptyOrPlaceholder(feedbackEntry.note),
                "expected_route_override": nonEmptyOrPlaceholder(feedbackEntry.expectedRouteOverride),
                "request_id": subject.requestId,
                "thread_id": nonEmptyOrPlaceholder(subject.threadId),
                "actual_route": subject.actualRoute,
                "reply_mode": subject.replyMode,
                "source_surface": subject.sourceSurface,
                "routing_source": subject.routingSource,
                "forced_route_reason": nonEmptyOrPlaceholder(subject.forcedRouteReason),
                "debug_reason": subject.debugReason,
                "visible_output_source": subject.visibleOutputSource,
                "has_screen_context": subject.hasScreenContext ? "true" : "false",
                "raw_transcript": nonEmptyOrPlaceholder(subject.rawTranscript),
                "processed_output": subject.processedText,
                "current_transcript_prompt": transcriptPrompt,
                "current_working_agent_prompt": workingAgentPrompt,
            ]
        )
    }

    static func historySummarySystemPrompt() -> String {
        PromptConfig.shared.string("history_summary_system_prompt")
    }

    static func historySummaryUserPrompt(
        text: String,
        rawTranscript: String?,
        source: String,
        replyMode: String?
    ) -> String {
        PromptConfig.shared.string(
            "history_summary_user_prompt",
            replacements: [
                "source": nonEmptyOrPlaceholder(source),
                "reply_mode": nonEmptyOrPlaceholder(replyMode),
                "final_text": nonEmptyOrPlaceholder(text),
                "raw_transcript": nonEmptyOrPlaceholder(rawTranscript),
            ]
        )
    }

    static func localGemmaTranscriptEnhancerSystemPrompt() -> String {
        PromptConfig.shared.string("local_gemma_transcript_enhancer_system_prompt")
    }

    static func localGemmaTranscriptEnhancerUserPrompt(transcript: String) -> String {
        localGemmaTranscriptEnhancerUserPrompt(
            transcript: transcript,
            screenContext: ElsonScreenContextPayload(
                hasScreenContext: false,
                screenText: nil,
                screenDescription: nil
            )
        )
    }

    static func localGemmaTranscriptEnhancerUserPrompt(
        transcript: String,
        screenContext: ElsonScreenContextPayload
    ) -> String {
        PromptConfig.shared.string(
            "local_gemma_transcript_enhancer_user_prompt",
            replacements: [
                "raw_transcript": transcript,
                "transcript_snippet_count": "None",
                "transcript_chunk_timing": "None",
                "local_date_time": "None",
                "local_date": "None",
                "local_time": "None",
                "timezone": "None",
                "words_glossary": "None",
                "screen_text": nonEmptyOrPlaceholder(screenContext.screenText),
            ]
        )
    }

    static func localGemmaTranscriptEnhancerUserPrompt(envelope: ElsonRequestEnvelope) -> String {
        PromptConfig.shared.string(
            "local_gemma_transcript_enhancer_user_prompt",
            replacements: localTranscriptEnhancerReplacements(envelope)
        )
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

    private static func transcriptChunkTimingText(_ timings: [ElsonTranscriptChunkTimingPayload]) -> String {
        let sortedTimings = timings.sorted { $0.index < $1.index }
        guard !sortedTimings.isEmpty else { return "None" }

        var lines = [PromptConfig.shared.string("transcript_chunk_timing_header")]
        for (position, timing) in sortedTimings.enumerated() {
            let snippet = timing.transcriptSnippetIndex.map { "snippet \($0 + 1)" } ?? "no transcript snippet"
            let phaseText = timing.phase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let phase = phaseText.isEmpty ? "transcript" : phaseText
            let overlap = timing.overlapStartSeconds.flatMap { start in
                timing.overlapEndSeconds.map { end in
                    secondsRange(start, end)
                }
            } ?? "None"
            lines.append(
                "- chunk \(timing.index + 1), phase=\(phase), \(snippet): audio=\(secondsRange(timing.audioStartSeconds, timing.audioEndSeconds)); asr_payload=\(secondsRange(timing.asrPayloadStartSeconds, timing.asrPayloadEndSeconds)); overlap_context=\(overlap); kept_transcript_audio=\(secondsRange(timing.keptTranscriptStartSeconds, timing.keptTranscriptEndSeconds))"
            )
            if timing.overlapDurationSeconds > 0, position > 0 {
                let previous = sortedTimings[position - 1]
                lines.append(
                    "  overlap_check: previous_stable_audio=\(secondsRange(0, timing.asrPayloadStartSeconds)); previous_asr_payload=\(secondsRange(previous.asrPayloadStartSeconds, previous.asrPayloadEndSeconds)); current_asr_payload=\(secondsRange(timing.asrPayloadStartSeconds, timing.asrPayloadEndSeconds))"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func secondsRange(_ start: Double, _ end: Double) -> String {
        "\(secondsText(start))-\(secondsText(end))s"
    }

    private static func secondsText(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.rounded() == rounded {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
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

    private static func envelopeReplacements(
        _ envelope: ElsonRequestEnvelope,
        attachmentSummary: String
    ) -> [String: String] {
        [
            "mode_hint": envelope.modeHint,
            "surface": envelope.surface,
            "input_source": envelope.inputSource,
            "transcript_snippet_count": envelope.transcriptSnippetCount.map { String($0) } ?? "None",
            "transcript_chunk_timing": transcriptChunkTimingText(envelope.transcriptChunkTimings),
            "local_date_time": envelope.systemContext.localDateTime,
            "local_date": envelope.systemContext.localDate,
            "local_time": envelope.systemContext.localTime,
            "timezone": envelope.systemContext.timezone,
            "frontmost_app_name": nonEmptyOrPlaceholder(envelope.appContext.frontmostAppName),
            "frontmost_app_bundle_id": nonEmptyOrPlaceholder(envelope.appContext.frontmostAppBundleId),
            "frontmost_window_title": nonEmptyOrPlaceholder(envelope.appContext.frontmostWindowTitle),
            "continuation_context": continuationContextText(envelope.continuationContext),
            "words_glossary": wordsGlossaryText(from: envelope.myElsonMarkdown),
            "clipboard_text": nonEmptyOrPlaceholder(envelope.clipboardText),
            "screen_text": nonEmptyOrPlaceholder(envelope.screenContext.screenText),
            "screen_description": nonEmptyOrPlaceholder(envelope.screenContext.screenDescription),
            "attachments": attachmentSummary,
            "skills_enabled": envelope.selectedSkill == nil ? "false" : "true",
            "selected_skill_context": nonEmptyOrPlaceholder(envelope.selectedSkill?.promptContext),
            "myelson_markdown": nonEmptyOrPlaceholder(envelope.myElsonMarkdown),
            "current_transcript": envelope.enhancedTranscript,
            "raw_transcript": nonEmptyOrPlaceholder(envelope.rawTranscript),
        ]
    }

    private static func localTranscriptEnhancerReplacements(_ envelope: ElsonRequestEnvelope) -> [String: String] {
        [
            "raw_transcript": nonEmptyOrPlaceholder(envelope.rawTranscript ?? envelope.enhancedTranscript),
        ]
    }

    private static func localWorkingAgentReplacements(
        _ envelope: ElsonRequestEnvelope,
        attachmentSummary: String
    ) -> [String: String] {
        [
            "transcript_context": nonEmptyOrPlaceholder(envelope.transcriptContext),
            "agent_intent_transcript": nonEmptyOrPlaceholder(envelope.agentIntentTranscript ?? envelope.rawTranscript),
            "raw_transcript": nonEmptyOrPlaceholder(envelope.rawTranscript),
            "transcript_snippet_count": envelope.transcriptSnippetCount.map { String($0) } ?? "None",
            "transcript_chunk_timing": transcriptChunkTimingText(envelope.transcriptChunkTimings),
            "local_date_time": envelope.systemContext.localDateTime,
            "local_date": envelope.systemContext.localDate,
            "local_time": envelope.systemContext.localTime,
            "timezone": envelope.systemContext.timezone,
            "frontmost_app_name": nonEmptyOrPlaceholder(envelope.appContext.frontmostAppName),
            "frontmost_app_bundle_id": nonEmptyOrPlaceholder(envelope.appContext.frontmostAppBundleId),
            "frontmost_window_title": nonEmptyOrPlaceholder(envelope.appContext.frontmostWindowTitle),
            "continuation_context": continuationContextText(envelope.continuationContext),
            "words_glossary": wordsGlossaryText(from: envelope.myElsonMarkdown),
            "clipboard_text": nonEmptyOrPlaceholder(envelope.clipboardText),
            "attachments": attachmentSummary,
            "skills_enabled": envelope.selectedSkill == nil ? "false" : "true",
            "selected_skill_context": nonEmptyOrPlaceholder(envelope.selectedSkill?.promptContext),
            "myelson_markdown": nonEmptyOrPlaceholder(envelope.myElsonMarkdown),
        ]
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

        return PromptConfig.shared.string(
            "continuation_context_template",
            replacements: [
                "candidate_thread_id": nonEmptyOrPlaceholder(context.candidateThreadId),
                "minutes_since_last_turn": nonEmptyOrPlaceholder(context.minutesSinceLastTurn),
                "last_turn_created_at": nonEmptyOrPlaceholder(context.lastTurnCreatedAt),
                "last_message_role": nonEmptyOrPlaceholder(context.lastMessageRole),
                "last_user_message": nonEmptyOrPlaceholder(context.lastUserMessage),
                "last_assistant_message": nonEmptyOrPlaceholder(context.lastAssistantMessage),
                "last_reply_mode": nonEmptyOrPlaceholder(context.lastReplyMode),
                "current_frontmost_app_name": nonEmptyOrPlaceholder(context.currentFrontmostAppName),
                "current_frontmost_app_bundle_id": nonEmptyOrPlaceholder(context.currentFrontmostAppBundleId),
                "current_frontmost_window_title": nonEmptyOrPlaceholder(context.currentFrontmostWindowTitle),
                "previous_frontmost_app_name": nonEmptyOrPlaceholder(context.previousFrontmostAppName),
                "previous_frontmost_app_bundle_id": nonEmptyOrPlaceholder(context.previousFrontmostAppBundleId),
                "previous_frontmost_window_title": nonEmptyOrPlaceholder(context.previousFrontmostWindowTitle),
                "same_frontmost_app": nonEmptyOrPlaceholder(context.sameFrontmostApp),
                "same_frontmost_window_title": nonEmptyOrPlaceholder(context.sameFrontmostWindowTitle),
                "last_output_was_auto_pasted": nonEmptyOrPlaceholder(context.lastOutputWasAutoPasted),
            ]
        )
    }
}
