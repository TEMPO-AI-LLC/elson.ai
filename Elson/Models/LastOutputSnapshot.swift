import Foundation

struct LastOutputSnapshot: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let processedText: String
    let rawTranscript: String?
    let replyMode: String
    let sourceSurface: String
    let requestId: String
    let threadId: String?
    let actualRoute: String
    let routingSource: String
    let forcedRouteReason: String?
    let debugReason: String
    let visibleOutputSource: String
    let hasScreenContext: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        processedText: String,
        rawTranscript: String?,
        replyMode: String,
        sourceSurface: String,
        requestId: String,
        threadId: String?,
        actualRoute: String,
        routingSource: String,
        forcedRouteReason: String?,
        debugReason: String,
        visibleOutputSource: String,
        hasScreenContext: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.processedText = processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRawTranscript = rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawTranscript = trimmedRawTranscript?.isEmpty == false ? trimmedRawTranscript : nil
        self.replyMode = replyMode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceSurface = sourceSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestId = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedThreadId = threadId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadId = trimmedThreadId?.isEmpty == false ? trimmedThreadId : nil
        self.actualRoute = actualRoute.trimmingCharacters(in: .whitespacesAndNewlines)
        self.routingSource = routingSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedForcedRouteReason = forcedRouteReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forcedRouteReason = trimmedForcedRouteReason?.isEmpty == false ? trimmedForcedRouteReason : nil
        self.debugReason = debugReason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.visibleOutputSource = visibleOutputSource.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hasScreenContext = hasScreenContext
        self.createdAt = createdAt
    }

    var hasRawTranscript: Bool {
        guard let rawTranscript else { return false }
        return !rawTranscript.isEmpty
    }

    var isUsableForFeedback: Bool {
        !processedText.isEmpty || hasRawTranscript
    }

    var feedbackSubject: FeedbackSubject {
        FeedbackSubject(
            requestId: requestId,
            threadId: threadId,
            rawTranscript: rawTranscript,
            processedText: processedText,
            replyMode: replyMode,
            actualRoute: actualRoute,
            sourceSurface: sourceSurface,
            routingSource: routingSource,
            forcedRouteReason: forcedRouteReason,
            debugReason: debugReason,
            visibleOutputSource: visibleOutputSource,
            hasScreenContext: hasScreenContext
        )
    }
}

struct ActiveFeedbackContext: Equatable {
    let snapshot: LastOutputSnapshot
    let openedAt: Date

    init(snapshot: LastOutputSnapshot, openedAt: Date = Date()) {
        self.snapshot = snapshot
        self.openedAt = openedAt
    }
}
