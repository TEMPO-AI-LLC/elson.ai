import AppKit
import SwiftUI

final class WindowSizer: ObservableObject {
    weak var window: NSWindow?

    private var lastApplied: CGSize = .zero
    private var pending: CGSize?
    private var scheduled = false

    func attach(window: NSWindow) {
        self.window = window
    }

    func requestResize(to size: CGSize) {
        // Filter noise / uninitialized layout
        guard size.width > 20, size.height > 20 else { return }

        // Stabilize (rounding prevents 0.5px oscillation)
        let target = CGSize(
            width: ceil(size.width),
            height: ceil(size.height)
        )

        // Coalesce: keep only last request
        pending = target
        scheduleApply()
    }

    private func scheduleApply() {
        guard !scheduled else { return }
        scheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.applyPendingIfNeeded()
        }
    }

    private func applyPendingIfNeeded() {
        guard let window, let target = pending else { return }
        pending = nil

        // Guard against endless resizes
        guard target != lastApplied else {
            print("📏 DEBUG: WindowSizer skipping - same as last applied: \(target.width) x \(target.height)")
            return
        }
        lastApplied = target

        let oldFrame = window.frame
        let newContentRect = NSRect(origin: .zero, size: target)
        let newFrameSize = window.frameRect(forContentRect: newContentRect).size

        print("📏 DEBUG: WindowSizer resizing window from \(oldFrame.size.width)x\(oldFrame.size.height) to \(newFrameSize.width)x\(newFrameSize.height)")

        // Anchor: Bottom-Right stays in place
        let newOrigin = NSPoint(
            x: oldFrame.maxX - newFrameSize.width,
            y: oldFrame.minY
        )

        var newFrame = NSRect(origin: newOrigin, size: newFrameSize)

        // Optional: clamp to screen
        if let screen = window.screen {
            newFrame = newFrame.clamped(to: screen.visibleFrame)
        }

        // No animation = less layout stress
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            window.setFrame(newFrame, display: true)
        }
    }
}

private extension NSRect {
    func clamped(to bounds: NSRect) -> NSRect {
        var r = self
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        return r
    }
}
