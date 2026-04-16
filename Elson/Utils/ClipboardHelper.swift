import Foundation
import AppKit

struct TranscriptClipboardBehavior: Equatable {
    let autoPasteEnabled: Bool
    let copyTranscriptToClipboardEnabled: Bool
    let restoreOriginalClipboardAfterPasteEnabled: Bool

    var shouldWriteTranscriptToClipboard: Bool {
        autoPasteEnabled || copyTranscriptToClipboardEnabled
    }

    var shouldRestoreOriginalClipboardAfterPaste: Bool {
        autoPasteEnabled && restoreOriginalClipboardAfterPasteEnabled
    }
}

struct ClipboardOperationResult: Equatable {
    let copied: Bool
    let autoPasted: Bool
    let restoredOriginalClipboard: Bool
    let copyStartedAt: Date?
    let copyCompletedAt: Date?
    let pasteStartedAt: Date?
    let pasteCompletedAt: Date?

    static let empty = ClipboardOperationResult(
        copied: false,
        autoPasted: false,
        restoredOriginalClipboard: false,
        copyStartedAt: nil,
        copyCompletedAt: nil,
        pasteStartedAt: nil,
        pasteCompletedAt: nil
    )
}

class ClipboardHelper {
    private static let defaultRestoreDelayAfterPaste: TimeInterval = 0.18

    @discardableResult
    static func copyToClipboard(_ text: String, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        
        print("Copied to clipboard: \(text.prefix(50))\(text.count > 50 ? "..." : "")")
        return wrote && getClipboardContent(pasteboard: pasteboard) == text
    }
    
    static func getClipboardContent(pasteboard: NSPasteboard = .general) -> String? {
        return pasteboard.string(forType: .string)
    }
    
    static func clearClipboard(pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
    }

    static func deliverTranscriptDetailed(
        _ text: String,
        behavior: TranscriptClipboardBehavior,
        pasteboard: NSPasteboard = .general,
        pasteAction: (() -> Void)? = nil,
        restoreDelayAfterPaste: TimeInterval = ClipboardHelper.defaultRestoreDelayAfterPaste
    ) -> ClipboardOperationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard behavior.shouldWriteTranscriptToClipboard else { return .empty }

        let originalSnapshot = behavior.shouldRestoreOriginalClipboardAfterPaste
            ? PasteboardSnapshot.capture(from: pasteboard)
            : nil
        let copyStartedAt = Date()
        guard copyToClipboard(trimmed, pasteboard: pasteboard) else {
            let copyCompletedAt = Date()
            let restoredOriginalClipboard = restoreSnapshotIfNeeded(
                originalSnapshot,
                to: pasteboard,
                afterDelay: 0
            )
            return ClipboardOperationResult(
                copied: false,
                autoPasted: false,
                restoredOriginalClipboard: restoredOriginalClipboard,
                copyStartedAt: copyStartedAt,
                copyCompletedAt: copyCompletedAt,
                pasteStartedAt: nil,
                pasteCompletedAt: nil
            )
        }
        let copyCompletedAt = Date()

        var pasteStartedAt: Date?
        var pasteCompletedAt: Date?
        if behavior.autoPasteEnabled {
            pasteStartedAt = Date()
            (pasteAction ?? pasteActiveApplication)()
            pasteCompletedAt = Date()
        }
        let restoredOriginalClipboard = restoreSnapshotIfNeeded(
            originalSnapshot,
            to: pasteboard,
            afterDelay: behavior.autoPasteEnabled ? restoreDelayAfterPaste : 0
        )

        return ClipboardOperationResult(
            copied: true,
            autoPasted: behavior.autoPasteEnabled,
            restoredOriginalClipboard: restoredOriginalClipboard,
            copyStartedAt: copyStartedAt,
            copyCompletedAt: copyCompletedAt,
            pasteStartedAt: pasteStartedAt,
            pasteCompletedAt: pasteCompletedAt
        )
    }

    @discardableResult
    static func deliverTranscript(_ text: String, behavior: TranscriptClipboardBehavior) -> Bool {
        let result = deliverTranscriptDetailed(text, behavior: behavior)
        return result.autoPasted || result.copied
    }

    static func pasteActiveApplication() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey: CGKeyCode = 9
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private static func restoreSnapshotIfNeeded(
        _ snapshot: PasteboardSnapshot?,
        to pasteboard: NSPasteboard,
        afterDelay delay: TimeInterval
    ) -> Bool {
        guard let snapshot else { return false }
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        snapshot.restore(to: pasteboard)
        return true
    }
}

private struct PasteboardSnapshot {
    let items: [NSPasteboardItem]

    static func capture(from pasteboard: NSPasteboard) -> Self {
        Self(items: (pasteboard.pasteboardItems ?? []).map(clone))
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        _ = pasteboard.writeObjects(items)
    }

    private static func clone(_ item: NSPasteboardItem) -> NSPasteboardItem {
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) {
                copy.setData(data, forType: type)
            } else if let string = item.string(forType: type) {
                copy.setString(string, forType: type)
            } else if let propertyList = item.propertyList(forType: type) {
                copy.setPropertyList(propertyList, forType: type)
            }
        }
        return copy
    }
}
