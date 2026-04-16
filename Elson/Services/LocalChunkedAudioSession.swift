import Foundation

enum LocalChunkedAudioSessionError: LocalizedError {
    case notRecording
    case missingFinalChunk
    case notStopped
    case emptyTranscript
    case chunkTranscriptionFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .notRecording:
            return "Audio session is not recording."
        case .missingFinalChunk:
            return "No audio chunk captured."
        case .notStopped:
            return "Audio session must be stopped before finalizing."
        case .emptyTranscript:
            return "No usable transcript was produced."
        case let .chunkTranscriptionFailed(index, message):
            return "Chunk \(index + 1) transcription failed: \(message)"
        }
    }
}

struct LocalChunkedAudioDraft: Sendable {
    let rawTranscript: String
    let snippetCount: Int
    let recordingStartedAt: Date?
    let recordingStoppedAt: Date?
    let firstChunkTranscriptionCompletedAt: Date?
}

@MainActor
final class LocalChunkedAudioSession {
    enum State {
        case idle
        case recording
        case stopped
    }

    enum ChunkStatus: String {
        case queued
        case transcribing
        case completed
        case failed
    }

    struct ChunkRecord {
        let index: Int
        let audioURL: URL
        let byteCount: Int
        var status: ChunkStatus
        var transcript: String?
        var errorMessage: String?
        var transcribingStartedAt: Date?
        var completedAt: Date?
    }

    private let recordingService: AudioRecordingService
    private let groqAPIKey: String
    private let chunkDuration: TimeInterval
    private let aiService = LocalAIService()
    private let retryStore: LocalChunkedAudioRetryStore
    private let sessionId = UUID().uuidString
    private let requestLogContext: LocalRequestLogContext?
    private let maxChunkTranscriptionAttempts = 4

    private(set) var state: State = .idle
    private var startedAt: Date?
    private var nextChunkIndex = 0
    private var chunkTasks: [Int: Task<String, Error>] = [:]
    private var chunkRecords: [Int: ChunkRecord] = [:]
    private var finalizedDraft: LocalChunkedAudioDraft?
    private var stoppedAt: Date?

    init(
        recordingService: AudioRecordingService,
        groqAPIKey: String,
        chunkDuration: TimeInterval = 30,
        requestLogContext: LocalRequestLogContext? = nil,
        retryStore: LocalChunkedAudioRetryStore = LocalChunkedAudioRetryStore()
    ) {
        self.recordingService = recordingService
        self.groqAPIKey = groqAPIKey
        self.chunkDuration = chunkDuration
        self.requestLogContext = requestLogContext
        self.retryStore = retryStore
    }

    var isRecording: Bool { state == .recording }
    var isStopped: Bool { state == .stopped }
    var requestId: String? { requestLogContext?.requestId }

    func start() -> Bool {
        guard state == .idle else { return false }
        startedAt = Date()
        finalizedDraft = nil
        chunkTasks = [:]
        chunkRecords = [:]
        nextChunkIndex = 0
        stoppedAt = nil

        let started = recordingService.startChunkedRecording(
            chunkDuration: chunkDuration,
            startingIndex: nextChunkIndex
        ) { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.enqueueChunkTranscription(chunk)
            }
        }

        state = started ? .recording : .idle
        if !started {
            startedAt = nil
            DebugLog.runtimeError(
                "audio_chunk_session_start_failed audio_session_id=\(sessionId) chunk_duration_s=\(Int(chunkDuration))"
            )
        } else {
            DebugLog.runtime(
                "audio_chunk_session_started audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_duration_s=\(Int(chunkDuration))"
            )
            persistSessionSnapshot()
        }
        return started
    }

    func stopRecordingDiscardingIfShorterThan(_ minimumDuration: TimeInterval) async throws -> Bool {
        let stageStartedAt = Date()
        if let requestLogContext {
            DebugLog.requestStageStart(
                RequestTimelineSnapshot(
                    requestId: requestLogContext.requestId,
                    threadId: requestLogContext.threadId,
                    surface: requestLogContext.surface,
                    inputSource: requestLogContext.inputSource
                ),
                stage: .audioCaptureFinalize,
                metadata: "audio_session_id=\(sessionId)"
            )
        }
        guard state == .recording else { throw LocalChunkedAudioSessionError.notRecording }
        guard let finalChunk = recordingService.stopChunkedRecording() else {
            state = .idle
            startedAt = nil
            DebugLog.runtimeError(
                "audio_chunk_session_stop_failed audio_session_id=\(sessionId) reason=missing_final_chunk"
            )
            throw LocalChunkedAudioSessionError.missingFinalChunk
        }

        let totalDuration = Date().timeIntervalSince(startedAt ?? Date())
        if totalDuration < minimumDuration {
            try? FileManager.default.removeItem(at: finalChunk.url)
            cancelPendingTasks()
            let sessionStartedAt = startedAt
            state = .idle
            startedAt = nil
            cleanupPersistedSession()
            if let requestLogContext {
                DebugLog.requestStageEnd(
                    RequestTimelineSnapshot(
                        requestId: requestLogContext.requestId,
                        threadId: requestLogContext.threadId,
                        surface: requestLogContext.surface,
                        inputSource: requestLogContext.inputSource
                    ),
                    stage: .audioCaptureFinalize,
                    durationMS: Int(Date().timeIntervalSince(stageStartedAt) * 1000),
                    metadata: "audio_session_id=\(sessionId) discarded=true"
                )
            }
            DebugLog.runtime(
                "audio_chunk_session_discarded audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(sessionStartedAt)) total_duration_s=\(String(format: "%.2f", totalDuration))"
            )
            return false
        }

        enqueueChunkTranscription(finalChunk)
        state = .stopped
        stoppedAt = Date()
        if let requestLogContext {
            let durationMS = Int(Date().timeIntervalSince(stageStartedAt) * 1000)
            DebugLog.requestStageEnd(
                RequestTimelineSnapshot(
                    requestId: requestLogContext.requestId,
                    threadId: requestLogContext.threadId,
                    surface: requestLogContext.surface,
                    inputSource: requestLogContext.inputSource
                ),
                stage: .audioCaptureFinalize,
                durationMS: durationMS,
                metadata: "audio_session_id=\(sessionId) kept=true"
            )
        }
        DebugLog.runtime(
            "audio_chunk_session_stopped audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) total_duration_s=\(String(format: "%.2f", totalDuration)) snippet_count=\(chunkRecords.count)"
        )
        return true
    }

    func finalize() async throws -> LocalChunkedAudioDraft {
        if let finalizedDraft {
            return finalizedDraft
        }
        guard state == .stopped else { throw LocalChunkedAudioSessionError.notStopped }

        let stageStartedAt = Date()
        if let requestLogContext {
            DebugLog.requestStageStart(
                RequestTimelineSnapshot(
                    requestId: requestLogContext.requestId,
                    threadId: requestLogContext.threadId,
                    surface: requestLogContext.surface,
                    inputSource: requestLogContext.inputSource
                ),
                stage: .groqTranscription,
                metadata: "audio_session_id=\(sessionId) snippet_count=\(chunkTasks.count)"
            )
        }

        DebugLog.runtime(
            "audio_chunk_finalize_started audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) snippet_count=\(chunkTasks.count) completed=\(chunkCount(for: .completed)) transcribing=\(chunkCount(for: .transcribing)) queued=\(chunkCount(for: .queued)) failed=\(chunkCount(for: .failed))"
        )

        let tasks = chunkTasks.keys.sorted().compactMap { index in
            chunkTasks[index].map { (index, $0) }
        }

        for (index, task) in tasks {
            do {
                _ = try await task.value
            } catch {
                DebugLog.runtimeError(
                    "audio_chunk_finalize_retry_needed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index) error=\(error.localizedDescription)"
                )
            }
        }
        chunkTasks = [:]

        try await retryIncompleteChunks()

        let orderedSnippets = chunkRecords.values
            .sorted { $0.index < $1.index }
            .compactMap { record -> String? in
                let trimmedTranscript = record.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmedTranscript.isEmpty ? nil : trimmedTranscript
            }

        let rawTranscript = orderedSnippets
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTranscript.isEmpty else {
            DebugLog.runtimeError(
                "audio_chunk_finalize_failed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) reason=empty_transcript"
            )
            throw LocalChunkedAudioSessionError.emptyTranscript
        }

        let draft = LocalChunkedAudioDraft(
            rawTranscript: rawTranscript,
            snippetCount: orderedSnippets.count,
            recordingStartedAt: startedAt,
            recordingStoppedAt: stoppedAt,
            firstChunkTranscriptionCompletedAt: chunkRecords.values
                .compactMap(\.completedAt)
                .min()
        )
        finalizedDraft = draft
        persistSessionSnapshot()
        if let requestLogContext {
            DebugLog.requestStageEnd(
                RequestTimelineSnapshot(
                    requestId: requestLogContext.requestId,
                    threadId: requestLogContext.threadId,
                    surface: requestLogContext.surface,
                    inputSource: requestLogContext.inputSource
                ),
                stage: .groqTranscription,
                durationMS: Int(Date().timeIntervalSince(stageStartedAt) * 1000),
                metadata: "audio_session_id=\(sessionId) snippet_count=\(orderedSnippets.count)"
            )
        }
        DebugLog.runtime(
            "audio_chunk_finalize_completed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) snippet_count=\(orderedSnippets.count) transcript_chars=\(rawTranscript.count)"
        )
        return draft
    }

    func markDeliveryCompleted() {
        cancelPendingTasks()
        finalizedDraft = nil
        startedAt = nil
        stoppedAt = nil
        state = .idle
        cleanupPersistedSession()
        DebugLog.runtime("audio_chunk_delivery_completed audio_session_id=\(sessionId)")
    }

    func cancel() {
        if state == .recording, let finalChunk = recordingService.stopChunkedRecording() {
            try? FileManager.default.removeItem(at: finalChunk.url)
        }
        cancelPendingTasks()
        state = .idle
        startedAt = nil
        stoppedAt = nil
        finalizedDraft = nil
        cleanupPersistedSession()
        DebugLog.runtime("audio_chunk_session_cancelled audio_session_id=\(sessionId)")
    }

    private func enqueueChunkTranscription(_ chunk: AudioRecordingService.AudioChunk) {
        guard chunkTasks[chunk.index] == nil else { return }
        nextChunkIndex = max(nextChunkIndex, chunk.index + 1)
        let persistedURL = persistChunkAudio(chunk)
        let byteCount = chunkByteCount(at: persistedURL)
        chunkRecords[chunk.index] = ChunkRecord(
            index: chunk.index,
            audioURL: persistedURL,
            byteCount: byteCount,
            status: .queued,
            transcript: nil,
            errorMessage: nil,
            transcribingStartedAt: nil,
            completedAt: nil
        )
        persistSessionSnapshot()
        DebugLog.runtime(
            "audio_chunk_rotated audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(chunk.index) snippet_count=\(chunkRecords.count) file_bytes=\(byteCount) status=queued"
        )
        let task = Task<String, Error> {
            await MainActor.run {
                self.markChunkTranscribing(index: chunk.index)
            }
            do {
                let transcript = try await self.transcribeChunk(
                    index: chunk.index,
                    audioURL: persistedURL,
                    maxAttempts: self.maxChunkTranscriptionAttempts
                )
                await MainActor.run {
                    self.markChunkCompleted(index: chunk.index, transcript: transcript)
                }
                return transcript
            } catch {
                await MainActor.run {
                    self.markChunkFailed(index: chunk.index, error: error)
                }
                throw error
            }
        }
        chunkTasks[chunk.index] = task
    }

    private func cancelPendingTasks() {
        chunkTasks.values.forEach { $0.cancel() }
        chunkTasks = [:]
        chunkRecords = [:]
        nextChunkIndex = 0
    }

    private func markChunkTranscribing(index: Int) {
        guard var record = chunkRecords[index] else { return }
        record.status = .transcribing
        record.errorMessage = nil
        record.transcribingStartedAt = Date()
        chunkRecords[index] = record
        persistSessionSnapshot()
        DebugLog.runtime(
            "audio_chunk_transcription_started audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index) snippet_count=\(chunkRecords.count) file_bytes=\(record.byteCount)"
        )
    }

    private func markChunkCompleted(index: Int, transcript: String) {
        guard var record = chunkRecords[index] else { return }
        record.status = .completed
        record.transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        record.errorMessage = nil
        record.completedAt = Date()
        chunkRecords[index] = record
        persistSessionSnapshot()
        DebugLog.runtime(
            "audio_chunk_transcription_completed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index) snippet_count=\(chunkRecords.count) transcript_chars=\(record.transcript?.count ?? 0)"
        )
    }

    private func markChunkFailed(index: Int, error: Error) {
        guard var record = chunkRecords[index] else { return }
        record.status = .failed
        record.errorMessage = error.localizedDescription
        record.completedAt = Date()
        chunkRecords[index] = record
        persistSessionSnapshot()
        DebugLog.runtimeError(
            "audio_chunk_transcription_failed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index) snippet_count=\(chunkRecords.count) error=\(error.localizedDescription)"
        )
    }

    private func retryIncompleteChunks() async throws {
        let retryCandidates = chunkRecords.values
            .filter { $0.status != .completed }
            .sorted { $0.index < $1.index }

        for record in retryCandidates {
            guard FileManager.default.fileExists(atPath: record.audioURL.path) else {
                let missingFileError = NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileNoSuchFileError,
                    userInfo: [NSLocalizedDescriptionKey: "Saved audio chunk is missing."]
                )
                markChunkFailed(index: record.index, error: missingFileError)
                throw LocalChunkedAudioSessionError.chunkTranscriptionFailed(record.index, missingFileError.localizedDescription)
            }

            do {
                let transcript = try await transcribeChunk(
                    index: record.index,
                    audioURL: record.audioURL,
                    maxAttempts: maxChunkTranscriptionAttempts
                )
                markChunkCompleted(index: record.index, transcript: transcript)
            } catch {
                markChunkFailed(index: record.index, error: error)
                throw LocalChunkedAudioSessionError.chunkTranscriptionFailed(record.index, error.localizedDescription)
            }
        }
    }

    private func transcribeChunk(index: Int, audioURL: URL, maxAttempts: Int) async throws -> String {
        var attempt = 0

        while true {
            do {
                return try await aiService.transcribe(
                    audioURL: audioURL,
                    groqAPIKey: groqAPIKey,
                    logContext: requestLogContext,
                    extraMetadata: "audio_session_id=\(sessionId) chunk_index=\(index)"
                )
            } catch {
                attempt += 1
                if attempt >= maxAttempts {
                    throw error
                }
                let delaySeconds = min(Double(attempt), 3)
                DebugLog.runtime(
                    "audio_chunk_transcription_retry_scheduled audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index) attempt=\(attempt + 1) delay_s=\(String(format: "%.1f", delaySeconds)) error=\(error.localizedDescription)"
                )
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
    }

    private func persistChunkAudio(_ chunk: AudioRecordingService.AudioChunk) -> URL {
        do {
            return try retryStore.stageChunkFile(sessionId: sessionId, index: chunk.index, sourceURL: chunk.url)
        } catch {
            DebugLog.runtimeError(
                "audio_chunk_persist_failed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(chunk.index) error=\(error.localizedDescription)"
            )
            return chunk.url
        }
    }

    private func persistSessionSnapshot() {
        let snapshot = PersistedLocalChunkedAudioSession(
            sessionId: sessionId,
            createdAt: startedAt ?? Date(),
            updatedAt: Date(),
            chunks: chunkRecords.values
                .sorted { $0.index < $1.index }
                .map { record in
                    PersistedLocalChunkedAudioRecord(
                        index: record.index,
                        audioFilePath: record.audioURL.path,
                        byteCount: record.byteCount,
                        status: record.status.rawValue,
                        transcript: record.transcript,
                        errorMessage: record.errorMessage,
                        transcribingStartedAt: record.transcribingStartedAt,
                        completedAt: record.completedAt
                    )
                },
            finalizedDraft: finalizedDraft.map {
                PersistedLocalChunkedAudioDraft(
                    rawTranscript: $0.rawTranscript,
                    snippetCount: $0.snippetCount
                )
            }
        )

        do {
            try retryStore.save(snapshot)
        } catch {
            DebugLog.runtimeError(
                "audio_chunk_snapshot_save_failed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) error=\(error.localizedDescription)"
            )
        }
    }

    private func cleanupPersistedSession() {
        retryStore.removeSession(sessionId: sessionId)
    }

    private func chunkCount(for status: ChunkStatus) -> Int {
        chunkRecords.values.filter { $0.status == status }.count
    }

    private func chunkByteCount(at url: URL) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return size ?? 0
    }

    private func isoTimestamp(_ date: Date?) -> String {
        guard let date else { return "none" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
