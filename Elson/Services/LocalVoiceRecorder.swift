@preconcurrency import AVFoundation
import Foundation

enum LocalVoiceCapturePhase: String, Codable, Equatable, Sendable {
    case transcript
    case agentIntent
}

struct LocalVoiceRecordedFile: Equatable, Sendable {
    let phase: LocalVoiceCapturePhase
    let url: URL
    let startedAt: Date
    let stoppedAt: Date

    var duration: TimeInterval {
        max(0, stoppedAt.timeIntervalSince(startedAt))
    }
}

enum LocalVoiceRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case missingAudioFile

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already active."
        case .notRecording:
            return "Recording is not active."
        case .missingAudioFile:
            return "Saved audio is missing."
        }
    }
}

final class LocalVoiceRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let writeQueue = DispatchQueue(label: "ai.elson.local-voice-recorder.writer", qos: .userInitiated)
    private let lock = NSLock()
    private let fileManager: FileManager
    private let recordingsDirectory: URL

    private var file: AVAudioFile?
    private var currentURL: URL?
    private var currentStartedAt: Date?
    private var currentPhase: LocalVoiceCapturePhase?
    private var recording = false

    init(fileManager: FileManager = .default, recordingsDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.recordingsDirectory = recordingsDirectory
            ?? fileManager.temporaryDirectory.appendingPathComponent("ElsonLocalVoice", isDirectory: true)
    }

    var isRecording: Bool {
        lock.withLocalVoiceLock { recording }
    }

    var activeRecordingStartedAt: Date? {
        lock.withLocalVoiceLock { currentStartedAt }
    }

    func start(phase: LocalVoiceCapturePhase) throws -> URL {
        let shouldStart = lock.withLocalVoiceLock { () -> Bool in
            guard !recording else { return false }
            return true
        }
        guard shouldStart else { throw LocalVoiceRecorderError.alreadyRecording }

        try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let startedAt = Date()
        let url = recordingsDirectory
            .appendingPathComponent("\(phase.rawValue)-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("wav")
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)

        lock.withLocalVoiceLock {
            file = audioFile
            currentURL = url
            currentStartedAt = startedAt
            currentPhase = phase
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.writeQueue.async { [weak self] in
                do {
                    try self?.write(buffer)
                } catch {
                    DebugLog.runtimeError("local_voice_audio_write_failed error=\(error.localizedDescription)")
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            lock.withLocalVoiceLock {
                recording = true
            }
            return url
        } catch {
            input.removeTap(onBus: 0)
            lock.withLocalVoiceLock {
                file = nil
                currentURL = nil
                currentStartedAt = nil
                currentPhase = nil
                recording = false
            }
            throw error
        }
    }

    func stop() throws -> LocalVoiceRecordedFile {
        let snapshot = lock.withLocalVoiceLock { () -> (URL?, Date?, LocalVoiceCapturePhase?, Bool) in
            let result = (currentURL, currentStartedAt, currentPhase, recording)
            recording = false
            return result
        }
        guard snapshot.3 else { throw LocalVoiceRecorderError.notRecording }
        guard let url = snapshot.0, let startedAt = snapshot.1, let phase = snapshot.2 else {
            throw LocalVoiceRecorderError.missingAudioFile
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        writeQueue.sync {
            lock.withLocalVoiceLock {
                file = nil
                currentURL = nil
                currentStartedAt = nil
                currentPhase = nil
            }
        }

        return LocalVoiceRecordedFile(
            phase: phase,
            url: url,
            startedAt: startedAt,
            stoppedAt: Date()
        )
    }

    func cancel() {
        let url = lock.withLocalVoiceLock { () -> URL? in
            let result = currentURL
            recording = false
            return result
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        writeQueue.sync {
            lock.withLocalVoiceLock {
                file = nil
                currentURL = nil
                currentStartedAt = nil
                currentPhase = nil
            }
        }
        if let url {
            try? fileManager.removeItem(at: url)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        try file?.write(from: buffer)
    }
}

private extension NSLock {
    func withLocalVoiceLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
