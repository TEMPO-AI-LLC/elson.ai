import Foundation
import XCTest
@testable import Elson

final class HostedChunkedAudioRetryStoreTests: XCTestCase {
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

    func testStageSaveLoadAndRemoveSession() throws {
        let store = HostedChunkedAudioRetryStore(rootURL: tempDirectoryURL)
        let sourceURL = tempDirectoryURL.appendingPathComponent("source.m4a")
        let payload = Data("voice-data".utf8)
        try payload.write(to: sourceURL)

        let stagedURL = try store.stageChunkFile(sessionId: "session-1", index: 2, sourceURL: sourceURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(stagedURL.path.contains("session-1"))

        let snapshot = PersistedHostedChunkedAudioSession(
            sessionId: "session-1",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            chunks: [
                PersistedHostedChunkedAudioRecord(
                    index: 2,
                    audioFilePath: stagedURL.path,
                    byteCount: payload.count,
                    status: "completed",
                    transcript: "Hallo Welt",
                    errorMessage: nil,
                    transcribingStartedAt: Date(timeIntervalSince1970: 11),
                    completedAt: Date(timeIntervalSince1970: 12)
                )
            ],
            finalizedDraft: PersistedHostedChunkedAudioDraft(
                rawTranscript: "Hallo Welt",
                snippetCount: 1
            )
        )

        try store.save(snapshot)
        let loaded = try store.load(sessionId: "session-1")

        XCTAssertEqual(loaded, snapshot)

        store.removeSession(sessionId: "session-1")

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.sessionDirectoryURL(sessionId: "session-1").path
            )
        )
    }

}
