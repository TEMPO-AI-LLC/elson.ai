import SwiftUI

enum ElsonGlassSurfaceStyle {
    case chrome
    case bubble
    case control

    fileprivate var compatTint: Color {
        switch self {
        case .chrome:
            return Color.white.opacity(0.05)
        case .bubble:
            return Color.white.opacity(0.08)
        case .control:
            return Color.accentColor.opacity(0.10)
        }
    }

    fileprivate var interactive: Bool {
        switch self {
        case .chrome:
            return false
        case .bubble, .control:
            return true
        }
    }
}

extension View {
    func elsonGlassSurface<S: Shape>(
        _ style: ElsonGlassSurfaceStyle,
        in shape: S,
        interactive: Bool? = nil,
        tint: Color? = nil
    ) -> some View {
#if ELSON_COMPAT15_VARIANT
        modifier(
            ElsonCompatSurfaceModifier(
                shape: shape,
                tint: tint ?? style.compatTint
            )
        )
#else
        let baseGlass: Glass = if let tint {
            Glass.regular.tint(tint)
        } else {
            Glass.regular
        }
        let glass = (interactive ?? style.interactive) ? baseGlass.interactive() : baseGlass

        return glassEffect(glass, in: shape)
#endif
    }

    func elsonGlassCard(cornerRadius: CGFloat = 24) -> some View {
        elsonGlassSurface(.chrome, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func elsonGlassControl(cornerRadius: CGFloat = 20) -> some View {
        elsonGlassSurface(.control, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func elsonProminentButtonStyle() -> some View {
#if ELSON_COMPAT15_VARIANT
        buttonStyle(.borderedProminent)
#else
        buttonStyle(.glassProminent)
#endif
    }
}

struct ElsonGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
#if ELSON_COMPAT15_VARIANT
        content
#else
        GlassEffectContainer(spacing: spacing) {
            content
        }
#endif
    }
}

private struct ElsonCompatSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape
                    .fill(tint)
            }
            .overlay {
                shape
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.14), radius: 18, y: 8)
    }
}
