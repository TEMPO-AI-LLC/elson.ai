import Foundation

struct TranscriptHistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let rawTranscript: String?
    let createdAt: Date
    let source: String
    let threadId: String?
    let replyMode: String?
    let actualRoute: String?
    let routingSource: String?
    let forcedRouteReason: String?
    let summaryTitle: String?

    init(
        id: UUID = UUID(),
        text: String,
        rawTranscript: String? = nil,
        createdAt: Date = Date(),
        source: String,
        threadId: String? = nil,
        replyMode: String? = nil,
        actualRoute: String? = nil,
        routingSource: String? = nil,
        forcedRouteReason: String? = nil,
        summaryTitle: String? = nil
    ) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRawTranscript = rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawTranscript = trimmedRawTranscript?.isEmpty == false ? trimmedRawTranscript : nil
        self.createdAt = createdAt
        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedThreadId = threadId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadId = trimmedThreadId?.isEmpty == false ? trimmedThreadId : nil
        let trimmedReplyMode = replyMode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.replyMode = trimmedReplyMode?.isEmpty == false ? trimmedReplyMode : nil
        let trimmedActualRoute = actualRoute?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.actualRoute = trimmedActualRoute?.isEmpty == false ? trimmedActualRoute : nil
        let trimmedRoutingSource = routingSource?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.routingSource = trimmedRoutingSource?.isEmpty == false ? trimmedRoutingSource : nil
        let trimmedForcedRouteReason = forcedRouteReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forcedRouteReason = trimmedForcedRouteReason?.isEmpty == false ? trimmedForcedRouteReason : nil
        let trimmedSummaryTitle = summaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summaryTitle = trimmedSummaryTitle?.isEmpty == false ? trimmedSummaryTitle : nil
    }

    var displayTitle: String {
        summaryTitle ?? source.capitalized
    }

    var isNavigable: Bool {
        threadId != nil
    }

    func withSummaryTitle(_ title: String?) -> TranscriptHistoryEntry {
        TranscriptHistoryEntry(
            id: id,
            text: text,
            rawTranscript: rawTranscript,
            createdAt: createdAt,
            source: source,
            threadId: threadId,
            replyMode: replyMode,
            actualRoute: actualRoute,
            routingSource: routingSource,
            forcedRouteReason: forcedRouteReason,
            summaryTitle: title
        )
    }
}

final class TranscriptHistoryStore: @unchecked Sendable {
    static let shared = TranscriptHistoryStore()

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxEntries = 25
    private let csvExportQueue = DispatchQueue(label: "ai.elson.desktop.transcript-csv-export", qos: .utility)

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [TranscriptHistoryEntry] {
        let url = storageURL()
        guard fileManager.fileExists(atPath: url.path) else { return [] }

        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode([TranscriptHistoryEntry].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            print("Failed to load transcript history: \(error)")
            return []
        }
    }

    func save(_ entries: [TranscriptHistoryEntry]) {
        let url = storageURL()
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let capped = Array(entries.sorted { $0.createdAt > $1.createdAt }.prefix(maxEntries))
            let data = try encoder.encode(capped)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("Failed to save transcript history: \(error)")
        }
    }

    func clear() {
        let url = storageURL()
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            print("Failed to clear transcript history: \(error)")
        }
    }

    func exportToWorkspaceCSV(_ entry: TranscriptHistoryEntry) {
        csvExportQueue.async { [weak self] in
            self?.appendTranscriptEntryToWorkspaceCSV(entry)
        }
    }

    @discardableResult
    func initializeWorkspaceCSV(on date: Date = Date()) -> Bool {
        let initEntry = TranscriptHistoryEntry(
            text: "Elson workspace initialized.",
            rawTranscript: nil,
            createdAt: date,
            source: "workspace_init"
        )

        return ElsonLocalConfigStore.shared.withWorkspaceFolderAccess { folderURL in
            appendTranscriptEntryToWorkspaceCSV(initEntry, folderURL: folderURL)
        } ?? false
    }

    private func storageURL() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
        return base
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("transcript-history.json")
    }

    @discardableResult
    private func appendTranscriptEntryToWorkspaceCSV(_ entry: TranscriptHistoryEntry, folderURL: URL? = nil) -> Bool {
        if let folderURL {
            return appendTranscriptEntryToWorkspaceCSV(entry, in: folderURL)
        }

        return ElsonLocalConfigStore.shared.withWorkspaceFolderAccess { folderURL in
            appendTranscriptEntryToWorkspaceCSV(entry, in: folderURL)
        } ?? false
    }

    private func appendTranscriptEntryToWorkspaceCSV(_ entry: TranscriptHistoryEntry, in folderURL: URL) -> Bool {
        let fileURL = folderURL.appendingPathComponent(dailyCSVFileName(for: entry.createdAt))
        let row = [
            csvEscaped(isoTimestamp(for: entry.createdAt)),
            csvEscaped(entry.source),
            csvEscaped(entry.text),
            csvEscaped(entry.rawTranscript ?? "")
        ]
        .joined(separator: ",") + "\n"

        do {
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard let data = (csvHeader + row).data(using: .utf8) else {
                    return false
                }
                try data.write(to: fileURL, options: [.atomic])
                return true
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = row.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            return true
        } catch {
            print("Failed to append transcript CSV at \(fileURL.path): \(error)")
            return false
        }
    }

    private func dailyCSVFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "ddMMyyyy"
        return "\(formatter.string(from: date))_elson.csv"
    }

    private var csvHeader: String {
        "created_at,source,text,raw_transcript\n"
    }

    private func isoTimestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func csvEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
