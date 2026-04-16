import AppKit

final class FloatingPopoverWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 270, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            DebugLog.reset("FloatingPopoverWindow.keyDown(ESC): posting .closePopover (isVisible=\(isVisible) isKeyWindow=\(isKeyWindow))")
            NotificationCenter.default.post(name: .closePopover, object: nil)
            return
        }
        super.keyDown(with: event)
    }

    override func resignKey() {
        super.resignKey()
        // If we lost key focus because the app presented another window (e.g. a confirmation dialog),
        // keep the popover open. We'll dismiss on genuine "click outside app" via the global monitor,
        // or when the app deactivates.
        if NSApp.isActive {
            DebugLog.reset("FloatingPopoverWindow.resignKey(): app still active -> not dismissing (isVisible=\(isVisible))")
            return
        }

        DebugLog.reset("FloatingPopoverWindow.resignKey(): app inactive -> posting .closePopover (isVisible=\(isVisible))")
        NotificationCenter.default.post(name: .closePopover, object: nil)
    }
}
