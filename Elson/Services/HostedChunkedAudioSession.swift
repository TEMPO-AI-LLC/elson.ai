import AVFoundation
import Foundation

@MainActor
protocol ChunkedAudioRecording: AnyObject {
    var activeRecordingStartedAt: Date? { get }

    func startChunkedRecording(
        chunkDuration: TimeInterval,
        startingIndex: Int,
        onChunk: @escaping (AudioRecordingService.AudioChunk) -> Void
    ) -> Bool

    func stopChunkedRecording() -> AudioRecordingService.AudioChunk?

    func rotateChunkNow() -> AudioRecordingService.AudioChunk?
}

extension AudioRecordingService: ChunkedAudioRecording {}

enum HostedChunkedAudioSessionError: LocalizedError {
    case notRecording
    case missingFinalChunk
    case notStopped
    case emptyTranscript
    case noUsableTranscript
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
        case .noUsableTranscript:
            return "Transcription failed. Replay available."
        case let .chunkTranscriptionFailed(index, message):
            return "Chunk \(index + 1) transcription failed: \(message)"
        }
    }
}

struct HostedChunkedAudioDraft: Sendable {
    let rawTranscript: String
    let transcriptRawText: String
    let agentIntentRawText: String
    let snippetCount: Int
    let transcriptSnippetCount: Int
    let agentIntentSnippetCount: Int
    let transcriptChunkTimings: [ElsonTranscriptChunkTimingPayload]
    let recordingStartedAt: Date?
    let recordingStoppedAt: Date?
    let firstChunkTranscriptionCompletedAt: Date?
    let isPartial: Bool
    let failedChunkIndices: [Int]
    let partialReason: String?
}

@MainActor
final class HostedChunkedAudioSession {
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

    enum ChunkPhase: String, Sendable {
        case transcript
        case agentIntent = "agent_intent"
    }

    struct ChunkRecord {
        let index: Int
        let phase: ChunkPhase
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

    private enum ChunkWaitEvent {
        case completed(Int)
        case failed(Int, String)
        case deadline
    }

    private let recordingService: any ChunkedAudioRecording
    private let groqAPIKey: String
    private let chunkDuration: TimeInterval
    private let transcriptionOverlapDuration: TimeInterval
    private let transcriber: any LocalAudioTranscribing
    private let retryStore: HostedChunkedAudioRetryStore
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
    private var finalizedDraft: HostedChunkedAudioDraft?
    private var stoppedAt: Date?
    private var ignoredChunkTaskIndices: Set<Int> = []
    private var agentIntentStartChunkIndex: Int?

    init(
        recordingService: any ChunkedAudioRecording,
        groqAPIKey: String,
        chunkDuration: TimeInterval = 25,
        transcriptionOverlapDuration: TimeInterval = 5,
        modeHint: InteractionMode? = nil,
        requestLogContext: LocalRequestLogContext? = nil,
        transcriber: any LocalAudioTranscribing = LocalAIService(),
        retryStore: HostedChunkedAudioRetryStore = HostedChunkedAudioRetryStore(),
        archiveStore: LocalCapturedAudioSessionStore = LocalCapturedAudioSessionStore()
    ) {
        self.recordingService = recordingService
        self.groqAPIKey = groqAPIKey
        self.chunkDuration = chunkDuration
        self.transcriptionOverlapDuration = transcriptionOverlapDuration
        self.modeHint = modeHint
        self.requestLogContext = requestLogContext
        self.transcriber = transcriber
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

    func markAgentIntentPhaseStarted() {
        guard state == .recording else { return }
        guard agentIntentStartChunkIndex == nil else { return }

        if let boundaryChunk = recordingService.rotateChunkNow() {
            enqueueChunkTranscription(boundaryChunk)
            agentIntentStartChunkIndex = max(nextChunkIndex, boundaryChunk.index + 1)
        } else {
            agentIntentStartChunkIndex = nextChunkIndex
        }
        modeHint = .agent
        archiveStore.updateContext(
            sessionId: sessionId,
            threadId: requestLogContext?.threadId,
            mode: InteractionMode.agent.rawValue
        )
        persistSessionSnapshot()
        DebugLog.runtime(
            "audio_chunk_agent_intent_phase_started audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) boundary_chunk_index=\(agentIntentStartChunkIndex ?? -1)"
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
        ignoredChunkTaskIndices = []
        agentIntentStartChunkIndex = nil

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
        guard state == .recording else { throw HostedChunkedAudioSessionError.notRecording }
        guard let finalChunk = recordingService.stopChunkedRecording() else {
            state = .idle
            startedAt = nil
            archiveStore.markStatus(
                sessionId: sessionId,
                status: .failed,
                errorMessage: HostedChunkedAudioSessionError.missingFinalChunk.localizedDescription
            )
            DebugLog.runtimeError(
                "audio_chunk_session_stop_failed audio_session_id=\(sessionId) reason=missing_final_chunk"
            )
            throw HostedChunkedAudioSessionError.missingFinalChunk
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

    func finalize(allowPartialAfter partialDeadline: TimeInterval? = nil) async throws -> HostedChunkedAudioDraft {
        if let finalizedDraft {
            return finalizedDraft
        }
        guard state == .stopped else { throw HostedChunkedAudioSessionError.notStopped }

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

        let deadlineTimedOutChunkIndices = await waitForChunkTasks(tasks, partialDeadline: partialDeadline)
        chunkTasks = [:]

        if partialDeadline == nil {
            try await retryIncompleteChunks()
        }

        let orderedRecords = chunkRecords.values
            .sorted { $0.index < $1.index }
        let orderedSnippets = transcriptSnippets(from: orderedRecords)
        let transcriptPhaseSnippets = transcriptSnippets(from: orderedRecords.filter { $0.phase == .transcript })
        let agentIntentPhaseSnippets = transcriptSnippets(from: orderedRecords.filter { $0.phase == .agentIntent })

        let rawTranscript = orderedSnippets
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptRawText = transcriptPhaseSnippets
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let agentIntentRawText = agentIntentPhaseSnippets
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTranscript.isEmpty else {
            archiveStore.markStatus(
                sessionId: sessionId,
                status: .failed,
                errorMessage: partialDeadline == nil
                    ? HostedChunkedAudioSessionError.emptyTranscript.localizedDescription
                    : HostedChunkedAudioSessionError.noUsableTranscript.localizedDescription
            )
            DebugLog.runtimeError(
                "audio_chunk_finalize_failed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) reason=empty_transcript"
            )
            throw partialDeadline == nil
                ? HostedChunkedAudioSessionError.emptyTranscript
                : HostedChunkedAudioSessionError.noUsableTranscript
        }

        let transcriptChunkTimings = makeTranscriptChunkTimings(from: orderedRecords)
        let failedChunkIndices = orderedRecords
            .filter { record in
                record.status == .failed || deadlineTimedOutChunkIndices.contains(record.index)
            }
            .map(\.index)
        let isPartial = partialDeadline != nil && !failedChunkIndices.isEmpty
        let partialReason = isPartial ? "transcription_deadline_or_chunk_failure" : nil
        let draft = HostedChunkedAudioDraft(
            rawTranscript: rawTranscript,
            transcriptRawText: transcriptRawText,
            agentIntentRawText: agentIntentRawText,
            snippetCount: orderedSnippets.count,
            transcriptSnippetCount: transcriptPhaseSnippets.count,
            agentIntentSnippetCount: agentIntentPhaseSnippets.count,
            transcriptChunkTimings: transcriptChunkTimings,
            recordingStartedAt: startedAt,
            recordingStoppedAt: stoppedAt,
            firstChunkTranscriptionCompletedAt: chunkRecords.values
                .compactMap(\.completedAt)
                .min(),
            isPartial: isPartial,
            failedChunkIndices: failedChunkIndices,
            partialReason: partialReason
        )
        finalizedDraft = draft
        do {
            try archiveStore.writeRawTranscript(
                sessionId: sessionId,
                rawTranscript: rawTranscript,
                snippetCount: orderedSnippets.count,
                transcriptChunkTimings: transcriptChunkTimings,
                status: isPartial ? .partial : .ready,
                isPartial: isPartial,
                partialReason: partialReason
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
                metadata: "audio_session_id=\(sessionId) snippet_count=\(orderedSnippets.count) partial=\(isPartial)"
            )
        }
        DebugLog.runtime(
            "audio_chunk_finalize_completed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) snippet_count=\(orderedSnippets.count) transcript_chars=\(rawTranscript.count) partial=\(isPartial) failed_chunks=\(failedChunkIndices.map(String.init).joined(separator: ","))"
        )
        return draft
    }

    private func waitForChunkTasks(
        _ tasks: [(index: Int, task: Task<String, Error>)],
        partialDeadline: TimeInterval?
    ) async -> Set<Int> {
        guard !tasks.isEmpty else { return [] }
        guard let partialDeadline else {
            for (index, task) in tasks {
                do {
                    _ = try await task.value
                } catch {
                    DebugLog.runtimeError(
                        "audio_chunk_finalize_retry_needed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index) error=\(error.localizedDescription)"
                    )
                }
            }
            return []
        }

        let timeoutNanoseconds = UInt64(max(0, partialDeadline) * 1_000_000_000)
        let stream = AsyncStream<ChunkWaitEvent> { continuation in
            for (index, task) in tasks {
                Task {
                    do {
                        _ = try await task.value
                        continuation.yield(.completed(index))
                    } catch {
                        continuation.yield(.failed(index, error.localizedDescription))
                    }
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                continuation.yield(.deadline)
            }
        }

        var pendingIndices = Set(tasks.map(\.index))
        var timedOutIndices: Set<Int> = []

        for await event in stream {
            switch event {
            case let .completed(index):
                pendingIndices.remove(index)
            case let .failed(index, message):
                pendingIndices.remove(index)
                DebugLog.runtimeError(
                    "audio_chunk_finalize_partial_candidate_failed audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(index) error=\(message)"
                )
            case .deadline:
                timedOutIndices = pendingIndices
                for index in timedOutIndices {
                    if let task = chunkTasks[index] {
                        task.cancel()
                    }
                    markChunkTimedOut(index: index, deadline: partialDeadline)
                }
                if !timedOutIndices.isEmpty {
                    DebugLog.runtimeError(
                        "audio_chunk_finalize_deadline_reached audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) deadline_s=\(String(format: "%.1f", partialDeadline)) timed_out_chunks=\(timedOutIndices.sorted().map(String.init).joined(separator: ","))"
                    )
                }
                break
            }

            if pendingIndices.isEmpty {
                break
            }
        }

        return timedOutIndices
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

    func markPartialDeliveryAvailable(reason: String?) {
        cancelPendingChunkTasks()
        finalizedDraft = nil
        startedAt = nil
        stoppedAt = nil
        state = .idle
        cleanupPersistedSession()
        archiveStore.markStatus(
            sessionId: sessionId,
            status: .partial,
            errorMessage: reason ?? "Partial transcript delivered. Replay available."
        )
        DebugLog.runtime("audio_chunk_partial_delivery_available audio_session_id=\(sessionId)")
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
        let phase = phase(forChunkIndex: chunk.index)
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
            phase: phase,
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
            "audio_chunk_rotated audio_session_id=\(sessionId) session_start_at=\(isoTimestamp(startedAt)) chunk_index=\(chunk.index) phase=\(phase.rawValue) snippet_count=\(chunkRecords.count) file_bytes=\(byteCount) status=queued"
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

    private func cancelPendingChunkTasks() {
        chunkTasks.values.forEach { $0.cancel() }
        chunkTasks = [:]
    }

    private func cancelPendingTasks() {
        cancelPendingChunkTasks()
        chunkRecords = [:]
        nextChunkIndex = 0
        ignoredChunkTaskIndices = []
        agentIntentStartChunkIndex = nil
    }

    private func phase(forChunkIndex index: Int) -> ChunkPhase {
        guard let agentIntentStartChunkIndex else { return .transcript }
        return index >= agentIntentStartChunkIndex ? .agentIntent : .transcript
    }

    private func markChunkTranscribing(index: Int) {
        guard !ignoredChunkTaskIndices.contains(index) else { return }
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
        guard !ignoredChunkTaskIndices.contains(index) else { return }
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
        guard !ignoredChunkTaskIndices.contains(index) else { return }
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

    private func markChunkTimedOut(index: Int, deadline: TimeInterval) {
        guard var record = chunkRecords[index] else { return }
        let message = "Transcription timed out after \(String(format: "%.1f", deadline)) seconds."
        record.status = .failed
        record.errorMessage = message
        record.completedAt = Date()
        chunkRecords[index] = record
        ignoredChunkTaskIndices.insert(index)
        archiveStore.markStatus(sessionId: sessionId, status: .failed, errorMessage: message)
        persistSessionSnapshot()
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
                throw HostedChunkedAudioSessionError.chunkTranscriptionFailed(record.index, missingFileError.localizedDescription)
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
                throw HostedChunkedAudioSessionError.chunkTranscriptionFailed(record.index, error.localizedDescription)
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
                let result = try await transcriber.transcribeDetailed(
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
        let orderedRecords = chunkRecords.values.sorted { $0.index < $1.index }
        let orderedSnippets = transcriptSnippets(from: orderedRecords)
        let rawTranscript = orderedSnippets.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTranscript.isEmpty else { return }

        do {
            try archiveStore.writeRawTranscript(
                sessionId: sessionId,
                rawTranscript: rawTranscript,
                snippetCount: orderedSnippets.count,
                transcriptChunkTimings: makeTranscriptChunkTimings(from: orderedRecords),
                status: state == .stopped ? .ready : .transcribing
            )
        } catch {
            DebugLog.runtimeError(
                "audio_capture_archive_partial_raw_failed audio_session_id=\(sessionId) error=\(error.localizedDescription)"
            )
        }
    }

    private func transcriptSnippets(from records: [ChunkRecord]) -> [String] {
        records.compactMap { record -> String? in
            let trimmedTranscript = record.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedTranscript.isEmpty ? nil : trimmedTranscript
        }
    }

    private func persistSessionSnapshot() {
        let snapshot = PersistedHostedChunkedAudioSession(
            sessionId: sessionId,
            createdAt: startedAt ?? Date(),
            updatedAt: Date(),
            chunks: chunkRecords.values
                .sorted { $0.index < $1.index }
                .map { record in
                    PersistedHostedChunkedAudioRecord(
                        index: record.index,
                        phase: record.phase.rawValue,
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
                PersistedHostedChunkedAudioDraft(
                    rawTranscript: $0.rawTranscript,
                    transcriptRawText: $0.transcriptRawText,
                    agentIntentRawText: $0.agentIntentRawText,
                    snippetCount: $0.snippetCount,
                    transcriptSnippetCount: $0.transcriptSnippetCount,
                    agentIntentSnippetCount: $0.agentIntentSnippetCount,
                    isPartial: $0.isPartial,
                    failedChunkIndices: $0.failedChunkIndices,
                    partialReason: $0.partialReason
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
                phase: record.phase.rawValue,
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
