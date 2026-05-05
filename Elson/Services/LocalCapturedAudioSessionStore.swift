import AVFoundation
import Foundation

enum LocalCapturedAudioSessionStatus: String, Codable, Sendable {
    case recording
    case stopped
    case transcribing
    case ready
    case delivered
    case failed
    case cancelled
}

struct LocalCapturedAudioSessionSnapshot: Codable, Equatable, Identifiable, Sendable {
    let sessionId: String
    let directoryPath: String
    let createdAt: Date
    var updatedAt: Date
    var requestId: String?
    var threadId: String?
    var sourceSurface: String?
    var mode: String?
    var status: LocalCapturedAudioSessionStatus
    var errorMessage: String?
    var rawTranscript: String?
    var snippetCount: Int?
    var audioFilePath: String?
    var rawTranscriptFilePath: String?
    var chunkAudioFilePaths: [String]

    var id: String { sessionId }

    var sessionDirectoryURL: URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
    }
}

final class LocalCapturedAudioSessionStore: @unchecked Sendable {
    static let retentionDaysDefaultsKey = "captured_audio_retention_days"

    private let fileManager: FileManager
    private let rootURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let retentionDays: Int

    init(fileManager: FileManager = .default, rootURL: URL? = nil, retentionDays: Int? = nil) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        self.retentionDays = max(1, retentionDays ?? Self.defaultRetentionDays())
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    func createSession(
        sessionId: String,
        createdAt: Date,
        requestId: String?,
        threadId: String?,
        sourceSurface: String?,
        mode: String?
    ) throws -> LocalCapturedAudioSessionSnapshot {
        let directoryURL = makeSessionDirectoryURL(createdAt: createdAt, sessionId: sessionId)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var snapshot = LocalCapturedAudioSessionSnapshot(
            sessionId: sessionId,
            directoryPath: directoryURL.path,
            createdAt: createdAt,
            updatedAt: Date(),
            requestId: normalized(requestId),
            threadId: normalized(threadId),
            sourceSurface: normalized(sourceSurface),
            mode: normalized(mode),
            status: .recording,
            errorMessage: nil,
            rawTranscript: nil,
            snippetCount: nil,
            audioFilePath: nil,
            rawTranscriptFilePath: nil,
            chunkAudioFilePaths: []
        )
        try save(&snapshot)
        purgeExpiredSessions()
        return snapshot
    }

    func updateContext(sessionId: String, threadId: String?, mode: String?) {
        guard var snapshot = load(sessionId: sessionId) else { return }
        if let threadId = normalized(threadId) {
            snapshot.threadId = threadId
        }
        if let mode = normalized(mode) {
            snapshot.mode = mode
        }
        try? save(&snapshot)
    }

    func stageChunkAudio(sessionId: String, index: Int, sourceURL: URL) throws -> URL {
        var snapshot = try loadOrCreateFallback(sessionId: sessionId)
        let chunksDirectory = snapshot.sessionDirectoryURL.appendingPathComponent("chunks", isDirectory: true)
        try fileManager.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)

        let pathExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let destinationURL = chunksDirectory.appendingPathComponent(
            String(format: "chunk-%04d.%@", index, pathExtension)
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        var paths = snapshot.chunkAudioFilePaths.filter { $0 != destinationURL.path }
        paths.append(destinationURL.path)
        snapshot.chunkAudioFilePaths = paths.sorted()
        snapshot.status = snapshot.status == .failed ? .transcribing : snapshot.status
        try save(&snapshot)
        return destinationURL
    }

    @discardableResult
    func writeAudioWAV(sessionId: String, sourceURLs: [URL]) throws -> URL? {
        let readableURLs = sourceURLs.filter { fileManager.fileExists(atPath: $0.path) }
        guard !readableURLs.isEmpty else { return nil }

        var snapshot = try loadOrCreateFallback(sessionId: sessionId)
        let outputURL = snapshot.sessionDirectoryURL.appendingPathComponent("audio.wav")
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        try writeWAV(from: readableURLs, to: outputURL)
        snapshot.audioFilePath = outputURL.path
        snapshot.status = snapshot.status == .recording ? .stopped : snapshot.status
        try save(&snapshot)
        return outputURL
    }

    func writeRawTranscript(
        sessionId: String,
        rawTranscript: String,
        snippetCount: Int?,
        status: LocalCapturedAudioSessionStatus = .ready
    ) throws {
        var snapshot = try loadOrCreateFallback(sessionId: sessionId)
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = snapshot.sessionDirectoryURL.appendingPathComponent("raw.md")
        guard let data = (trimmed + "\n").data(using: .utf8) else { return }
        try data.write(to: rawURL, options: [.atomic])
        snapshot.rawTranscript = trimmed.isEmpty ? nil : trimmed
        snapshot.rawTranscriptFilePath = rawURL.path
        snapshot.snippetCount = snippetCount
        snapshot.status = status
        snapshot.errorMessage = nil
        try save(&snapshot)
    }

    func markStatus(sessionId: String, status: LocalCapturedAudioSessionStatus, errorMessage: String? = nil) {
        guard var snapshot = load(sessionId: sessionId) else { return }
        snapshot.status = status
        snapshot.errorMessage = normalized(errorMessage)
        try? save(&snapshot)
    }

    func load(sessionId: String) -> LocalCapturedAudioSessionSnapshot? {
        if let indexedURL = loadIndex()[sessionId].map(URL.init(fileURLWithPath:)),
           let snapshot = loadSnapshot(at: indexedURL) {
            return snapshot
        }

        guard let discovered = discoverMetadataURL(sessionId: sessionId),
              let snapshot = loadSnapshot(at: discovered)
        else {
            return nil
        }

        var index = loadIndex()
        index[sessionId] = discovered.path
        saveIndex(index)
        return snapshot
    }

    func recentSessions(limit: Int = 50) -> [LocalCapturedAudioSessionSnapshot] {
        metadataURLs().compactMap(loadSnapshot(at:))
            .sorted { left, right in
                if left.updatedAt == right.updatedAt {
                    return left.createdAt > right.createdAt
                }
                return left.updatedAt > right.updatedAt
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    func rawTranscript(sessionId: String) -> String? {
        guard let snapshot = load(sessionId: sessionId) else { return nil }
        if let path = snapshot.rawTranscriptFilePath,
           let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let trimmed = snapshot.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func audioURL(sessionId: String) -> URL? {
        guard let snapshot = load(sessionId: sessionId) else { return nil }
        if let path = snapshot.audioFilePath, fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return snapshot.chunkAudioFilePaths
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    func purgeExpiredSessions(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60))
        var index = loadIndex()
        for snapshot in recentSessions(limit: Int.max) where snapshot.createdAt < cutoff {
            try? fileManager.removeItem(at: snapshot.sessionDirectoryURL)
            index.removeValue(forKey: snapshot.sessionId)
        }
        saveIndex(index)
    }

    func purgeAllSessions() {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try? fileManager.removeItem(at: rootURL)
    }

    private func loadOrCreateFallback(sessionId: String) throws -> LocalCapturedAudioSessionSnapshot {
        if let snapshot = load(sessionId: sessionId) {
            return snapshot
        }
        return try createSession(
            sessionId: sessionId,
            createdAt: Date(),
            requestId: nil,
            threadId: nil,
            sourceSurface: nil,
            mode: nil
        )
    }

    private func save(_ snapshot: inout LocalCapturedAudioSessionSnapshot) throws {
        snapshot.updatedAt = Date()
        try fileManager.createDirectory(at: snapshot.sessionDirectoryURL, withIntermediateDirectories: true)
        let metadataURL = metadataURL(for: snapshot.sessionDirectoryURL)
        let data = try encoder.encode(snapshot)
        try data.write(to: metadataURL, options: [.atomic])

        var index = loadIndex()
        index[snapshot.sessionId] = metadataURL.path
        saveIndex(index)
    }

    private func writeWAV(from sourceURLs: [URL], to outputURL: URL) throws {
        let firstInput = try AVAudioFile(forReading: sourceURLs[0])
        let format = firstInput.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved
        ]
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        try write(input: firstInput, to: output)
        for sourceURL in sourceURLs.dropFirst() {
            let input = try AVAudioFile(forReading: sourceURL)
            try write(input: input, to: output)
        }
    }

    private func write(input: AVAudioFile, to output: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096) else {
            return
        }

        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    private func makeSessionDirectoryURL(createdAt: Date, sessionId: String) -> URL {
        let day = dayFormatter.string(from: createdAt)
        let time = timeFormatter.string(from: createdAt)
        let base = rootURL
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent(time, isDirectory: true)
        guard fileManager.fileExists(atPath: base.path) else { return base }
        return rootURL
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("\(time)-\(String(sessionId.prefix(8)))", isDirectory: true)
    }

    private func metadataURL(for directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("metadata.json")
    }

    private func indexURL() -> URL {
        rootURL.appendingPathComponent("index.json")
    }

    private func loadIndex() -> [String: String] {
        let url = indexURL()
        guard let data = try? Data(contentsOf: url),
              let index = try? decoder.decode([String: String].self, from: data)
        else {
            return [:]
        }
        return index
    }

    private func saveIndex(_ index: [String: String]) {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let data = try encoder.encode(index)
            try data.write(to: indexURL(), options: [.atomic])
        } catch {
            print("Failed to save captured audio session index: \(error)")
        }
    }

    private func metadataURLs() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.lastPathComponent == "metadata.json"
            else {
                return nil
            }
            return url
        }
    }

    private func discoverMetadataURL(sessionId: String) -> URL? {
        metadataURLs().first { url in
            loadSnapshot(at: url)?.sessionId == sessionId
        }
    }

    private func loadSnapshot(at url: URL) -> LocalCapturedAudioSessionSnapshot? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? decoder.decode(LocalCapturedAudioSessionSnapshot.self, from: data)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH-mm-ss"
        return formatter
    }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private static func defaultRetentionDays() -> Int {
        let stored = UserDefaults.standard.integer(forKey: retentionDaysDefaultsKey)
        return stored > 0 ? stored : 30
    }
}
