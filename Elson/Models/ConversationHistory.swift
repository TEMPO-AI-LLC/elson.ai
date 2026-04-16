import Foundation

struct ConversationThreadSummary: Identifiable, Equatable {
    let threadId: String
    let title: String
    let updatedAt: Date
    let lastMessage: String
    let lastRole: String?
    let lastReplyTarget: String?
    let sessionKey: String?

    var id: String { threadId }
}

struct ConversationThreadMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
        case system
    }

    let id: String
    let role: Role
    let content: String
    let createdAt: Date
    let style: ChatMessage.Style
    let rawTranscript: String?
    let insertedText: String?
    let attachments: [ChatMessageAttachment]
    let showsAttachmentChip: Bool
    let feedbackSubject: FeedbackSubject?

    init(
        id: String,
        role: Role,
        content: String,
        createdAt: Date,
        style: ChatMessage.Style = .text,
        rawTranscript: String? = nil,
        insertedText: String? = nil,
        attachments: [ChatMessageAttachment] = [],
        showsAttachmentChip: Bool = false,
        feedbackSubject: FeedbackSubject? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.style = style
        let trimmedRawTranscript = rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawTranscript = trimmedRawTranscript?.isEmpty == false ? trimmedRawTranscript : nil
        let trimmedInsertedText = insertedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.insertedText = trimmedInsertedText?.isEmpty == false ? trimmedInsertedText : nil
        self.attachments = attachments
        self.showsAttachmentChip = showsAttachmentChip
        self.feedbackSubject = feedbackSubject
    }
}
