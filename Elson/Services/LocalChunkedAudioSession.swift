import AVFoundation
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
            return "No speech detected."
        case let .chunkTranscriptionFailed(index, message):
            return "Chunk \(index + 1) transcription failed: \(message)"
        }
    }
}

struct LocalChunkedAudioDraft: Sendable {
    let rawTranscript: String
    let snippetCount: Int
    let transcriptChunkTimings: [ElsonTranscriptChunkTimingPayload]
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
        let transcriptionAudioURL: URL
        let transcriptionContextDuration: TimeInterval
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
    private let transcriptionOverlapDuration: TimeInterval
    private let aiService = LocalAIService()
    private let retryStore: LocalChunkedAudioRetryStore
    private let archiveStore: LocalCapturedAudioSessionStore
    private let sessionId = UUID().uuidString
    private let requestLogContext: LocalRequestLogContext?
    private var modeHint: InteractionMode?
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
        chunkDuration: TimeInterval = 25,
        transcriptionOverlapDuration: TimeInterval = 5,
        modeHint: InteractionMode? = nil,
        requestLogContext: LocalRequestLogContext? = nil,
        retryStore: LocalChunkedAudioRetryStore = LocalChunkedAudioRetryStore(),
        archiveStore: LocalCapturedAudioSessionStore = LocalCapturedAudioSessionStore()
    ) {
        self.recordingService = recordingService
        self.groqAPIKey = groqAPIKey
        self.chunkDuration = chunkDuration
        self.transcriptionOverlapDuration = transcriptionOverlapDuration
        self.modeHint = modeHint
        self.requestLogContext = requestLogContext
        self.retryStore = retryStore
        self.archiveStore = archiveStore
    }

    var isRecording: Bool { state == .recording }
    var isStopped: Bool { state == .stopped }
    var requestId: String? { requestLogContext?.requestId }
    var persistedSessionId: String { sessionId }

    func updateReplayContext(mode: InteractionMode, threadId: String? = nil) {
        modeHint = mode
        archiveStore.updateContext(
            sessionId: sessionId,
            threadId: threadId ?? requestLogContext?.threadId,
            mode: mode.rawValue
        )
    }

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
            do {
                _ = try archiveStore.createSession(
                    sessionId: sessionId,
                    createdAt: startedAt ?? Date(),
                    requestId: requestLogContext?.requestId,
                    threadId: requestLogContext?.threadId,
                    sourceSurface: requestLogContext?.surface,
                    mode: modeHint?.rawValue
                )
            } catch {
                DebugLog.runtimeError(
                    "audio_capture_archive_create_failed audio_session_id=\(sessionId) error=\(error.localizedDescription)"
                )
            }
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
            archiveStore.markStatus(
                sessionId: sessionId,
                status: .failed,
                errorMessage: LocalChunkedAudioSessionError.missingFinalChunk.localizedDescription
            )
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
            archiveStore.markStatus(sessionId: sessionId, status: .cancelled, errorMessage: "Recording too short.")
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
        do {
            _ = try archiveStore.writeAudioWAV(
                sessionId: sessionId,
                sourceURLs: chunkRecords.values.sorted { $0.index < $1.index }.map(\.audioURL)
            )
            archiveStore.markStatus(sessionId: sessionId, status: .stopped)
        } catch {
            DebugLog.runtimeError(
                "audio_capture_archive_wav_failed audio_session_id=\(sessionId) error=\(error.localizedDescription)"
            )
        }
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

        let orderedRecords = chunkRecords.values
            .sorted { $0.index < $1.index }
        let orderedSnippets = orderedRecords
            .compactMap { record -> String? in
                let trimmedTranscript = record.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmedTranscript.isEmpty ? nil : trimmedTranscript
            }

        let rawTranscript = orderedSnippets
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTranscript.isEmpty else {
            archiveStore.markStatus(
                sessionId: sessionId,
                status: .failed,
                errorMessage: LocalChunkedAudioSessionError.emptyTranscript.localizedDescription
            )
            DebugLog.runtimeError(
                "audio_chunk_finalize_failed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) reason=empty_transcript"
            )
            throw LocalChunkedAudioSessionError.emptyTranscript
        }

        let transcriptChunkTimings = makeTranscriptChunkTimings(from: orderedRecords)
        let draft = LocalChunkedAudioDraft(
            rawTranscript: rawTranscript,
            snippetCount: orderedSnippets.count,
            transcriptChunkTimings: transcriptChunkTimings,
            recordingStartedAt: startedAt,
            recordingStoppedAt: stoppedAt,
            firstChunkTranscriptionCompletedAt: chunkRecords.values
                .compactMap(\.completedAt)
                .min()
        )
        finalizedDraft = draft
        do {
            try archiveStore.writeRawTranscript(
                sessionId: sessionId,
                rawTranscript: rawTranscript,
                snippetCount: orderedSnippets.count,
                transcriptChunkTimings: transcriptChunkTimings,
                status: .ready
            )
        } catch {
            DebugLog.runtimeError(
                "audio_capture_archive_raw_failed audio_session_id=\(sessionId) error=\(error.localizedDescription)"
            )
        }
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
        archiveStore.markStatus(sessionId: sessionId, status: .delivered)
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
        archiveStore.markStatus(sessionId: sessionId, status: .cancelled)
        DebugLog.runtime("audio_chunk_session_cancelled audio_session_id=\(sessionId)")
    }

    private func enqueueChunkTranscription(_ chunk: AudioRecordingService.AudioChunk) {
        guard chunkTasks[chunk.index] == nil else { return }
        nextChunkIndex = max(nextChunkIndex, chunk.index + 1)
        let persistedURL = persistChunkAudio(chunk)
        do {
            _ = try archiveStore.stageChunkAudio(sessionId: sessionId, index: chunk.index, sourceURL: persistedURL)
        } catch {
            DebugLog.runtimeError(
                "audio_capture_archive_chunk_failed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(chunk.index) error=\(error.localizedDescription)"
            )
        }
        let byteCount = chunkByteCount(at: persistedURL)
        let transcriptionAudio = prepareTranscriptionAudio(index: chunk.index, currentURL: persistedURL)
        chunkRecords[chunk.index] = ChunkRecord(
            index: chunk.index,
            audioURL: persistedURL,
            transcriptionAudioURL: transcriptionAudio.url,
            transcriptionContextDuration: transcriptionAudio.contextDuration,
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
                    audioURL: transcriptionAudio.url,
                    overlapDuration: transcriptionAudio.contextDuration,
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
        persistPartialRawTranscript()
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
        archiveStore.markStatus(sessionId: sessionId, status: .failed, errorMessage: error.localizedDescription)
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
                    audioURL: record.transcriptionAudioURL,
                    overlapDuration: record.transcriptionContextDuration,
                    maxAttempts: maxChunkTranscriptionAttempts
                )
                markChunkCompleted(index: record.index, transcript: transcript)
            } catch {
                markChunkFailed(index: record.index, error: error)
                throw LocalChunkedAudioSessionError.chunkTranscriptionFailed(record.index, error.localizedDescription)
            }
        }
    }

    private func transcribeChunk(
        index: Int,
        audioURL: URL,
        overlapDuration: TimeInterval,
        maxAttempts: Int
    ) async throws -> String {
        var attempt = 0

        while true {
            do {
                let result = try await aiService.transcribeDetailed(
                    audioURL: audioURL,
                    groqAPIKey: groqAPIKey,
                    logContext: requestLogContext,
                    extraMetadata: "audio_session_id=\(sessionId) chunk_index=\(index) overlap_s=\(String(format: "%.1f", overlapDuration))"
                )
                if overlapDuration > 0 {
                    if let deduped = result.textDiscardingSegments(endingAtOrBefore: overlapDuration) {
                        DebugLog.runtime(
                            "audio_chunk_overlap_segments_discarded audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index) overlap_s=\(String(format: "%.1f", overlapDuration)) original_chars=\(result.text.count) deduped_chars=\(deduped.count)"
                        )
                        return deduped
                    }
                    DebugLog.runtime(
                        "audio_chunk_overlap_dedupe_fallback audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index) overlap_s=\(String(format: "%.1f", overlapDuration)) reason=missing_segment_timing"
                    )
                }
                return result.text
            } catch LocalAIServiceError.noSpeechDetected {
                DebugLog.runtime(
                    "audio_chunk_no_speech_discarded audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index)"
                )
                return ""
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

    private func prepareTranscriptionAudio(index: Int, currentURL: URL) -> (url: URL, contextDuration: TimeInterval) {
        guard transcriptionOverlapDuration > 0,
              let previousURL = previousOriginalChunkURL(before: index)
        else {
            return (currentURL, 0)
        }

        let outputURL = retryStore.sessionDirectoryURL(sessionId: sessionId)
            .appendingPathComponent(String(format: "transcription-%04d.wav", index))
        do {
            let contextDuration = try writeContextualTranscriptionWAV(
                previousURL: previousURL,
                currentURL: currentURL,
                tailDuration: transcriptionOverlapDuration,
                outputURL: outputURL
            )
            DebugLog.runtime(
                "audio_chunk_contextual_transcription_audio_created audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index) overlap_s=\(String(format: "%.1f", contextDuration)) file=\(outputURL.lastPathComponent)"
            )
            return (outputURL, contextDuration)
        } catch {
            DebugLog.runtimeError(
                "audio_chunk_contextual_transcription_audio_failed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index) error=\(error.localizedDescription)"
            )
            return (currentURL, 0)
        }
    }

    private func previousOriginalChunkURL(before index: Int) -> URL? {
        chunkRecords.values
            .filter { $0.index < index }
            .sorted { $0.index > $1.index }
            .map(\.audioURL)
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    private func writeContextualTranscriptionWAV(
        previousURL: URL,
        currentURL: URL,
        tailDuration: TimeInterval,
        outputURL: URL
    ) throws -> TimeInterval {
        let previousInput = try AVAudioFile(forReading: previousURL)
        let currentInput = try AVAudioFile(forReading: currentURL)
        let format = currentInput.processingFormat
        let previousFormat = previousInput.processingFormat
        guard previousFormat.sampleRate == format.sampleRate,
              previousFormat.channelCount == format.channelCount
        else {
            throw NSError(
                domain: "ai.elson.desktop.audio-context",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio chunk formats differ."]
            )
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

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

        let requestedTailFrames = AVAudioFramePosition(tailDuration * previousFormat.sampleRate)
        let tailFrames = min(previousInput.length, max(0, requestedTailFrames))
        previousInput.framePosition = max(0, previousInput.length - tailFrames)
        try write(input: previousInput, to: output)
        try write(input: currentInput, to: output)
        return previousFormat.sampleRate > 0 ? TimeInterval(tailFrames) / previousFormat.sampleRate : 0
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

    private func persistPartialRawTranscript() {
        let orderedSnippets = chunkRecords.values
            .sorted { $0.index < $1.index }
            .compactMap { record -> String? in
                let trimmedTranscript = record.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmedTranscript.isEmpty ? nil : trimmedTranscript
            }
        let rawTranscript = orderedSnippets.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTranscript.isEmpty else { return }

        do {
            try archiveStore.writeRawTranscript(
                sessionId: sessionId,
                rawTranscript: rawTranscript,
                snippetCount: orderedSnippets.count,
                transcriptChunkTimings: makeTranscriptChunkTimings(from: chunkRecords.values.sorted { $0.index < $1.index }),
                status: state == .stopped ? .ready : .transcribing
            )
        } catch {
            DebugLog.runtimeError(
                "audio_capture_archive_partial_raw_failed audio_session_id=\(sessionId) error=\(error.localizedDescription)"
            )
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

    private func makeTranscriptChunkTimings(from records: [ChunkRecord]) -> [ElsonTranscriptChunkTimingPayload] {
        var currentStart: TimeInterval = 0
        var includedSnippetIndex = 0

        return records.map { record in
            let duration = audioDuration(at: record.audioURL) ?? chunkDuration
            let audioStart = currentStart
            let audioEnd = audioStart + max(0, duration)
            let overlapDuration = min(max(0, record.transcriptionContextDuration), audioStart)
            let payloadStart = max(0, audioStart - overlapDuration)
            let payloadEnd = audioEnd
            let trimmedTranscript = record.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let snippetIndex: Int?
            if trimmedTranscript.isEmpty {
                snippetIndex = nil
            } else {
                snippetIndex = includedSnippetIndex
                includedSnippetIndex += 1
            }

            currentStart = audioEnd
            return ElsonTranscriptChunkTimingPayload(
                index: record.index,
                transcriptSnippetIndex: snippetIndex,
                audioStartSeconds: audioStart,
                audioEndSeconds: audioEnd,
                asrPayloadStartSeconds: payloadStart,
                asrPayloadEndSeconds: payloadEnd,
                overlapStartSeconds: overlapDuration > 0 ? payloadStart : nil,
                overlapEndSeconds: overlapDuration > 0 ? audioStart : nil,
                overlapDurationSeconds: overlapDuration,
                keptTranscriptStartSeconds: audioStart,
                keptTranscriptEndSeconds: audioEnd
            )
        }
    }

    private func audioDuration(at url: URL) -> TimeInterval? {
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.fileFormat.sampleRate > 0 else { return nil }
            return TimeInterval(file.length) / file.fileFormat.sampleRate
        } catch {
            DebugLog.runtimeError(
                "audio_chunk_duration_read_failed audio_session_id=\(sessionId) file=\(url.lastPathComponent) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private func isoTimestamp(_ date: Date?) -> String {
        guard let date else { return "none" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
