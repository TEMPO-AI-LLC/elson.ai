import Foundation

struct PersistedHostedChunkedAudioDraft: Codable, Equatable, Sendable {
    let rawTranscript: String
    var transcriptRawText: String? = nil
    var agentIntentRawText: String? = nil
    let snippetCount: Int
    var transcriptSnippetCount: Int? = nil
    var agentIntentSnippetCount: Int? = nil
    var isPartial: Bool? = nil
    var failedChunkIndices: [Int]? = nil
    var partialReason: String? = nil
}

struct PersistedHostedChunkedAudioRecord: Codable, Equatable, Sendable {
    let index: Int
    var phase: String? = nil
    let audioFilePath: String
    let byteCount: Int
    var status: String
    var transcript: String?
    var errorMessage: String?
    var transcribingStartedAt: Date?
    var completedAt: Date?
}

struct PersistedHostedChunkedAudioSession: Codable, Equatable, Sendable {
    let sessionId: String
    let createdAt: Date
    var updatedAt: Date
    var chunks: [PersistedHostedChunkedAudioRecord]
    var finalizedDraft: PersistedHostedChunkedAudioDraft?
}

final class HostedChunkedAudioRetryStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let rootURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func stageChunkFile(sessionId: String, index: Int, sourceURL: URL) throws -> URL {
        let sessionDirectory = sessionDirectoryURL(sessionId: sessionId)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let pathExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let destinationURL = sessionDirectory.appendingPathComponent(
            String(format: "chunk-%04d.%@", index, pathExtension)
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func save(_ snapshot: PersistedHostedChunkedAudioSession) throws {
        let sessionDirectory = sessionDirectoryURL(sessionId: snapshot.sessionId)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: metadataURL(sessionId: snapshot.sessionId), options: [.atomic])
    }

    func load(sessionId: String) throws -> PersistedHostedChunkedAudioSession {
        let data = try Data(contentsOf: metadataURL(sessionId: sessionId))
        return try decoder.decode(PersistedHostedChunkedAudioSession.self, from: data)
    }

    func removeSession(sessionId: String) {
        let sessionDirectory = sessionDirectoryURL(sessionId: sessionId)
        guard fileManager.fileExists(atPath: sessionDirectory.path) else { return }
        try? fileManager.removeItem(at: sessionDirectory)
    }

    func sessionDirectoryURL(sessionId: String) -> URL {
        rootURL.appendingPathComponent(sessionId, isDirectory: true)
    }

    private func metadataURL(sessionId: String) -> URL {
        sessionDirectoryURL(sessionId: sessionId).appendingPathComponent("metadata.json")
    }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("PendingAudioSessions", isDirectory: true)
    }
}
