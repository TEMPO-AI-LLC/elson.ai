import Foundation
import AVFoundation
import SwiftUI
import OSLog

@MainActor
final class AudioRecordingService: NSObject, ObservableObject {
    struct AudioChunk {
        let url: URL
        let index: Int
    }

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?
    private var smoothedLevel: Double = 0
    private let systemAudioDucker = SystemAudioDucker()
    private let logger = Logger(subsystem: "ai.elson.desktop", category: "AudioRecordingService")
    private var recordingStartedAt: Date?

    private var chunkTimer: Timer?
    private var chunkDuration: TimeInterval = 30
    private var chunkIndex: Int = 0
    private var isChunkedRecording = false
    private var isRotatingChunk = false
    private var onChunkReady: ((AudioChunk) -> Void)?

    // CoreAudio can briefly reconfigure hardware right after stopping a recorder.
    // Starting again too quickly can trigger HAL "reconfig pending" races.
    private var lastStopUptime: TimeInterval = 0
    private let minimumRestartDelay: TimeInterval = 0.35
    
    @Published var isRecording = false
    @Published var hasPermission = true // macOS handles permissions differently
    @Published var inputLevel: Double = 0
    @Published private(set) var lastRecordingDuration: TimeInterval = 0
    var activeRecordingStartedAt: Date? { recordingStartedAt }

    private func setPublished<T>(_ keyPath: ReferenceWritableKeyPath<AudioRecordingService, T>, _ value: T) {
        if Thread.isMainThread {
            self[keyPath: keyPath] = value
        } else {
            DispatchQueue.main.sync {
                self[keyPath: keyPath] = value
            }
        }
    }
    
    override init() {
        super.init()
        // No audio session setup needed on macOS
    }

    private var shouldMuteSystemAudioDuringRecording: Bool {
        let key = "muteSystemAudioDuringRecording"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    private func recordingsDirectory() throws -> URL {
        // Use an app-private directory to avoid triggering macOS "Documents folder" prompts.
        // The app already cleans up recordings after processing, so persistence isn't needed.
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    func startRecording() -> Bool {
        if Thread.isMainThread {
            return startRecordingOnMain(allowWhenRecording: false)
        }
        return DispatchQueue.main.sync {
            startRecordingOnMain(allowWhenRecording: false)
        }
    }

    private func startRecordingOnMain(allowWhenRecording: Bool) -> Bool {
        print("🎤 AUDIO DEBUG: startRecording() called")
        print("🎤 AUDIO DEBUG: hasPermission: \(hasPermission), isRecording: \(isRecording)")
        lastRecordingDuration = 0

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micAuthorized = micStatus == .authorized
        setPublished(\.hasPermission, micAuthorized)

        let sinceStop = ProcessInfo.processInfo.systemUptime - lastStopUptime
        if sinceStop < minimumRestartDelay {
            let remaining = minimumRestartDelay - sinceStop
            print("⏳ AUDIO DEBUG: Start inhibited (cooldown \(String(format: "%.3f", remaining))s remaining)")
            return false
        }

        guard micAuthorized else {
            print("❌ AUDIO DEBUG: No microphone permission")
            return false
        }
        
        guard !isRecording || allowWhenRecording else {
            print("⚠️ AUDIO DEBUG: Already recording")
            return false
        }

        let audioFilename: URL
        do {
            let recordingsDir = try recordingsDirectory()
            audioFilename = recordingsDir.appendingPathComponent("Elson_\(Date().timeIntervalSince1970).m4a")
        } catch {
            print("❌ AUDIO DEBUG: Failed to create recordings directory: \(error)")
            return false
        }
        
        print("🎤 AUDIO DEBUG: Audio filename: \(audioFilename.path)")
        
        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        print("🎤 AUDIO DEBUG: Audio settings: \(settings)")
        
        do {
            print("🎤 AUDIO DEBUG: Creating AVAudioRecorder...")
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            
            print("🎤 AUDIO DEBUG: Starting recording...")
            let recordResult = audioRecorder?.record()
            print("🎤 AUDIO DEBUG: Record result: \(recordResult ?? false)")

            guard recordResult == true else {
                print("❌ AUDIO DEBUG: AVAudioRecorder.record() returned false")
                audioRecorder = nil
                recordingURL = nil
                stopMetering()
                systemAudioDucker.end()
                return false
            }

            if shouldMuteSystemAudioDuringRecording && !allowWhenRecording {
                logger.notice("Muting system audio during recording enabled")
                systemAudioDucker.begin()
            } else {
                logger.notice("Muting system audio during recording disabled")
            }

            recordingURL = audioFilename
            recordingStartedAt = Date()
            setPublished(\.isRecording, true)
            startMetering()
            
            print("✅ AUDIO DEBUG: Started recording to: \(audioFilename)")
            return true
        } catch {
            print("❌ AUDIO DEBUG: Failed to start recording: \(error)")
            print("❌ AUDIO DEBUG: Error details: \(error.localizedDescription)")
            systemAudioDucker.end()
            return false
        }
    }
    
    func stopRecording() -> URL? {
        if Thread.isMainThread {
            return stopRecordingOnMain(keepRecordingState: false)
        }
        return DispatchQueue.main.sync {
            stopRecordingOnMain(keepRecordingState: false)
        }
    }

    func stopRecordingDiscardingIfShorterThan(_ minimumDuration: TimeInterval) -> URL? {
        guard let url = stopRecording() else { return nil }
        guard lastRecordingDuration >= minimumDuration else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func stopRecordingOnMain(keepRecordingState: Bool) -> URL? {
        print("🛑 AUDIO DEBUG: stopRecording() called")
        print("🛑 AUDIO DEBUG: isRecording: \(isRecording)")
        
        guard isRecording else {
            print("⚠️ AUDIO DEBUG: Not currently recording")
            return nil
        }
        
        print("🛑 AUDIO DEBUG: Stopping audio recorder...")
        audioRecorder?.stop()
        lastStopUptime = ProcessInfo.processInfo.systemUptime
        lastRecordingDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        if !keepRecordingState {
            setPublished(\.isRecording, false)
        }
        stopMetering()
        if !keepRecordingState {
            logger.notice("Restoring system audio after recording")
            systemAudioDucker.end()
        }

        if !keepRecordingState && isChunkedRecording {
            stopChunkTimer()
            isChunkedRecording = false
            isRotatingChunk = false
            onChunkReady = nil
        }
        
        let url = recordingURL
        recordingURL = nil
        audioRecorder = nil
        
        print("✅ AUDIO DEBUG: Stopped recording. File saved at: \(url?.path ?? "unknown")")
        
        // Check if file exists and get size
        if let url = url {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attributes[.size] as? Int64 ?? 0
                print("📁 AUDIO DEBUG: File size: \(fileSize) bytes")
            } catch {
                print("❌ AUDIO DEBUG: Error getting file attributes: \(error)")
            }
        }
        
        return url
    }

    func startChunkedRecording(chunkDuration: TimeInterval = 30, onChunk: @escaping (AudioChunk) -> Void) -> Bool {
        startChunkedRecording(chunkDuration: chunkDuration, startingIndex: 0, onChunk: onChunk)
    }

    /// Resume-capable chunked recording. `startingIndex` lets callers continue indices across pauses so
    /// server-side chunk storage (session_id + chunk_index) doesn't collide.
    func startChunkedRecording(chunkDuration: TimeInterval = 30, startingIndex: Int, onChunk: @escaping (AudioChunk) -> Void) -> Bool {
        if Thread.isMainThread {
            return startChunkedRecordingOnMain(chunkDuration: chunkDuration, startingIndex: startingIndex, onChunk: onChunk)
        }
        return DispatchQueue.main.sync {
            startChunkedRecordingOnMain(chunkDuration: chunkDuration, startingIndex: startingIndex, onChunk: onChunk)
        }
    }

    private func startChunkedRecordingOnMain(chunkDuration: TimeInterval, startingIndex: Int, onChunk: @escaping (AudioChunk) -> Void) -> Bool {
        guard !isRecording else { return false }
        self.chunkDuration = max(5, chunkDuration)
        self.chunkIndex = max(0, startingIndex)
        self.isChunkedRecording = true
        self.isRotatingChunk = false
        self.onChunkReady = onChunk

        guard startRecordingOnMain(allowWhenRecording: false) else {
            self.isChunkedRecording = false
            self.onChunkReady = nil
            return false
        }

        scheduleChunkTimer()
        return true
    }

    func stopChunkedRecording() -> AudioChunk? {
        if Thread.isMainThread {
            return stopChunkedRecordingOnMain()
        }
        return DispatchQueue.main.sync {
            stopChunkedRecordingOnMain()
        }
    }

    private func stopChunkedRecordingOnMain() -> AudioChunk? {
        guard isChunkedRecording else { return nil }
        stopChunkTimer()
        isChunkedRecording = false
        isRotatingChunk = false
        onChunkReady = nil
        let url = stopRecordingOnMain(keepRecordingState: false)
        guard let url else { return nil }
        let index = chunkIndex
        chunkIndex += 1
        return AudioChunk(url: url, index: index)
    }

    private func scheduleChunkTimer() {
        stopChunkTimer()
        let timer = Timer(timeInterval: chunkDuration, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rotateChunkIfNeeded()
            }
        }
        chunkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopChunkTimer() {
        chunkTimer?.invalidate()
        chunkTimer = nil
    }

    private func rotateChunkIfNeeded() {
        guard isChunkedRecording, !isRotatingChunk else { return }
        isRotatingChunk = true

        let url = stopRecordingOnMain(keepRecordingState: true)
        if let url {
            let index = chunkIndex
            chunkIndex += 1
            onChunkReady?(AudioChunk(url: url, index: index))
        }

        let sinceStop = ProcessInfo.processInfo.systemUptime - lastStopUptime
        let delay = max(0, minimumRestartDelay - sinceStop)

        Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard self.isChunkedRecording else {
                self.isRotatingChunk = false
                return
            }

            let started = self.startRecordingOnMain(allowWhenRecording: true)
            if !started {
                print("❌ AUDIO DEBUG: Failed to rotate chunk recording")
                self.isChunkedRecording = false
                self.stopChunkTimer()
                self.setPublished(\.isRecording, false)
                self.logger.notice("Restoring system audio after recording")
                self.systemAudioDucker.end()
            }

            self.isRotatingChunk = false
        }
    }

    private func startMetering() {
        if Thread.isMainThread {
            startMeteringOnMain()
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.startMeteringOnMain()
            }
        }
    }

    private func startMeteringOnMain() {
        stopMeteringOnMain()
        smoothedLevel = 0
        inputLevel = 0

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let recorder = self.audioRecorder, self.isRecording else { return }

                recorder.updateMeters()
                let average = Double(recorder.averagePower(forChannel: 0)) // [-160, 0]
                let minDb: Double = -50
                let normalized = max(0, min(1, (average - minDb) / -minDb))
                self.smoothedLevel = (self.smoothedLevel * 0.75) + (normalized * 0.25)
                self.inputLevel = self.smoothedLevel
            }
        }

        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMetering() {
        if Thread.isMainThread {
            stopMeteringOnMain()
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.stopMeteringOnMain()
            }
        }
    }

    private func stopMeteringOnMain() {
        meterTimer?.invalidate()
        meterTimer = nil
        smoothedLevel = 0
        inputLevel = 0
    }
    
    func cleanup() {
        // Clean up old recording files
        do {
            let recordingsDir = try recordingsDirectory()
            let files = try FileManager.default.contentsOfDirectory(
                at: recordingsDir,
                includingPropertiesForKeys: nil
            )
            
            for file in files {
                if file.lastPathComponent.hasPrefix("Elson_") {
                    // Delete files older than 1 hour
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    if let creationDate = attributes[.creationDate] as? Date,
                       Date().timeIntervalSince(creationDate) > 3600 {
                        try FileManager.default.removeItem(at: file)
                        print("Cleaned up old recording: \(file.lastPathComponent)")
                    }
                }
            }
        } catch {
            print("Failed to cleanup old recordings: \(error)")
        }
    }
    
    func openSystemPreferences() {
        PermissionCoordinator.openMicrophoneSettings()
    }
}

extension AudioRecordingService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            print("Recording failed")
            self.lastStopUptime = ProcessInfo.processInfo.systemUptime
            self.recordingStartedAt = nil
            self.lastRecordingDuration = 0
            self.setPublished(\.isRecording, false)
            self.recordingURL = nil
            self.audioRecorder = nil
            self.stopMetering()
            self.systemAudioDucker.end()
        }
    }
    
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            print("Recording encode error: \(error?.localizedDescription ?? "Unknown error")")
            self.lastStopUptime = ProcessInfo.processInfo.systemUptime
            self.recordingStartedAt = nil
            self.lastRecordingDuration = 0
            self.setPublished(\.isRecording, false)
            self.recordingURL = nil
            self.audioRecorder = nil
            self.stopMetering()
            self.systemAudioDucker.end()
        }
    }
}
