import SwiftUI
import AppKit

final class FloatingIndicatorWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Make window always on top
        self.level = .floating
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.hasShadow = false
        self.ignoresMouseEvents = false  // Allow clicks for popover interaction
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position in bottom-right corner
        positionWindow()
    }

    // Track drag state
    private var initialMouseLocation: NSPoint?
    private var initialWindowOrigin: NSPoint?
    private var isDragging = false
    private let dragThreshold: CGFloat = 3.0

    // Prevent becoming main window (keep main app window as main)
    override var canBecomeMain: Bool {
        return false
    }

    override func mouseDown(with event: NSEvent) {
        // Capture initial state
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = self.frame.origin
        isDragging = false
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let initialMouseLocation = initialMouseLocation,
              let initialWindowOrigin = initialWindowOrigin,
              let screen = self.screen ?? NSScreen.main else { return }
        
        let currentMouseLocation = NSEvent.mouseLocation
        let deltaY = currentMouseLocation.y - initialMouseLocation.y
        
        // Check threshold to avoid accidental drags
        if !isDragging && abs(deltaY) > dragThreshold {
            isDragging = true
        }
        
        if isDragging {
            // New Frame Calculation
            var newY = initialWindowOrigin.y + deltaY // + because moving mouse UP increases Y and window Y should increase
            
            let screenFrame = screen.visibleFrame
            let windowHeight = self.frame.height
            
            // Clamp to screen bounds.
            // Since window is 64px but bubble is 44px (10px padding), 
            // clamping exactly to screen edges gives us a nice ~10px visual margin.
            let maxY = screenFrame.maxY - windowHeight
            let minY = screenFrame.minY
            
            // Clamp
            newY = min(maxY, max(minY, newY))
            
            self.setFrameOrigin(NSPoint(x: initialWindowOrigin.x, y: newY))
            
            // Layout popover if needed (or just ensure it knows we moved)
            NotificationCenter.default.post(name: .bubbleDidMove, object: nil)
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            // It was a click!
            NotificationCenter.default.post(name: .toggleBubbleInterface, object: nil)
        }
        
        initialMouseLocation = nil
        initialWindowOrigin = nil
        isDragging = false
    }

    private func positionWindow() {
        let targetScreen = self.screen ?? NSScreen.main
        guard let screen = targetScreen else { return }

        let screenFrame = screen.visibleFrame
        let windowSize = self.frame.size

        // Position with padding from bottom-right.
        // Window is 64px wide, bubble is 44px (10px internal padding).
        // If we want ~20px visual margin:
        // x = maxX - (20 visual + 10 internal + 44 bubble + 10 internal) ... wait
        // x = maxX - 64 (window width) - 10 (extra visual margin).
        // Total visual margin = 10 (extra) + 10 (internal) = 20px.
        let x = screenFrame.maxX - windowSize.width - 10
        let y = screenFrame.minY + 100 // Slightly higher initially
        
        // Ensure within bounds
        let safeX = min(screenFrame.maxX - windowSize.width, max(screenFrame.minX, x))
        let safeY = min(screenFrame.maxY - windowSize.height, max(screenFrame.minY, y))

        self.setFrameOrigin(NSPoint(x: safeX, y: safeY))
    }

    func updatePosition() {
        // Only reset if completely off screen or needed?
        // For now, let's leave updatePosition for explicit resets.
        // positionWindow()
    }
}

extension Notification.Name {
    static let openPopover = Notification.Name("openPopover")
    static let closePopover = Notification.Name("closePopover")
    static let bubbleDidMove = Notification.Name("bubbleDidMove")
    static let bubbleDidDrag = Notification.Name("bubbleDidDrag")
    static let toggleBubbleInterface = Notification.Name("toggleBubbleInterface")
    static let bringBubbleToFront = Notification.Name("bringBubbleToFront")
    static let openThreadWindow = Notification.Name("openThreadWindow")
    static let toggleThreadWindow = Notification.Name("toggleThreadWindow")
    static let openFeedbackWindow = Notification.Name("openFeedbackWindow")
    static let closeFeedbackWindow = Notification.Name("closeFeedbackWindow")
    static let insertTextIntoThreadComposer = Notification.Name("insertTextIntoThreadComposer")
    static let mainAppWindowDidResolve = Notification.Name("mainAppWindowDidResolve")
    static let folderAccessPromptWillBegin = Notification.Name("folderAccessPromptWillBegin")
    static let folderAccessPromptDidFinish = Notification.Name("folderAccessPromptDidFinish")
    static let completeInstallOnboardingHandoff = Notification.Name("completeInstallOnboardingHandoff")
    static let showSettingsElsonMDTab = Notification.Name("showSettingsElsonMDTab")
    static let authDidReset = Notification.Name("authDidReset")
    static let authDidConnect = Notification.Name("authDidConnect")
    static let invalidatePopoverDraft = Notification.Name("invalidatePopoverDraft")
}
