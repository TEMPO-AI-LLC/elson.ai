import SwiftUI

struct CopyFeedbackButton: View {
    let text: String
    var isVisible: Bool = true
    var onSuccess: (() -> Void)? = nil

    @State private var isCopied = false
    @State private var isHoveringButton = false
    @State private var resetTask: Task<Void, Never>? = nil

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCopy: Bool {
        !trimmedText.isEmpty
    }

    private var shouldShow: Bool {
        canCopy && (isVisible || isCopied || isHoveringButton)
    }

    var body: some View {
        Button {
            copy()
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .opacity(shouldShow ? 1 : 0)
        .allowsHitTesting(shouldShow && canCopy)
        .onHover { hovering in
            isHoveringButton = hovering
        }
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private func copy() {
        guard canCopy, ClipboardHelper.copyToClipboard(trimmedText) else { return }

        onSuccess?()
        resetTask?.cancel()
        isCopied = true

        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            isCopied = false
            resetTask = nil
        }
    }
}
