import Foundation
import XCTest
@testable import Elson

final class RequestTimelineTests: XCTestCase {
    func testAddingStageAccumulatesDurationsAndProviderLatency() {
        let snapshot = RequestTimelineSnapshot(
            requestId: "req-1",
            threadId: "thread-1",
            surface: "shortcut",
            inputSource: "audio"
        )
        .addingStage(.groqTranscription, durationMS: 120, countTowardProvider: true)
        .addingStage(.groqTranscription, durationMS: 30, countTowardProvider: true)
        .addingStage(.uiCommit, durationMS: 8)

        XCTAssertEqual(snapshot.stageDurationsMS[RequestTimelineStage.groqTranscription.rawValue], 150)
        XCTAssertEqual(snapshot.stageDurationsMS[RequestTimelineStage.uiCommit.rawValue], 8)
        XCTAssertEqual(snapshot.latencyProviderMS, 150)
    }

    func testFormattedRequestTimelineUsesCanonicalStageOrder() {
        let snapshot = RequestTimelineSnapshot(
            requestId: "req-2",
            threadId: "thread-2",
            surface: "chat",
            inputSource: "audio"
        )
        .addingStage(.uiCommit, durationMS: 11)
        .addingStage(.workingAgent, durationMS: 70, countTowardProvider: true)
        .addingStage(.groqTranscription, durationMS: 120, countTowardProvider: true)
        .withVisibleLatencyMS(260)

        let formatted = DebugLog.formattedRequestTimeline(snapshot)

        XCTAssertTrue(formatted.contains("latency_visible_ms=260"))
        XCTAssertTrue(formatted.contains("latency_provider_ms=190"))
        XCTAssertLessThan(
            formatted.range(of: "groq_transcription=120")!.lowerBound,
            formatted.range(of: "working_agent=70")!.lowerBound
        )
        XCTAssertLessThan(
            formatted.range(of: "working_agent=70")!.lowerBound,
            formatted.range(of: "ui_commit=11")!.lowerBound
        )
    }

    func testFormattedRequestTimelineIncludesMetricsAndAnnotations() {
        let snapshot = RequestTimelineSnapshot(
            requestId: "req-3",
            threadId: "thread-3",
            surface: "shortcut",
            inputSource: "audio"
        )
        .addingStage(.speculativeTranscript, durationMS: 240, countTowardProvider: true)
        .addingMetric("latency_hotkey_to_recording_start_ms", valueMS: 85)
        .addingMetric("latency_recording_stop_to_transcript_ms", valueMS: 1320)
        .addingAnnotation("visible_output_source", value: "speculative_transcript_reuse")

        let formatted = DebugLog.formattedRequestTimeline(snapshot)

        XCTAssertTrue(formatted.contains("speculative_transcript=240"))
        XCTAssertTrue(formatted.contains("latency_hotkey_to_recording_start_ms=85"))
        XCTAssertTrue(formatted.contains("latency_recording_stop_to_transcript_ms=1320"))
        XCTAssertTrue(formatted.contains("visible_output_source=speculative_transcript_reuse"))
    }
}
