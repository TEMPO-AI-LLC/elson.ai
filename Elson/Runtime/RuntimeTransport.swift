import Foundation

enum LocalModelProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case google
    case cerebras

    var displayName: String {
        switch self {
        case .google:
            return "Google"
        case .cerebras:
            return "Cerebras"
        }
    }
}

struct ElsonAttachmentPayload: Codable, Hashable, Sendable {
    let kind: String
    let name: String
    let mime: String
    let source: String
    let dataRef: String

    enum CodingKeys: String, CodingKey {
        case kind
        case name
        case mime
        case source
        case dataRef = "data_ref"
    }
}

struct ElsonTimestampsPayload: Codable, Hashable, Sendable {
    let capturedAt: String
    let selectionNoteAt: String?
    let clipboardAt: String?
    let attachmentsAt: String?

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case selectionNoteAt = "selection_note_at"
        case clipboardAt = "clipboard_at"
        case attachmentsAt = "attachments_at"
    }
}

struct ElsonScreenContextPayload: Codable, Hashable, Sendable {
    let hasScreenContext: Bool
    let screenText: String?
    let screenDescription: String?

    enum CodingKeys: String, CodingKey {
        case hasScreenContext = "has_screen_context"
        case screenText = "screen_text"
        case screenDescription = "screen_description"
    }
}

struct ElsonSystemContextPayload: Codable, Hashable, Sendable {
    let localDateTime: String
    let localDate: String
    let localTime: String
    let timezone: String

    enum CodingKeys: String, CodingKey {
        case localDateTime = "local_date_time"
        case localDate = "local_date"
        case localTime = "local_time"
        case timezone
    }
}

struct ElsonAppContextPayload: Codable, Hashable, Sendable {
    let frontmostAppName: String?
    let frontmostAppBundleId: String?
    let frontmostWindowTitle: String?

    enum CodingKeys: String, CodingKey {
        case frontmostAppName = "frontmost_app_name"
        case frontmostAppBundleId = "frontmost_app_bundle_id"
        case frontmostWindowTitle = "frontmost_window_title"
    }
}

struct ElsonContinuationContextPayload: Codable, Hashable, Sendable {
    let candidateThreadId: String?
    let minutesSinceLastTurn: Double?
    let lastTurnCreatedAt: String?
    let lastMessageRole: String?
    let lastUserMessage: String?
    let lastAssistantMessage: String?
    let lastReplyMode: String?
    let currentFrontmostAppName: String?
    let currentFrontmostAppBundleId: String?
    let currentFrontmostWindowTitle: String?
    let previousFrontmostAppName: String?
    let previousFrontmostAppBundleId: String?
    let previousFrontmostWindowTitle: String?
    let sameFrontmostApp: Bool?
    let sameFrontmostWindowTitle: Bool?
    let lastOutputWasAutoPasted: Bool?

    enum CodingKeys: String, CodingKey {
        case candidateThreadId = "candidate_thread_id"
        case minutesSinceLastTurn = "minutes_since_last_turn"
        case lastTurnCreatedAt = "last_turn_created_at"
        case lastMessageRole = "last_message_role"
        case lastUserMessage = "last_user_message"
        case lastAssistantMessage = "last_assistant_message"
        case lastReplyMode = "last_reply_mode"
        case currentFrontmostAppName = "current_frontmost_app_name"
        case currentFrontmostAppBundleId = "current_frontmost_app_bundle_id"
        case currentFrontmostWindowTitle = "current_frontmost_window_title"
        case previousFrontmostAppName = "previous_frontmost_app_name"
        case previousFrontmostAppBundleId = "previous_frontmost_app_bundle_id"
        case previousFrontmostWindowTitle = "previous_frontmost_window_title"
        case sameFrontmostApp = "same_frontmost_app"
        case sameFrontmostWindowTitle = "same_frontmost_window_title"
        case lastOutputWasAutoPasted = "last_output_was_auto_pasted"
    }

    var hasCandidateThread: Bool {
        let trimmed = candidateThreadId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }
}

enum ElsonConversationRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
}

struct ElsonConversationTurnPayload: Codable, Hashable, Sendable {
    let role: ElsonConversationRole
    let content: String
}

struct ElsonRequestEnvelope: Codable, Hashable, Sendable {
    let requestId: String
    let threadId: String
    let surface: String
    let inputSource: String
    let modeHint: String
    let rawTranscript: String?
    let enhancedTranscript: String
    let transcriptSnippetCount: Int?
    let myElsonMarkdown: String
    let transcriptAgentPrompt: String
    let workingAgentPrompt: String
    let selectionNote: String?
    let clipboardText: String?
    let attachments: [ElsonAttachmentPayload]
    let conversationHistory: [ElsonConversationTurnPayload]
    let screenContext: ElsonScreenContextPayload
    let timestamps: ElsonTimestampsPayload
    let appContext: ElsonAppContextPayload
    let continuationContext: ElsonContinuationContextPayload?
    let systemContext: ElsonSystemContextPayload
    let selectedSkill: SelectedSkillPayload?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case threadId = "thread_id"
        case surface
        case inputSource = "input_source"
        case modeHint = "mode_hint"
        case rawTranscript = "raw_transcript"
        case enhancedTranscript = "enhanced_transcript"
        case transcriptSnippetCount = "transcript_snippet_count"
        case myElsonMarkdown = "my_elson_markdown"
        case transcriptAgentPrompt = "transcript_agent_prompt"
        case workingAgentPrompt = "working_agent_prompt"
        case selectionNote = "selection_note"
        case clipboardText = "clipboard_text"
        case attachments
        case conversationHistory = "conversation_history"
        case screenContext = "screen_context"
        case timestamps
        case appContext = "app_context"
        case continuationContext = "continuation_context"
        case systemContext = "system_context"
        case selectedSkill = "selected_skill"
    }
}

struct SelectedSkillPayload: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let sourceFamily: String
    let promptContext: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case sourceFamily = "source_family"
        case promptContext = "prompt_context"
    }
}

struct ElsonAction: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(type):\(args.keys.sorted().joined(separator: ","))" }

    let type: String
    let args: [String: String]
}

enum AgentOutcomeType: String, Codable, CaseIterable, Hashable, Sendable {
    case transcript
    case reply
    case note
    case reminder
    case myElsonUpdate = "myelson_update"
}

enum AudioDeciderRoute: String, Codable, Hashable, Sendable {
    case directTranscript = "direct_transcript"
    case fullAgent = "full_agent"
}

enum AudioDeciderThreadDecision: String, Codable, Hashable, Sendable, CaseIterable {
    case continueCurrentThread = "continue_current_thread"
    case startNewThread = "start_new_thread"
}

enum AudioDeciderReplyRelation: String, Codable, Hashable, Sendable, CaseIterable {
    case replyToLastAssistant = "reply_to_last_assistant"
    case replyToLastUser = "reply_to_last_user"
    case none
}

struct AgentLocalAction: Codable, Hashable, Sendable {
    let type: String
    let text: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    init(type: String, text: String? = nil) {
        self.type = type
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.text = trimmed.isEmpty ? nil : trimmed
    }
}

struct MyElsonReplaceOperation: Codable, Hashable, Sendable {
    let from: String
    let to: String
}

struct MyElsonPatch: Codable, Hashable, Sendable {
    let identityAndProfile: [String]
    let preferences: [String]
    let words: [String]
    let notes: [String]
    let reminders: [String]
    let openLoops: [String]
    let removeIdentityAndProfile: [String]
    let removePreferences: [String]
    let removeWords: [String]
    let removeNotes: [String]
    let removeReminders: [String]
    let removeOpenLoops: [String]
    let replaceIdentityAndProfile: [MyElsonReplaceOperation]
    let replacePreferences: [MyElsonReplaceOperation]
    let replaceWords: [MyElsonReplaceOperation]
    let replaceNotes: [MyElsonReplaceOperation]
    let replaceReminders: [MyElsonReplaceOperation]
    let replaceOpenLoops: [MyElsonReplaceOperation]

    enum CodingKeys: String, CodingKey {
        case identityAndProfile = "identity_and_profile"
        case preferences
        case words
        case notes
        case reminders
        case openLoops = "open_loops"
        case removeIdentityAndProfile = "remove_identity_and_profile"
        case removePreferences = "remove_preferences"
        case removeWords = "remove_words"
        case removeNotes = "remove_notes"
        case removeReminders = "remove_reminders"
        case removeOpenLoops = "remove_open_loops"
        case replaceIdentityAndProfile = "replace_identity_and_profile"
        case replacePreferences = "replace_preferences"
        case replaceWords = "replace_words"
        case replaceNotes = "replace_notes"
        case replaceReminders = "replace_reminders"
        case replaceOpenLoops = "replace_open_loops"
    }

    init(
        identityAndProfile: [String] = [],
        preferences: [String] = [],
        words: [String] = [],
        notes: [String] = [],
        reminders: [String] = [],
        openLoops: [String] = [],
        removeIdentityAndProfile: [String] = [],
        removePreferences: [String] = [],
        removeWords: [String] = [],
        removeNotes: [String] = [],
        removeReminders: [String] = [],
        removeOpenLoops: [String] = [],
        replaceIdentityAndProfile: [MyElsonReplaceOperation] = [],
        replacePreferences: [MyElsonReplaceOperation] = [],
        replaceWords: [MyElsonReplaceOperation] = [],
        replaceNotes: [MyElsonReplaceOperation] = [],
        replaceReminders: [MyElsonReplaceOperation] = [],
        replaceOpenLoops: [MyElsonReplaceOperation] = []
    ) {
        self.identityAndProfile = identityAndProfile
        self.preferences = preferences
        self.words = words
        self.notes = notes
        self.reminders = reminders
        self.openLoops = openLoops
        self.removeIdentityAndProfile = removeIdentityAndProfile
        self.removePreferences = removePreferences
        self.removeWords = removeWords
        self.removeNotes = removeNotes
        self.removeReminders = removeReminders
        self.removeOpenLoops = removeOpenLoops
        self.replaceIdentityAndProfile = replaceIdentityAndProfile
        self.replacePreferences = replacePreferences
        self.replaceWords = replaceWords
        self.replaceNotes = replaceNotes
        self.replaceReminders = replaceReminders
        self.replaceOpenLoops = replaceOpenLoops
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identityAndProfile = try container.decodeIfPresent([String].self, forKey: .identityAndProfile) ?? []
        preferences = try container.decodeIfPresent([String].self, forKey: .preferences) ?? []
        words = try container.decodeIfPresent([String].self, forKey: .words) ?? []
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        reminders = try container.decodeIfPresent([String].self, forKey: .reminders) ?? []
        openLoops = try container.decodeIfPresent([String].self, forKey: .openLoops) ?? []
        removeIdentityAndProfile = try container.decodeIfPresent([String].self, forKey: .removeIdentityAndProfile) ?? []
        removePreferences = try container.decodeIfPresent([String].self, forKey: .removePreferences) ?? []
        removeWords = try container.decodeIfPresent([String].self, forKey: .removeWords) ?? []
        removeNotes = try container.decodeIfPresent([String].self, forKey: .removeNotes) ?? []
        removeReminders = try container.decodeIfPresent([String].self, forKey: .removeReminders) ?? []
        removeOpenLoops = try container.decodeIfPresent([String].self, forKey: .removeOpenLoops) ?? []
        replaceIdentityAndProfile = try container.decodeIfPresent([MyElsonReplaceOperation].self, forKey: .replaceIdentityAndProfile) ?? []
        replacePreferences = try container.decodeIfPresent([MyElsonReplaceOperation].self, forKey: .replacePreferences) ?? []
        replaceWords = try container.decodeIfPresent([MyElsonReplaceOperation].self, forKey: .replaceWords) ?? []
        replaceNotes = try container.decodeIfPresent([MyElsonReplaceOperation].self, forKey: .replaceNotes) ?? []
        replaceReminders = try container.decodeIfPresent([MyElsonReplaceOperation].self, forKey: .replaceReminders) ?? []
        replaceOpenLoops = try container.decodeIfPresent([MyElsonReplaceOperation].self, forKey: .replaceOpenLoops) ?? []
    }

    var isEmpty: Bool {
        identityAndProfile.isEmpty
            && preferences.isEmpty
            && words.isEmpty
            && notes.isEmpty
            && reminders.isEmpty
            && openLoops.isEmpty
            && removeIdentityAndProfile.isEmpty
            && removePreferences.isEmpty
            && removeWords.isEmpty
            && removeNotes.isEmpty
            && removeReminders.isEmpty
            && removeOpenLoops.isEmpty
            && replaceIdentityAndProfile.isEmpty
            && replacePreferences.isEmpty
            && replaceWords.isEmpty
            && replaceNotes.isEmpty
            && replaceReminders.isEmpty
            && replaceOpenLoops.isEmpty
    }
}

struct AgentDecision: Hashable, Sendable {
    let outcomeType: AgentOutcomeType
    let replyText: String
    let localActions: [AgentLocalAction]
    let myElsonPatch: MyElsonPatch?
    let reason: String
}

struct AgentExecutionResult: Hashable, Sendable {
    let decision: AgentDecision
    let updatedMyElsonMarkdown: String?
    let displayText: String
    let clipboardText: String
    let actions: [ElsonAction]
}

struct ElsonResponseEnvelope: Codable, Hashable, Sendable {
    let replyMode: String
    let displayText: String
    let clipboardText: String
    let actions: [ElsonAction]
    let requiresConfirmation: Bool
    let threadReset: Bool
    let debugReason: String
    let threadId: String?
    let messageId: String?
    let sessionKey: String?
    let updatedMyElsonMarkdown: String?

    enum CodingKeys: String, CodingKey {
        case replyMode = "reply_mode"
        case displayText = "display_text"
        case clipboardText = "clipboard_text"
        case actions
        case requiresConfirmation = "requires_confirmation"
        case threadReset = "thread_reset"
        case debugReason = "debug_reason"
        case threadId = "thread_id"
        case messageId = "message_id"
        case sessionKey = "session_key"
        case updatedMyElsonMarkdown = "updated_myelson_markdown"
    }
}

protocol RuntimeTransport: Sendable {
    func send(_ request: ElsonRequestEnvelope, config: ElsonLocalConfig) async throws -> ElsonResponseEnvelope
}

struct PostResponseCorrectionSeed: Hashable, Sendable {
    let request: ElsonRequestEnvelope
    let assistantReplyText: String

    func withMyElsonMarkdown(_ markdown: String) -> PostResponseCorrectionSeed {
        PostResponseCorrectionSeed(
            request: ElsonRequestEnvelope(
                requestId: request.requestId,
                threadId: request.threadId,
                surface: request.surface,
                inputSource: request.inputSource,
                modeHint: request.modeHint,
                rawTranscript: request.rawTranscript,
                enhancedTranscript: request.enhancedTranscript,
                transcriptSnippetCount: request.transcriptSnippetCount,
                myElsonMarkdown: markdown,
                transcriptAgentPrompt: request.transcriptAgentPrompt,
                workingAgentPrompt: request.workingAgentPrompt,
                selectionNote: request.selectionNote,
                clipboardText: request.clipboardText,
                attachments: request.attachments,
                conversationHistory: request.conversationHistory,
                screenContext: request.screenContext,
                timestamps: request.timestamps,
                appContext: request.appContext,
                continuationContext: request.continuationContext,
                systemContext: request.systemContext,
                selectedSkill: request.selectedSkill
            ),
            assistantReplyText: assistantReplyText
        )
    }
}
