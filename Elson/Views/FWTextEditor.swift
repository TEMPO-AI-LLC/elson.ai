import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FWTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    var isEditable: Bool = true
    var minVisibleLines: CGFloat = 1
    var maxVisibleLines: CGFloat? = nil
    var measuredHeight: Binding<CGFloat>? = nil
    var showsVerticalScrollerWhenClipped: Bool = false
    var textInsetX: CGFloat = 0
    var textInsetY: CGFloat = 0
    var lineFragmentPadding: CGFloat = 5
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onPasteAttachments: (([AgentAttachment]) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FWInsertionTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.string = text
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        textView.onPasteAttachments = onPasteAttachments
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainerInset = NSSize(width: textInsetX, height: textInsetY)
        textView.textContainer?.lineFragmentPadding = lineFragmentPadding
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.attach(textView: textView, scrollView: scrollView)
        context.coordinator.updateConfig(
            minVisibleLines: minVisibleLines,
            maxVisibleLines: maxVisibleLines,
            measuredHeight: measuredHeight,
            showsVerticalScrollerWhenClipped: showsVerticalScrollerWhenClipped
        )
        context.coordinator.remeasure()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? FWInsertionTextView else { return }

        if textView.string != text {
            textView.string = text
        }

        textView.isEditable = isEditable
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        textView.onPasteAttachments = onPasteAttachments
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainerInset = NSSize(width: textInsetX, height: textInsetY)
        textView.textContainer?.lineFragmentPadding = lineFragmentPadding
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        nsView.scrollerStyle = .overlay
        nsView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.attach(textView: textView, scrollView: nsView)
        context.coordinator.updateConfig(
            minVisibleLines: minVisibleLines,
            maxVisibleLines: maxVisibleLines,
            measuredHeight: measuredHeight,
            showsVerticalScrollerWhenClipped: showsVerticalScrollerWhenClipped
        )
        context.coordinator.remeasure()

        if isFocused, nsView.window?.firstResponder !== textView {
            // Defer to next runloop so the first click can both enter edit mode and focus.
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(textView)
            }
        } else if !isFocused, nsView.window?.firstResponder === textView {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var isFocused: Bool
        weak var textView: FWInsertionTextView?
        weak var scrollView: NSScrollView?

        private var boundsObserver: NSObjectProtocol?
        private var lastAppliedHeight: CGFloat = .nan

        private var minVisibleLines: CGFloat = 1
        private var maxVisibleLines: CGFloat? = nil
        private var measuredHeight: Binding<CGFloat>? = nil
        private var showsVerticalScrollerWhenClipped: Bool = false

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            _text = text
            _isFocused = isFocused
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            remeasure()
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused = false
        }

        func attach(textView: FWInsertionTextView, scrollView: NSScrollView) {
            self.textView = textView

            if self.scrollView !== scrollView {
                if let boundsObserver {
                    NotificationCenter.default.removeObserver(boundsObserver)
                    self.boundsObserver = nil
                }

                self.scrollView = scrollView
                scrollView.contentView.postsBoundsChangedNotifications = true

                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.remeasure()
                    }
                }
            }
        }

        func updateConfig(
            minVisibleLines: CGFloat,
            maxVisibleLines: CGFloat?,
            measuredHeight: Binding<CGFloat>?,
            showsVerticalScrollerWhenClipped: Bool
        ) {
            self.minVisibleLines = minVisibleLines
            self.maxVisibleLines = maxVisibleLines
            self.measuredHeight = measuredHeight
            self.showsVerticalScrollerWhenClipped = showsVerticalScrollerWhenClipped
        }

        func remeasure() {
            guard let textView, let scrollView else { return }
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else { return }

            let contentWidth = scrollView.contentView.bounds.width
            if contentWidth > 0 {
                // Keep wrapping stable: the container size must track the current content width.
                textContainer.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
                textView.frame.size.width = contentWidth
            }

            layoutManager.ensureLayout(for: textContainer)

            let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let lineHeight = layoutManager.defaultLineHeight(for: font)
            let usedRect = layoutManager.usedRect(for: textContainer)

            // `usedRect` can be inconsistent around trailing newlines because the layout manager may or may not
            // include the extra line fragment (caret line) in `usedRect`. Use the max Y of both to avoid
            // transient +1-line jumps when inserting a newline at the end.
            let extraUsedRect = layoutManager.extraLineFragmentUsedRect
            let layoutHeight = max(usedRect.maxY, extraUsedRect.maxY)
            let usedHeightAdjusted = max(layoutHeight, lineHeight)
            let insetY = textView.textContainerInset.height
            let contentHeight = usedHeightAdjusted + (2 * insetY)

            let minHeight = max(0, lineHeight * minVisibleLines + (2 * insetY))
            let maxHeight = maxVisibleLines.map { lineHeight * $0 + (2 * insetY) }

            let targetHeight: CGFloat
            if let maxHeight {
                targetHeight = min(max(contentHeight, minHeight), maxHeight)
            } else {
                targetHeight = max(contentHeight, minHeight)
            }

            if let maxHeight, showsVerticalScrollerWhenClipped {
                scrollView.hasVerticalScroller = contentHeight > maxHeight
            } else {
                scrollView.hasVerticalScroller = false
            }

            guard let measuredHeight else { return }
            if !lastAppliedHeight.isNaN, abs(lastAppliedHeight - targetHeight) <= 0.5 { return }
            lastAppliedHeight = targetHeight

            if abs(measuredHeight.wrappedValue - targetHeight) > 0.5 {
                measuredHeight.wrappedValue = targetHeight
            }
        }
    }
}

final class FWInsertionTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onPasteAttachments: (([AgentAttachment]) -> Void)?

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var adjusted = rect
        adjusted.size.width = max(2, rect.size.width)
        super.drawInsertionPoint(in: adjusted, color: color, turnedOn: flag)
    }

    override func paste(_ sender: Any?) {
        guard let onPasteAttachments else {
            super.paste(sender)
            return
        }

        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems ?? []

        var attachments: [AgentAttachment] = []
        attachments.reserveCapacity(min(5, items.count))

        for item in items {
            if attachments.count >= 5 { break }
            if let attachment = Self.attachmentFromPasteboardItem(item) {
                attachments.append(attachment)
            }
        }

        if attachments.isEmpty {
            // Common case: Finder copy provides file URLs but not raw image data.
            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] {
                for url in urls {
                    if attachments.count >= 5 { break }
                    if let attachment = Self.attachmentFromFileURL(url) {
                        attachments.append(attachment)
                    }
                }
            }
        }

        if attachments.isEmpty {
            // Common case: Browser/Preview copy provides NSImage objects.
            if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
                for image in images {
                    if attachments.count >= 5 { break }
                    if let jpeg = ImageAttachmentCodec.jpegData(from: image), !jpeg.isEmpty {
                        attachments.append(AgentAttachment(fileName: "pasted.jpg", mimeType: "image/jpeg", data: jpeg))
                    }
                }
            }
        }

        if !attachments.isEmpty {
            onPasteAttachments(attachments)
            return
        }

        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        // Return (36) / Keypad Enter (76)
        if event.keyCode == 36 || event.keyCode == 76 {
            let hasShift = event.modifierFlags.contains(.shift)
            if hasShift {
                insertNewline(nil)
                return
            }
            if !hasShift, let onSubmit {
                onSubmit()
                return
            }
        }

        // Escape (53)
        if event.keyCode == 53, let onEscape {
            onEscape()
            return
        }

        super.keyDown(with: event)
    }

    private static func attachmentFromPasteboardItem(_ item: NSPasteboardItem) -> AgentAttachment? {
        if let urlString = item.string(forType: .fileURL) ?? item.string(forType: NSPasteboard.PasteboardType("public.file-url")) {
            if let url = URL(string: urlString), let attachment = attachmentFromFileURL(url) {
                return attachment
            }
        }

        if let data = item.data(forType: NSPasteboard.PasteboardType("public.jpeg")), let jpeg = ImageAttachmentCodec.jpegData(from: data), !jpeg.isEmpty {
            return AgentAttachment(fileName: "pasted.jpg", mimeType: "image/jpeg", data: jpeg)
        }
        if let data = item.data(forType: .png), let jpeg = ImageAttachmentCodec.jpegData(from: data), !jpeg.isEmpty {
            return AgentAttachment(fileName: "pasted.jpg", mimeType: "image/jpeg", data: jpeg)
        }
        if let data = item.data(forType: .tiff), let jpeg = ImageAttachmentCodec.jpegData(from: data), !jpeg.isEmpty {
            return AgentAttachment(fileName: "pasted.jpg", mimeType: "image/jpeg", data: jpeg)
        }

        return nil
    }

    private static func attachmentFromFileURL(_ url: URL) -> AgentAttachment? {
        guard url.isFileURL else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        if values?.isDirectory == true { return nil }

        let fileName = url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent
        let contentType = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let mimeType = contentType?.preferredMIMEType ?? "application/octet-stream"

        if String(mimeType).lowercased().starts(with: "image/") {
            guard let jpeg = ImageAttachmentCodec.jpegData(fromFileURL: url), !jpeg.isEmpty else { return nil }
            let base = url.deletingPathExtension().lastPathComponent
            let name = base.isEmpty ? "image.jpg" : "\(base).jpg"
            return AgentAttachment(fileName: name, mimeType: "image/jpeg", data: jpeg)
        }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return AgentAttachment(fileName: fileName, mimeType: mimeType, data: data)
    }
}
