import SwiftUI

struct ElsonSettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elsonGlassCard(cornerRadius: 24)
    }
}

struct ElsonPermissionRow: View {
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

struct ElsonMaskedAPIKeyEditor: View {
    let title: String
    let persistedValue: String
    @Binding var draftValue: String
    @Binding var isEditing: Bool
    let isSaving: Bool
    let statusText: String?
    let maskedValue: String
    let onSave: () -> Void
    let onCancel: () -> Void

    private var persistedSecret: String {
        persistedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draftSecret: String {
        draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasStoredValue: Bool {
        !persistedSecret.isEmpty
    }

    private var isDirty: Bool {
        draftSecret != persistedSecret
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            if hasStoredValue && !isEditing {
                HStack {
                    Text(maskedValue)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Spacer()
                    Button("Change") {
                        draftValue = persistedValue
                        isEditing = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .elsonGlassSurface(.chrome, in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
            } else {
                HStack(spacing: 8) {
                    SecureField("\(title) API Key", text: $draftValue)
                        .textFieldStyle(.roundedBorder)

                    if hasStoredValue {
                        Button {
                            onCancel()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                    }

                    if isDirty {
                        Button("✅", action: onSave)
                            .buttonStyle(.plain)
                            .font(.system(size: 16))
                            .disabled(isSaving)
                    }
                }
            }

            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
