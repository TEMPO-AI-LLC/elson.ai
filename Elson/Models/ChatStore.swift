import Foundation
import Observation

enum ThreadReplyTarget: String, Codable {
    case agent
    case transcript
}

struct LocalChatThreadStore {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        let baseURL = rootURL
            ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        self.rootURL = baseURL
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("chat-threads", isDirectory: true)
    }

    func load(threadId: String) -> ChatThread? {
        let trimmedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThreadId.isEmpty else { return nil }

        let fileURL = threadFileURL(for: trimmedThreadId)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(ChatThread.self, from: data)
        } catch {
            print("Failed to load chat thread \(trimmedThreadId): \(error)")
            return nil
        }
    }

    func save(_ thread: ChatThread) {
        let trimmedThreadId = thread.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThreadId.isEmpty else { return }

        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let data = try encoder.encode(thread)
            try data.write(to: threadFileURL(for: trimmedThreadId), options: [.atomic])
        } catch {
            print("Failed to save chat thread \(trimmedThreadId): \(error)")
        }
    }

    func remove(threadId: String) {
        let trimmedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThreadId.isEmpty else { return }

        let fileURL = threadFileURL(for: trimmedThreadId)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            print("Failed to remove chat thread \(trimmedThreadId): \(error)")
        }
    }

    func clear() {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }

        do {
            try fileManager.removeItem(at: rootURL)
        } catch {
            print("Failed to clear chat threads: \(error)")
        }
    }

    private func threadFileURL(for threadId: String) -> URL {
        rootURL
            .appendingPathComponent(safeFileName(for: threadId))
            .appendingPathExtension("json")
    }

    private func safeFileName(for threadId: String) -> String {
        Data(threadId.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct InFlightRun: Equatable {
    let threadId: String
    let mode: ThreadReplyTarget
    let startedAt: Date
    let optimisticUserMessageId: UUID?

    init(threadId: String, mode: ThreadReplyTarget, startedAt: Date = Date(), optimisticUserMessageId: UUID? = nil) {
        self.threadId = threadId
        self.mode = mode
        self.startedAt = startedAt
        self.optimisticUserMessageId = optimisticUserMessageId
    }
}

enum ThreadModeStore {
    private static func key(for threadId: String) -> String { "thread_mode:\(threadId)" }

    static func get(threadId: String) -> ThreadReplyTarget? {
        let raw = UserDefaults.standard.string(forKey: key(for: threadId)) ?? ""
        return ThreadReplyTarget(rawValue: raw)
    }

    static func set(threadId: String, target: ThreadReplyTarget) {
        guard !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UserDefaults.standard.set(target.rawValue, forKey: key(for: threadId))
    }

    static func clear(threadId: String) {
        guard !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: key(for: threadId))
    }
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable {
        case system
        case user
        case assistant
    }

    enum Style: String, Codable {
        case text
        case voiceTranscript
    }

    let id: UUID
    let role: Role
    let content: String
    let style: Style
    let rawTranscript: String?
    let insertedText: String?
    let attachments: [ChatMessageAttachment]
    let showsAttachmentChip: Bool
    let feedbackSubject: FeedbackSubject?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        style: Style = .text,
        rawTranscript: String? = nil,
        insertedText: String? = nil,
        attachments: [ChatMessageAttachment] = [],
        showsAttachmentChip: Bool = false,
        feedbackSubject: FeedbackSubject? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.style = style
        let trimmedRawTranscript = rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawTranscript = trimmedRawTranscript?.isEmpty == false ? trimmedRawTranscript : nil
        let trimmedInsertedText = insertedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.insertedText = trimmedInsertedText?.isEmpty == false ? trimmedInsertedText : nil
        self.attachments = attachments
        self.showsAttachmentChip = showsAttachmentChip
        self.feedbackSubject = feedbackSubject
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .text
        rawTranscript = try container.decodeIfPresent(String.self, forKey: .rawTranscript)
        insertedText = try container.decodeIfPresent(String.self, forKey: .insertedText)
        attachments = try container.decodeIfPresent([ChatMessageAttachment].self, forKey: .attachments) ?? []
        showsAttachmentChip = try container.decodeIfPresent(Bool.self, forKey: .showsAttachmentChip) ?? false
        feedbackSubject = try container.decodeIfPresent(FeedbackSubject.self, forKey: .feedbackSubject)
    }
}

struct ChatThread: Equatable, Codable {
    var id: String
    var messages: [ChatMessage]
}

@MainActor
@Observable
final class ChatStore {
    private(set) var thread: ChatThread = ChatThread(id: "", messages: [])
    private(set) var inFlight: InFlightRun? = nil
    private(set) var recentThreads: [ConversationThreadSummary] = []
    private(set) var historyHasMore = false
    private(set) var historyLoading = false
    private(set) var historyError: String? = nil
    private(set) var unreadThreadIDs: Set<String> = []

    @ObservationIgnored private let threadStore: LocalChatThreadStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var historyOffset = 0

    init(threadStore: LocalChatThreadStore = LocalChatThreadStore(), defaults: UserDefaults = .standard) {
        self.threadStore = threadStore
        self.defaults = defaults
        let id = loadOrCreateThreadID()
        if let persisted = threadStore.load(threadId: id) {
            thread = persisted
        } else {
            let initialThread = ChatThread(id: id, messages: [])
            thread = initialThread
            threadStore.save(initialThread)
        }
    }

    /// Adopt a new thread id as the canonical id without losing the local message tail.
    /// This is used to recover from any thread-id mismatch between views / request paths.
    @MainActor
    func adoptThreadIdPreservingMessages(newId: String) {
        let trimmed = newId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != thread.id else { return }
        let previousThreadId = thread.id
        let previousMessages = thread.messages
        let persistedTargetMessages = threadStore.load(threadId: trimmed)?.messages ?? []
        defaults.set(trimmed, forKey: threadIDDefaultsKey())
        var current = thread
        current.id = trimmed
        current.messages = mergedMessages(existing: persistedTargetMessages, appending: previousMessages)
        thread = current
        persistCurrentThread()
        threadStore.remove(threadId: previousThreadId)
    }

    @MainActor
    func beginRun(threadId: String, mode: ThreadReplyTarget, optimisticUserMessageId: UUID? = nil) {
        inFlight = InFlightRun(threadId: threadId, mode: mode, optimisticUserMessageId: optimisticUserMessageId)
    }

    @MainActor
    func endRun(threadId: String) {
        guard inFlight?.threadId == threadId else { return }
        inFlight = nil
    }

    @MainActor
    func loadRecentThreads(config: ElsonLocalConfig, reset: Bool) async {
        guard reset else { return }
        _ = config
        recentThreads = []
        historyHasMore = false
        historyOffset = 0
        historyError = nil
    }

    @MainActor
    func openThreadFromHistory(_ summary: ConversationThreadSummary) {
        let trimmedMessage = summary.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackRole = summary.lastRole.flatMap(ChatMessage.Role.init(rawValue:))
        let fallbackMessages: [ChatMessage] = {
            guard let fallbackRole, !trimmedMessage.isEmpty else { return [] }
            return [ChatMessage(role: fallbackRole, content: trimmedMessage)]
        }()
        openPersistedThread(id: summary.threadId, fallbackMessages: fallbackMessages)
        markThreadRead(summary.threadId)
        upsertRecentThread(summary)
    }

    @MainActor
    func markThreadRead(_ threadId: String) {
        unreadThreadIDs.remove(threadId)
    }

    @MainActor
    func noteConversationActivity(
        threadId: String,
        title: String? = nil,
        lastMessage: String,
        lastRole: String?,
        lastReplyTarget: String?,
        sessionKey: String? = nil,
        markUnread: Bool
    ) {
        let normalizedMessage = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessage.isEmpty else { return }
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)

        let summary = ConversationThreadSummary(
            threadId: threadId,
            title: (normalizedTitle?.isEmpty == false ? normalizedTitle : nil) ?? "Conversation",
            updatedAt: Date(),
            lastMessage: normalizedMessage,
            lastRole: lastRole,
            lastReplyTarget: lastReplyTarget,
            sessionKey: sessionKey
        )
        upsertRecentThread(summary)

        if markUnread, thread.id != threadId {
            unreadThreadIDs.insert(threadId)
        } else if thread.id == threadId {
            unreadThreadIDs.remove(threadId)
        }
    }

    @MainActor
    private func upsertRecentThread(_ summary: ConversationThreadSummary) {
        var next = recentThreads.filter { $0.threadId != summary.threadId }
        next.insert(summary, at: 0)
        recentThreads = next.sorted { $0.updatedAt > $1.updatedAt }
    }

    @MainActor
    func append(_ message: ChatMessage) {
        var current = thread
        current.messages.append(message)
        thread = current
        persistCurrentThread()
    }

    @MainActor
    func replaceMessage(
        id: UUID,
        role: ChatMessage.Role? = nil,
        style: ChatMessage.Style? = nil,
        rawTranscript: String? = nil,
        overrideRawTranscript: Bool = false,
        insertedText: String? = nil,
        overrideInsertedText: Bool = false,
        attachments: [ChatMessageAttachment]? = nil,
        showsAttachmentChip: Bool? = nil,
        with content: String
    ) {
        var current = thread
        guard let index = current.messages.firstIndex(where: { $0.id == id }) else { return }
        let existing = current.messages[index]
        current.messages[index] = ChatMessage(
            id: existing.id,
            role: role ?? existing.role,
            content: content,
            style: style ?? existing.style,
            rawTranscript: overrideRawTranscript ? rawTranscript : existing.rawTranscript,
            insertedText: overrideInsertedText ? insertedText : existing.insertedText,
            attachments: attachments ?? existing.attachments,
            showsAttachmentChip: showsAttachmentChip ?? existing.showsAttachmentChip,
            feedbackSubject: existing.feedbackSubject
        )
        thread = current
        persistCurrentThread()
    }

    @MainActor
    func replaceLastUserMessage(with content: String) {
        var current = thread
        guard let index = current.messages.lastIndex(where: { $0.role == .user }) else { return }
        current.messages[index] = ChatMessage(
            id: current.messages[index].id,
            role: .user,
            content: content,
            style: current.messages[index].style,
            rawTranscript: current.messages[index].rawTranscript,
            insertedText: current.messages[index].insertedText,
            attachments: current.messages[index].attachments,
            showsAttachmentChip: current.messages[index].showsAttachmentChip,
            feedbackSubject: current.messages[index].feedbackSubject
        )
        thread = current
        persistCurrentThread()
    }

    @MainActor
    func resetMessages() {
        let currentThreadId = loadOrCreateThreadID()
        thread = ChatThread(id: currentThreadId, messages: [])
        inFlight = nil
        persistCurrentThread()
    }

    @MainActor
    func resetThreadID() {
        let id = UUID().uuidString
        defaults.set(id, forKey: threadIDDefaultsKey())
        thread = ChatThread(id: id, messages: [])
        inFlight = nil
        persistCurrentThread()
    }

    @MainActor
    func setThread(id: String, messages: [ChatMessage] = []) {
        defaults.set(id, forKey: threadIDDefaultsKey())
        thread = ChatThread(id: id, messages: messages)
        inFlight = nil
        unreadThreadIDs.remove(id)
        persistCurrentThread()
    }

    @MainActor
    func openPersistedThread(id: String, fallbackMessages: [ChatMessage] = []) {
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }

        defaults.set(trimmedId, forKey: threadIDDefaultsKey())
        let restoredThread = threadStore.load(threadId: trimmedId)
            ?? ChatThread(id: trimmedId, messages: fallbackMessages)
        thread = restoredThread
        inFlight = nil
        unreadThreadIDs.remove(trimmedId)
        threadStore.save(restoredThread)
    }

    private func threadIDDefaultsKey() -> String {
        "chat_thread_id_elson"
    }

    private func loadOrCreateThreadID() -> String {
        let key = threadIDDefaultsKey()
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: key)
        return created
    }

    private func persistCurrentThread() {
        threadStore.save(thread)
    }

    private func mergedMessages(existing: [ChatMessage], appending tail: [ChatMessage]) -> [ChatMessage] {
        var seenIDs = Set(existing.map(\.id))
        var merged = existing
        for message in tail where !seenIDs.contains(message.id) {
            merged.append(message)
            seenIDs.insert(message.id)
        }
        return merged
    }

    @MainActor
    func hardReset() {
        threadStore.clear()
        defaults.removeObject(forKey: threadIDDefaultsKey())
        let freshThreadId = loadOrCreateThreadID()
        thread = ChatThread(id: freshThreadId, messages: [])
        inFlight = nil
        recentThreads = []
        historyHasMore = false
        historyLoading = false
        historyError = nil
        unreadThreadIDs = []
        historyOffset = 0
        persistCurrentThread()
    }
}
