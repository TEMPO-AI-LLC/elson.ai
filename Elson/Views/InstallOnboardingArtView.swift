import SwiftUI

struct InstallOnboardingArtView: View {
    let step: InstallOnboardingStep

    var body: some View {
        switch step {
        case .interactionModel:
            interactionModelArt
        case .apiKeys:
            apiArt
        case .microphone:
            micArt
        case .screen:
            screenArt
        case .accessibility:
            accessibilityArt
        case .fullDiskAccess:
            fullDiskAccessArt
        case .folder:
            folderArt
        case .transcriptShortcut:
            shortcutArt(primary: .orange, secondary: .white.opacity(0.24))
        case .agentShortcut:
            shortcutArt(primary: .purple, secondary: .white.opacity(0.24))
        case .celebration:
            celebrationArt
        }
    }

    private var interactionModelArt: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.14 + (0.05 * (0.5 + 0.5 * sin(t * 2.0)))

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 260, height: 136)

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    .frame(width: 260, height: 136)

                HStack(spacing: 14) {
                    modeBadge(
                        title: "Transcript",
                        icon: "text.bubble",
                        accent: Color.orange.opacity(0.72 + pulse)
                    )
                    modeBadge(
                        title: "Agent",
                        icon: "sparkles",
                        accent: Color.purple.opacity(0.72 + pulse)
                    )
                }
            }
        }
    }

    private var apiArt: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let rotation = Angle(degrees: sin(t * 1.3) * 10)
            let scale = 1 + (sin(t * 2.2) * 0.06)

            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 140, height: 140)

                Image(systemName: "brain.head.profile")
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .scaleEffect(scale)

                Image(systemName: "key.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.orange.opacity(0.92))
                    .rotationEffect(rotation)
                    .offset(x: 48, y: -34)

                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white)
                    .offset(x: -44, y: 36)
                    .opacity(0.5 + (sin(t * 3) * 0.4))
            }
        }
    }

    private var micArt: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.14))
                    .frame(width: 150, height: 150)

                Image(systemName: "mic.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))

                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { index in
                        let height = 18 + abs(sin(t * 3 + Double(index) * 0.55)) * 38
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.blue.opacity(0.86))
                            .frame(width: 10, height: height)
                    }
                }
                .offset(y: 60)
            }
        }
    }

    private var screenArt: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let y = CGFloat(sin(t * 1.2) * 32)

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                    .frame(width: 210, height: 130)

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.12), Color.white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 190, height: 110)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.green.opacity(0.85))
                    .frame(width: 154, height: 4)
                    .blur(radius: 1)
                    .offset(y: y)

                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
        }
    }

    private var accessibilityArt: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let offset = CGFloat(sin(t * 2) * 12)

            ZStack {
                Circle()
                    .fill(Color.pink.opacity(0.14))
                    .frame(width: 150, height: 150)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 176, height: 108)

                Image(systemName: "command")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .offset(x: -24)

                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(Color.pink.opacity(0.9))
                    .offset(x: 42, y: offset)
            }
        }
    }

    private var fullDiskAccessArt: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.25 + (sin(t * 2.2) * 0.08)

            ZStack {
                Circle()
                    .fill(Color.teal.opacity(0.14))
                    .frame(width: 150, height: 150)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 184, height: 112)

                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.90))

                Image(systemName: "lock.open.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.teal.opacity(0.78 + pulse))
                    .offset(x: 58, y: -30)
            }
        }
    }

    private func shortcutArt(primary: Color, secondary: Color) -> some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let glow = 0.35 + (sin(t * 2.3) * 0.18)

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 220, height: 124)

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    .frame(width: 220, height: 124)

                HStack(spacing: 12) {
                    keycap("fn", accent: primary)
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.7))
                    keycap("⌘", accent: secondary.opacity(glow))
                }

                Image(systemName: "keyboard")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .offset(y: -42)
            }
        }
    }

    private func keycap(_ label: String, accent: Color) -> some View {
        Text(label)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(width: 64, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(accent.opacity(0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
    }

    private func modeBadge(title: String, icon: String, accent: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 64, height: 64)
                .background(
                    Circle()
                        .fill(accent)
                )

            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.88))
        }
    }

    private var folderArt: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let fileOffset = CGFloat(12 + abs(sin(t * 1.8)) * 16)

            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.14))
                    .frame(width: 150, height: 150)

                Image(systemName: "folder.fill")
                    .font(.system(size: 88, weight: .semibold))
                    .foregroundStyle(Color.yellow.opacity(0.95))

                Image(systemName: "doc.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .offset(x: fileOffset, y: -6)
            }
        }
    }

    private var celebrationArt: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let blueGlow = 0.16 + (0.06 * (0.5 + 0.5 * sin(t * 2.0)))
            let purpleGlow = 0.12 + (0.05 * (0.5 + 0.5 * sin(t * 2.3 + .pi / 3)))
            let arrowDrift = 3.0 * sin(t * 1.6)
            let arrowEndpoint = CGPoint(x: 154, y: 146)

            ZStack {
                Circle()
                    .fill(Color.blue.opacity(blueGlow))
                    .frame(width: 180, height: 180)
                    .offset(x: -30, y: -26)

                Circle()
                    .fill(Color.purple.opacity(purpleGlow))
                    .frame(width: 154, height: 154)
                    .offset(x: 44, y: 26)

                Path { path in
                    path.move(to: CGPoint(x: 46, y: 42))
                    path.addCurve(
                        to: arrowEndpoint,
                        control1: CGPoint(x: 40, y: 112),
                        control2: CGPoint(x: 104, y: 176)
                    )
                }
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            Color.blue.opacity(0.82),
                            Color.purple.opacity(0.88),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round)
                )
                .offset(y: arrowDrift)

                Path { path in
                    path.move(to: arrowEndpoint)
                    path.addLine(to: CGPoint(x: 118, y: 144))
                    path.move(to: arrowEndpoint)
                    path.addLine(to: CGPoint(x: 146, y: 110))
                }
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.blue.opacity(0.9),
                            Color.purple.opacity(0.95),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round)
                )
                .offset(y: arrowDrift)

                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.95), Color.purple.opacity(0.95)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .offset(x: 78, y: 76)
            }
            .frame(width: 220, height: 220)
        }
    }
}
