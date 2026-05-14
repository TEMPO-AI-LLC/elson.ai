import AppKit
import Foundation
import XCTest
@testable import Elson

final class ClipboardHelperTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("elson-tests-\(UUID().uuidString)"))
        ClipboardHelper.clearClipboard(pasteboard: pasteboard)
    }

    override func tearDownWithError() throws {
        ClipboardHelper.clearClipboard(pasteboard: pasteboard)
        pasteboard = nil
    }

    func testAutoPasteWithoutAutoCopyLeavesTranscriptInClipboardByDefault() {
        XCTAssertTrue(ClipboardHelper.copyToClipboard("original", pasteboard: pasteboard))

        var pasteCalls = 0
        let result = ClipboardHelper.deliverTranscriptDetailed(
            "fresh transcript",
            behavior: TranscriptClipboardBehavior(
                autoPasteEnabled: true,
                copyTranscriptToClipboardEnabled: false,
                restoreOriginalClipboardAfterPasteEnabled: false
            ),
            pasteboard: pasteboard,
            pasteAction: { pasteCalls += 1 },
            restoreDelayAfterPaste: 0
        )

        XCTAssertTrue(result.copied)
        XCTAssertTrue(result.autoPasted)
        XCTAssertFalse(result.restoredOriginalClipboard)
        XCTAssertEqual(pasteCalls, 1)
        XCTAssertEqual(ClipboardHelper.getClipboardContent(pasteboard: pasteboard), "fresh transcript")
    }

    func testAutoPasteWithoutAutoCopyLeavesTranscriptInClipboardWhenClipboardWasEmpty() {
        ClipboardHelper.clearClipboard(pasteboard: pasteboard)

        let result = ClipboardHelper.deliverTranscriptDetailed(
            "fresh transcript",
            behavior: TranscriptClipboardBehavior(
                autoPasteEnabled: true,
                copyTranscriptToClipboardEnabled: false,
                restoreOriginalClipboardAfterPasteEnabled: false
            ),
            pasteboard: pasteboard,
            pasteAction: {},
            restoreDelayAfterPaste: 0
        )

        XCTAssertTrue(result.copied)
        XCTAssertTrue(result.autoPasted)
        XCTAssertFalse(result.restoredOriginalClipboard)
        XCTAssertEqual(ClipboardHelper.getClipboardContent(pasteboard: pasteboard), "fresh transcript")
    }

    func testAutoCopyWithoutAutoPasteLeavesTranscriptInClipboard() {
        let result = ClipboardHelper.deliverTranscriptDetailed(
            "fresh transcript",
            behavior: TranscriptClipboardBehavior(
                autoPasteEnabled: false,
                copyTranscriptToClipboardEnabled: true,
                restoreOriginalClipboardAfterPasteEnabled: false
            ),
            pasteboard: pasteboard,
            pasteAction: { XCTFail("Paste should not be triggered when auto-paste is disabled.") }
        )

        XCTAssertTrue(result.copied)
        XCTAssertFalse(result.autoPasted)
        XCTAssertFalse(result.restoredOriginalClipboard)
        XCTAssertEqual(ClipboardHelper.getClipboardContent(pasteboard: pasteboard), "fresh transcript")
    }

    func testAutoPasteCanRestoreOriginalClipboardWhenExplicitlyEnabled() {
        XCTAssertTrue(ClipboardHelper.copyToClipboard("original", pasteboard: pasteboard))

        let result = ClipboardHelper.deliverTranscriptDetailed(
            "fresh transcript",
            behavior: TranscriptClipboardBehavior(
                autoPasteEnabled: true,
                copyTranscriptToClipboardEnabled: true,
                restoreOriginalClipboardAfterPasteEnabled: true
            ),
            pasteboard: pasteboard,
            pasteAction: {},
            restoreDelayAfterPaste: 0
        )

        XCTAssertTrue(result.copied)
        XCTAssertTrue(result.autoPasted)
        XCTAssertTrue(result.restoredOriginalClipboard)
        XCTAssertEqual(ClipboardHelper.getClipboardContent(pasteboard: pasteboard), "original")
    }

    func testWithoutAutoPasteOrAutoCopyLeavesClipboardUntouched() {
        XCTAssertTrue(ClipboardHelper.copyToClipboard("original", pasteboard: pasteboard))

        let result = ClipboardHelper.deliverTranscriptDetailed(
            "fresh transcript",
            behavior: TranscriptClipboardBehavior(
                autoPasteEnabled: false,
                copyTranscriptToClipboardEnabled: false,
                restoreOriginalClipboardAfterPasteEnabled: false
            ),
            pasteboard: pasteboard,
            pasteAction: { XCTFail("Paste should not be triggered when clipboard delivery is disabled.") }
        )

        XCTAssertEqual(result, ClipboardOperationResult.empty)
        XCTAssertEqual(ClipboardHelper.getClipboardContent(pasteboard: pasteboard), "original")
    }

    func testAutoPasteDelaysClipboardRestoreLongEnoughForPasteToReadTranscript() {
        XCTAssertTrue(ClipboardHelper.copyToClipboard("original", pasteboard: pasteboard))

        let startedAt = Date()
        let result = ClipboardHelper.deliverTranscriptDetailed(
            "fresh transcript",
            behavior: TranscriptClipboardBehavior(
                autoPasteEnabled: true,
                copyTranscriptToClipboardEnabled: false,
                restoreOriginalClipboardAfterPasteEnabled: true
            ),
            pasteboard: pasteboard,
            pasteAction: {
                XCTAssertEqual(ClipboardHelper.getClipboardContent(pasteboard: self.pasteboard), "fresh transcript")
            },
            restoreDelayAfterPaste: 0.02
        )

        XCTAssertTrue(result.autoPasted)
        XCTAssertTrue(result.restoredOriginalClipboard)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.02)
        XCTAssertEqual(ClipboardHelper.getClipboardContent(pasteboard: pasteboard), "original")
    }
}

final class ElsonLocalConfigClipboardSettingsTests: XCTestCase {
    func testDecodingLegacyConfigDefaultsClipboardSettingsToFalse() throws {
        let encoded = try JSONEncoder().encode(ElsonLocalConfig.default)
        var jsonObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        jsonObject.removeValue(forKey: "copy_transcript_to_clipboard")
        jsonObject.removeValue(forKey: "restore_original_clipboard_after_paste")

        let legacyData = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(ElsonLocalConfig.self, from: legacyData)

        XCTAssertFalse(decoded.copyTranscriptToClipboard)
        XCTAssertFalse(decoded.restoreOriginalClipboardAfterPaste)
    }

    func testConfigRoundTripPersistsClipboardSettings() throws {
        var config = ElsonLocalConfig.default
        config.copyTranscriptToClipboard = true
        config.restoreOriginalClipboardAfterPaste = true

        let roundTripped = try JSONDecoder().decode(
            ElsonLocalConfig.self,
            from: JSONEncoder().encode(config)
        )

        XCTAssertTrue(roundTripped.copyTranscriptToClipboard)
        XCTAssertTrue(roundTripped.restoreOriginalClipboardAfterPaste)
    }
}
