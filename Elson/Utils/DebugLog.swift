import AppKit
import Foundation
import os

enum RequestTimelineStage: String, CaseIterable, Sendable {
    case audioCaptureFinalize = "audio_capture_finalize"
    case groqTranscription = "groq_transcription"
    case screenContext = "screen_context"
    case intentAgent = "intent_agent"
    case speculativeTranscript = "speculative_transcript"
    case workingAgent = "working_agent"
    case localTranscript = "local_transcript"
    case desktopActions = "desktop_actions"
    case uiCommit = "ui_commit"
    case backgroundWordsCorrection = "background_words_correction"
}

struct RequestTimelineSnapshot: Sendable, Equatable {
    let requestId: String
    let threadId: String
    let surface: String
    let inputSource: String
    let startedAt: Date
    let stageDurationsMS: [String: Int]
    let metricsMS: [String: Int]
    let annotations: [String: String]
    let latencyVisibleMS: Int?
    let latencyProviderMS: Int
    let latencyBackgroundMS: Int

    init(
        requestId: String,
        threadId: String,
        surface: String,
        inputSource: String,
        startedAt: Date = Date(),
        stageDurationsMS: [String: Int] = [:],
        metricsMS: [String: Int] = [:],
        annotations: [String: String] = [:],
        latencyVisibleMS: Int? = nil,
        latencyProviderMS: Int = 0,
        latencyBackgroundMS: Int = 0
    ) {
        self.requestId = requestId
        self.threadId = threadId
        self.surface = surface
        self.inputSource = inputSource
        self.startedAt = startedAt
        self.stageDurationsMS = stageDurationsMS
        self.metricsMS = metricsMS
        self.annotations = annotations
        self.latencyVisibleMS = latencyVisibleMS
        self.latencyProviderMS = latencyProviderMS
        self.latencyBackgroundMS = latencyBackgroundMS
    }

    func addingStage(
        _ stage: RequestTimelineStage,
        durationMS: Int,
        countTowardProvider: Bool = false
    ) -> RequestTimelineSnapshot {
        var nextDurations = stageDurationsMS
        nextDurations[stage.rawValue] = (nextDurations[stage.rawValue] ?? 0) + durationMS
        return RequestTimelineSnapshot(
            requestId: requestId,
            threadId: threadId,
            surface: surface,
            inputSource: inputSource,
            startedAt: startedAt,
            stageDurationsMS: nextDurations,
            metricsMS: metricsMS,
            annotations: annotations,
            latencyVisibleMS: latencyVisibleMS,
            latencyProviderMS: latencyProviderMS + (countTowardProvider ? durationMS : 0),
            latencyBackgroundMS: latencyBackgroundMS
        )
    }

    func addingMetric(_ key: String, valueMS: Int?) -> RequestTimelineSnapshot {
        guard let valueMS else { return self }
        var nextMetrics = metricsMS
        nextMetrics[key] = valueMS
        return RequestTimelineSnapshot(
            requestId: requestId,
            threadId: threadId,
            surface: surface,
            inputSource: inputSource,
            startedAt: startedAt,
            stageDurationsMS: stageDurationsMS,
            metricsMS: nextMetrics,
            annotations: annotations,
            latencyVisibleMS: latencyVisibleMS,
            latencyProviderMS: latencyProviderMS,
            latencyBackgroundMS: latencyBackgroundMS
        )
    }

    func addingAnnotation(_ key: String, value: String?) -> RequestTimelineSnapshot {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        var nextAnnotations = annotations
        nextAnnotations[key] = value
        return RequestTimelineSnapshot(
            requestId: requestId,
            threadId: threadId,
            surface: surface,
            inputSource: inputSource,
            startedAt: startedAt,
            stageDurationsMS: stageDurationsMS,
            metricsMS: metricsMS,
            annotations: nextAnnotations,
            latencyVisibleMS: latencyVisibleMS,
            latencyProviderMS: latencyProviderMS,
            latencyBackgroundMS: latencyBackgroundMS
        )
    }

    func withVisibleLatencyMS(_ latencyVisibleMS: Int) -> RequestTimelineSnapshot {
        RequestTimelineSnapshot(
            requestId: requestId,
            threadId: threadId,
            surface: surface,
            inputSource: inputSource,
            startedAt: startedAt,
            stageDurationsMS: stageDurationsMS,
            metricsMS: metricsMS,
            annotations: annotations,
            latencyVisibleMS: latencyVisibleMS,
            latencyProviderMS: latencyProviderMS,
            latencyBackgroundMS: latencyBackgroundMS
        )
    }

    func withBackgroundLatencyMS(_ latencyBackgroundMS: Int) -> RequestTimelineSnapshot {
        RequestTimelineSnapshot(
            requestId: requestId,
            threadId: threadId,
            surface: surface,
            inputSource: inputSource,
            startedAt: startedAt,
            stageDurationsMS: stageDurationsMS,
            metricsMS: metricsMS,
            annotations: annotations,
            latencyVisibleMS: latencyVisibleMS,
            latencyProviderMS: latencyProviderMS,
            latencyBackgroundMS: latencyBackgroundMS
        )
    }

    func withThreadId(_ threadId: String) -> RequestTimelineSnapshot {
        RequestTimelineSnapshot(
            requestId: requestId,
            threadId: threadId,
            surface: surface,
            inputSource: inputSource,
            startedAt: startedAt,
            stageDurationsMS: stageDurationsMS,
            metricsMS: metricsMS,
            annotations: annotations,
            latencyVisibleMS: latencyVisibleMS,
            latencyProviderMS: latencyProviderMS,
            latencyBackgroundMS: latencyBackgroundMS
        )
    }
}

enum DebugLog {
    private actor BackgroundTailAccumulator {
        private var totalsMS: [String: Int] = [:]

        func add(requestId: String, durationMS: Int) -> Int {
            totalsMS[requestId, default: 0] += durationMS
            return totalsMS[requestId] ?? durationMS
        }
    }

    private enum LogFile: String {
        case runtime = "runtime.log"
        case llm = "llm.log"
    }

    private static let resetKey = "GAIRVIS_DEBUG_RESET"
    private static let aiDebugKey = "GAIRVIS_DEBUG_AI"
    private static let aiDebugMaxCharsKey = "GAIRVIS_DEBUG_AI_MAX_CHARS"
    private static let resetLogger = Logger(subsystem: "ai.elson.desktop", category: "reset")
    private static let runtimeLogger = Logger(subsystem: "ai.elson.desktop", category: "runtime")
    private static let routingLogger = Logger(subsystem: "ai.elson.desktop", category: "routing")
    private static let providerLogger = Logger(subsystem: "ai.elson.desktop", category: "provider")
    private static let fileQueue = DispatchQueue(label: "ai.elson.desktop.debug-log-writer", qos: .utility)
    private static let backgroundTailAccumulator = BackgroundTailAccumulator()

    static var resetEnabled: Bool {
        ProcessInfo.processInfo.environment[resetKey] == "1"
    }

    static var aiDebugEnabled: Bool {
        ProcessInfo.processInfo.environment[aiDebugKey] == "1"
    }

    private static var aiDebugMaxChars: Int {
        guard let raw = ProcessInfo.processInfo.environment[aiDebugMaxCharsKey],
              let value = Int(raw),
              value > 256 else {
            return 12000
        }
        return value
    }

    static func reset(_ message: String, file: String = #fileID, line: Int = #line) {
        guard resetEnabled else { return }
        let ts = String(format: "%.3f", Date().timeIntervalSince1970)
        let msg = "[DEBUG_RESET] t=\(ts) \(file):\(line) \(message)"
        // Use Unified Logging so `log stream` can see it even for apps launched from /Applications.
        resetLogger.notice("\(msg, privacy: .public)")
        // Also print for Xcode / `swift run` sessions.
        print(msg)
        appendLine(msg, to: .runtime)
    }

    static func runtimeError(_ message: String) {
        runtimeLogger.error("\(message, privacy: .public)")
        let line = "[RUNTIME_ERROR] \(message)"
        print(line)
        appendLine(line, to: .runtime)
    }

    static func runtime(_ message: String) {
        runtimeLogger.notice("\(message, privacy: .public)")
        let line = "[RUNTIME] \(message)"
        print(line)
        appendLine(line, to: .runtime)
    }

    static func routingDecision(_ message: String) {
        routingLogger.notice("\(message, privacy: .public)")
        let line = "[ROUTING] \(message)"
        print(line)
        appendLine(line, to: .runtime)
    }

    static func requestStageStart(
        _ snapshot: RequestTimelineSnapshot,
        stage: RequestTimelineStage,
        metadata: String = ""
    ) {
        let message = [
            "request_stage_start",
            "request_id=\(snapshot.requestId)",
            "thread_id=\(snapshot.threadId)",
            "surface=\(snapshot.surface)",
            "input_source=\(snapshot.inputSource)",
            "stage=\(stage.rawValue)",
            metadata.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        runtime(message)
    }

    static func requestStageEnd(
        _ snapshot: RequestTimelineSnapshot,
        stage: RequestTimelineStage,
        durationMS: Int,
        metadata: String = ""
    ) {
        let message = [
            "request_stage_end",
            "request_id=\(snapshot.requestId)",
            "thread_id=\(snapshot.threadId)",
            "surface=\(snapshot.surface)",
            "input_source=\(snapshot.inputSource)",
            "stage=\(stage.rawValue)",
            "duration_ms=\(durationMS)",
            metadata.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        runtime(message)
    }

    static func requestTimeline(_ snapshot: RequestTimelineSnapshot) {
        runtime(formattedRequestTimeline(snapshot))
    }

    static func requestMilestone(
        _ snapshot: RequestTimelineSnapshot,
        name: String,
        metadata: String = ""
    ) {
        let message = [
            "request_milestone",
            "request_id=\(snapshot.requestId)",
            "thread_id=\(snapshot.threadId)",
            "surface=\(snapshot.surface)",
            "input_source=\(snapshot.inputSource)",
            "milestone=\(name)",
            metadata.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        runtime(message)
    }

    static func requestBackgroundTail(
        requestId: String,
        threadId: String,
        surface: String,
        inputSource: String,
        task: String,
        durationMS: Int
    ) {
        Task {
            let totalMS = await backgroundTailAccumulator.add(requestId: requestId, durationMS: durationMS)
            let message = [
                "request_background_tail",
                "request_id=\(requestId)",
                "thread_id=\(threadId)",
                "surface=\(surface)",
                "input_source=\(inputSource)",
                "task=\(task)",
                "duration_ms=\(durationMS)",
                "latency_background_ms=\(totalMS)"
            ]
            .joined(separator: " ")
            runtime(message)
        }
    }

    static func providerEvent(
        phase: String,
        service: String,
        model: String,
        metadata: String = "",
        payloadPreview: String? = nil
    ) {
        let summary = [
            "phase=\(phase)",
            "service=\(service)",
            "model=\(model)",
            providerMetadataPrefix(for: service, metadata: metadata),
            metadata.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        providerLogger.notice("\(summary, privacy: .public)")
        let line = "[PROVIDER] \(summary)"
        print(line)
        appendLine(line, to: .llm)

        guard let payloadPreview, !payloadPreview.isEmpty else { return }
        appendBlock(
            header: "[PROVIDER_PAYLOAD] \(summary)",
            payload: payloadPreview,
            to: .llm
        )

        guard aiDebugEnabled else { return }
        let preview = truncate(payloadPreview)
        providerLogger.notice("payload \(preview, privacy: .public)")
        print("[PROVIDER_PAYLOAD] \(preview)")
    }

    static func providerFailure(
        service: String,
        model: String,
        metadata: String = "",
        error: String,
        payloadPreview: String? = nil
    ) {
        let summary = [
            "phase=failure",
            "service=\(service)",
            "model=\(model)",
            providerMetadataPrefix(for: service, metadata: metadata),
            metadata.trimmingCharacters(in: .whitespacesAndNewlines),
            "error=\(error)"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        providerLogger.error("\(summary, privacy: .public)")
        let line = "[PROVIDER_ERROR] \(summary)"
        print(line)
        appendLine(line, to: .runtime)
        appendLine(line, to: .llm)

        guard let payloadPreview, !payloadPreview.isEmpty else { return }
        appendBlock(
            header: "[PROVIDER_ERROR_PAYLOAD] \(summary)",
            payload: payloadPreview,
            to: .llm
        )

        guard aiDebugEnabled else { return }
        let preview = truncate(payloadPreview)
        providerLogger.error("payload \(preview, privacy: .public)")
        print("[PROVIDER_ERROR_PAYLOAD] \(preview)")
    }

    static func logsDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    @MainActor
    static func openLogsFolder() {
        let url = logsDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            runtimeError("open_logs_folder_failed path=\(url.path) error=\(error.localizedDescription)")
        }
        NSWorkspace.shared.open(url)
    }

    private static func truncate(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > aiDebugMaxChars else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: aiDebugMaxChars)
        return String(collapsed[..<end]) + "…"
    }

    static func formattedRequestTimeline(_ snapshot: RequestTimelineSnapshot) -> String {
        let stageParts = RequestTimelineStage.allCases.compactMap { stage -> String? in
            guard let durationMS = snapshot.stageDurationsMS[stage.rawValue] else { return nil }
            return "\(stage.rawValue)=\(durationMS)"
        }
        let preferredMetricOrder = [
            "latency_hotkey_to_recording_start_ms",
            "latency_recording_stop_to_first_stt_ms",
            "latency_recording_stop_to_intent_ms",
            "latency_recording_stop_to_transcript_ms",
            "latency_recording_stop_to_visible_ms",
            "latency_visible_to_clipboard_ms",
            "latency_visible_to_autopaste_ms",
            "latency_hotkey_to_autopaste_ms",
        ]
        let metricParts = preferredMetricOrder.compactMap { key -> String? in
            guard let value = snapshot.metricsMS[key] else { return nil }
            return "\(key)=\(value)"
        } + snapshot.metricsMS.keys
            .filter { !preferredMetricOrder.contains($0) }
            .sorted()
            .compactMap { key -> String? in
                guard let value = snapshot.metricsMS[key] else { return nil }
                return "\(key)=\(value)"
            }
        let annotationParts = snapshot.annotations.keys
            .sorted()
            .compactMap { key -> String? in
                guard let value = snapshot.annotations[key] else { return nil }
                return "\(key)=\(value)"
            }

        return [
            "request_timeline",
            "request_id=\(snapshot.requestId)",
            "thread_id=\(snapshot.threadId)",
            "surface=\(snapshot.surface)",
            "input_source=\(snapshot.inputSource)",
            "latency_visible_ms=\(snapshot.latencyVisibleMS ?? -1)",
            "latency_provider_ms=\(snapshot.latencyProviderMS)",
            "latency_background_ms=\(snapshot.latencyBackgroundMS)",
            stageParts.joined(separator: " "),
            metricParts.joined(separator: " "),
            annotationParts.joined(separator: " ")
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func providerMetadataPrefix(for service: String, metadata: String) -> String {
        guard !metadata.contains("provider=") else { return "" }
        guard let provider = providerSlug(for: service) else { return "" }
        return "provider=\(provider)"
    }

    private static func providerSlug(for service: String) -> String? {
        let normalized = service.lowercased()
        if normalized.contains("groq") {
            return "groq"
        }
        if normalized.contains("cerebras") {
            return "cerebras"
        }
        if normalized.contains("gemini") || normalized.contains("google") {
            return "google"
        }
        return nil
    }

    private static func appendLine(_ message: String, to file: LogFile) {
        append(lines: [timestamped(message)], to: file)
    }

    private static func appendBlock(header: String, payload: String, to file: LogFile) {
        append(
            lines: [
                timestamped(header),
                payload.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"),
                ""
            ],
            to: file
        )
    }

    private static func timestamped(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(formatter.string(from: Date())) \(value)"
    }

    private static func append(lines: [String], to file: LogFile) {
        fileQueue.async {
            let fileManager = FileManager.default
            let directoryURL = logsDirectoryURL()
            let fileURL = directoryURL.appendingPathComponent(file.rawValue)

            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    fileManager.createFile(atPath: fileURL.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()

                let text = lines.joined(separator: "\n") + "\n"
                if let data = text.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                let fallback = "[DEBUG_LOG_FILE_ERROR] path=\(fileURL.path) error=\(error.localizedDescription)"
                runtimeLogger.error("\(fallback, privacy: .public)")
                print(fallback)
            }
        }
    }
}
