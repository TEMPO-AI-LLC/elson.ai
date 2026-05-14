import Foundation
import XCTest
@testable import Elson

final class LocalChunkedAudioSessionPartialTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL, FileManager.default.fileExists(atPath: tempDirectoryURL.path) {
            try FileManager.default.removeItem(at: tempDirectoryURL)
        }
    }

    @MainActor
    func testPartialTranscriptReturnedWhenLaterChunkTimesOut() async throws {
        let recording = FakeChunkedAudioRecording(rootURL: tempDirectoryURL)
        let transcriber = FakeChunkTranscriber(
            responses: [
                0: .success("first chunk"),
                1: .stall
            ]
        )
        let archiveStore = LocalCapturedAudioSessionStore(
            rootURL: tempDirectoryURL.appendingPathComponent("archive", isDirectory: true)
        )
        let session = LocalChunkedAudioSession(
            recordingService: recording,
            groqAPIKey: "groq-key",
            chunkDuration: 5,
            transcriptionOverlapDuration: 0,
            transcriber: transcriber,
            retryStore: LocalChunkedAudioRetryStore(
                rootURL: tempDirectoryURL.appendingPathComponent("retry", isDirectory: true)
            ),
            archiveStore: archiveStore
        )

        XCTAssertTrue(session.start())
        try recording.emitChunk(index: 0)
        let kept = try await session.stopRecordingDiscardingIfShorterThan(0)
        XCTAssertTrue(kept)

        let draft = try await session.finalize(allowPartialAfter: 0.05)

        XCTAssertEqual(draft.rawTranscript, "first chunk")
        XCTAssertTrue(draft.isPartial)
        XCTAssertEqual(draft.failedChunkIndices, [1])

        let snapshot = try XCTUnwrap(archiveStore.load(sessionId: session.persistedSessionId))
        XCTAssertEqual(snapshot.status, .partial)
        XCTAssertEqual(snapshot.rawTranscript, "first chunk")
        XCTAssertEqual(snapshot.isPartial, true)
    }

    @MainActor
    func testNoUsableChunkProducesReplayableFailure() async throws {
        let recording = FakeChunkedAudioRecording(rootURL: tempDirectoryURL)
        let transcriber = FakeChunkTranscriber(responses: [0: .stall])
        let archiveStore = LocalCapturedAudioSessionStore(
            rootURL: tempDirectoryURL.appendingPathComponent("archive", isDirectory: true)
        )
        let session = LocalChunkedAudioSession(
            recordingService: recording,
            groqAPIKey: "groq-key",
            chunkDuration: 5,
            transcriptionOverlapDuration: 0,
            transcriber: transcriber,
            retryStore: LocalChunkedAudioRetryStore(
                rootURL: tempDirectoryURL.appendingPathComponent("retry", isDirectory: true)
            ),
            archiveStore: archiveStore
        )

        XCTAssertTrue(session.start())
        let kept = try await session.stopRecordingDiscardingIfShorterThan(0)
        XCTAssertTrue(kept)

        do {
            _ = try await session.finalize(allowPartialAfter: 0.05)
            XCTFail("Expected no usable transcript failure.")
        } catch LocalChunkedAudioSessionError.noUsableTranscript {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshot = try XCTUnwrap(archiveStore.load(sessionId: session.persistedSessionId))
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertEqual(snapshot.errorMessage, "Transcription failed. Replay available.")
        XCTAssertFalse(snapshot.chunkAudioFilePaths.isEmpty)
    }
}

final class LocalCapturedAudioSessionSnapshotPartialDecodingTests: XCTestCase {
    func testLegacyCapturedSessionMetadataDecodesWithoutPartialFields() throws {
        let payload = """
        {
          "sessionId": "session-1",
          "directoryPath": "/tmp/session-1",
          "createdAt": "2026-05-10T08:00:00Z",
          "updatedAt": "2026-05-10T08:01:00Z",
          "status": "ready",
          "chunkAudioFilePaths": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(
            LocalCapturedAudioSessionSnapshot.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertNil(snapshot.isPartial)
        XCTAssertNil(snapshot.partialReason)
    }
}

@MainActor
private final class FakeChunkedAudioRecording: ChunkedAudioRecording {
    private let rootURL: URL
    private var onChunk: ((AudioRecordingService.AudioChunk) -> Void)?
    private var nextStopIndex = 0

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    var activeRecordingStartedAt: Date? { Date() }

    func startChunkedRecording(
        chunkDuration _: TimeInterval,
        startingIndex: Int,
        onChunk: @escaping (AudioRecordingService.AudioChunk) -> Void
    ) -> Bool {
        self.onChunk = onChunk
        nextStopIndex = startingIndex
        return true
    }

    func stopChunkedRecording() -> AudioRecordingService.AudioChunk? {
        defer { nextStopIndex += 1 }
        return makeChunk(index: nextStopIndex)
    }

    func emitChunk(index: Int) throws {
        nextStopIndex = max(nextStopIndex, index + 1)
        onChunk?(makeChunk(index: index))
    }

    private func makeChunk(index: Int) -> AudioRecordingService.AudioChunk {
        let url = rootURL.appendingPathComponent("source-\(index).m4a")
        try? Data("audio-\(index)".utf8).write(to: url, options: [.atomic])
        return AudioRecordingService.AudioChunk(url: url, index: index)
    }
}

private struct FakeChunkTranscriber: LocalAudioTranscribing {
    enum Response: Sendable {
        case success(String)
        case stall
    }

    let responses: [Int: Response]

    func transcribeDetailed(
        audioURL: URL,
        groqAPIKey _: String,
        logContext _: LocalRequestLogContext?,
        extraMetadata _: String
    ) async throws -> LocalTranscriptionResult {
        let index = chunkIndex(from: audioURL)
        switch responses[index] ?? .stall {
        case let .success(text):
            return LocalTranscriptionResult(
                text: text,
                language: "en",
                duration: nil,
                segments: nil
            )
        case .stall:
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }
    }

    private func chunkIndex(from url: URL) -> Int {
        let filename = url.deletingPathExtension().lastPathComponent
        let digits = filename.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits)) ?? 0
    }
}
