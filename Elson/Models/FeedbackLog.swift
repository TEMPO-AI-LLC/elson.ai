import Foundation

enum FeedbackRating: String, Codable, CaseIterable, Hashable {
    case good
    case bad
}

enum FeedbackRouteOverride: String, Codable, CaseIterable, Hashable {
    case unchanged
    case directTranscript = "direct_transcript"
    case fullAgent = "full_agent"
}

struct FeedbackSubject: Codable, Hashable {
    let requestId: String
    let threadId: String?
    let rawTranscript: String?
    let processedText: String
    let replyMode: String
    let actualRoute: String
    let sourceSurface: String
    let routingSource: String
    let forcedRouteReason: String?
    let debugReason: String
    let visibleOutputSource: String
    let hasScreenContext: Bool

    init(
        requestId: String,
        threadId: String?,
        rawTranscript: String?,
        processedText: String,
        replyMode: String,
        actualRoute: String,
        sourceSurface: String,
        routingSource: String,
        forcedRouteReason: String?,
        debugReason: String,
        visibleOutputSource: String,
        hasScreenContext: Bool
    ) {
        self.requestId = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedThreadId = threadId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadId = trimmedThreadId?.isEmpty == false ? trimmedThreadId : nil
        let trimmedRawTranscript = rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawTranscript = trimmedRawTranscript?.isEmpty == false ? trimmedRawTranscript : nil
        self.processedText = processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.replyMode = replyMode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.actualRoute = actualRoute.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceSurface = sourceSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        self.routingSource = routingSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedForcedRouteReason = forcedRouteReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forcedRouteReason = trimmedForcedRouteReason?.isEmpty == false ? trimmedForcedRouteReason : nil
        self.debugReason = debugReason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.visibleOutputSource = visibleOutputSource.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hasScreenContext = hasScreenContext
    }

    var isUsableForFeedback: Bool {
        !processedText.isEmpty || (rawTranscript?.isEmpty == false)
    }
}

struct FeedbackEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let rating: FeedbackRating
    let note: String?
    let expectedRouteOverride: String?
    let actualRoute: String
    let requestId: String
    let threadId: String?
    let createdAt: Date
    let submittedAt: Date
    let rawTranscript: String?
    let processedText: String
    let replyMode: String
    let sourceSurface: String

    init(
        id: UUID = UUID(),
        rating: FeedbackRating,
        note: String?,
        expectedRouteOverride: String?,
        actualRoute: String,
        requestId: String,
        threadId: String?,
        createdAt: Date,
        submittedAt: Date = Date(),
        rawTranscript: String?,
        processedText: String,
        replyMode: String,
        sourceSurface: String
    ) {
        self.id = id
        self.rating = rating
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = trimmedNote?.isEmpty == false ? trimmedNote : nil
        let trimmedOverride = expectedRouteOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.expectedRouteOverride = trimmedOverride?.isEmpty == false ? trimmedOverride : nil
        self.actualRoute = actualRoute.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestId = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedThreadId = threadId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadId = trimmedThreadId?.isEmpty == false ? trimmedThreadId : nil
        self.createdAt = createdAt
        self.submittedAt = submittedAt
        let trimmedRawTranscript = rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawTranscript = trimmedRawTranscript?.isEmpty == false ? trimmedRawTranscript : nil
        self.processedText = processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.replyMode = replyMode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceSurface = sourceSurface.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class FeedbackLogStore: @unchecked Sendable {
    static let shared = FeedbackLogStore()

    private let encoder = JSONEncoder()
    private let appendQueue = DispatchQueue(label: "ai.elson.desktop.feedback-log", qos: .utility)
    private let fileURL: URL

    init(fileURL: URL = DebugLog.logsDirectoryURL().appendingPathComponent("feedback.jsonl")) {
        self.fileURL = fileURL
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    @discardableResult
    func append(_ entry: FeedbackEntry) -> Bool {
        appendQueue.sync { [encoder, fileURL] in
            do {
                let directoryURL = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }

                let data = try encoder.encode(entry)
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data("\n".utf8))
                return true
            } catch {
                DebugLog.runtimeError("feedback_log_append_failed path=\(fileURL.path) error=\(error.localizedDescription)")
                return false
            }
        }
    }
}
