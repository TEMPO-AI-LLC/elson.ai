import AppKit
import ApplicationServices
import Foundation

struct FrontmostAppContextSnapshot: Hashable, Sendable {
    let appName: String?
    let bundleId: String?
    let windowTitle: String?
}

enum FrontmostAppContextResolver {
    static func snapshot() -> FrontmostAppContextSnapshot {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return FrontmostAppContextSnapshot(
            appName: normalized(frontmost?.localizedName),
            bundleId: normalized(frontmost?.bundleIdentifier),
            windowTitle: focusedWindowTitle(for: frontmost)
        )
    }

    private static func focusedWindowTitle(for application: NSRunningApplication?) -> String? {
        guard AXIsProcessTrusted(),
              let application,
              application.processIdentifier > 0
        else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)

        if let focusedWindow = copyElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement),
           let title = stringAttribute(kAXTitleAttribute as CFString, from: focusedWindow)
            ?? stringAttribute(kAXDocumentAttribute as CFString, from: focusedWindow)
        {
            return title
        }

        if let mainWindow = copyElementAttribute(kAXMainWindowAttribute as CFString, from: appElement),
           let title = stringAttribute(kAXTitleAttribute as CFString, from: mainWindow)
            ?? stringAttribute(kAXDocumentAttribute as CFString, from: mainWindow)
        {
            return title
        }

        return nil
    }

    private static func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return normalized(value as? String)
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
