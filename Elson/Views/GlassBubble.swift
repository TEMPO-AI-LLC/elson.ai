import SwiftUI

struct GlassBubble: View {
    enum Status {
        case idle
        case listening
        case processing
        case agentProcessing
        case success
        case agentSuccess
        case error

    }

    let status: Status
    let inputLevel: Double
    let action: () -> Void

    private var glassTint: Color? {
        switch status {
        case .idle:
            return nil
        case .listening:
            return Color.blue.opacity(0.16)
        case .processing:
            return Color(red: 1.0, green: 0.52, blue: 0.12).opacity(0.15)
        case .agentProcessing, .agentSuccess:
            return Color.purple.opacity(0.16)
        case .success:
            return Color.green.opacity(0.14)
        case .error:
            return Color(red: 1.0, green: 0.08, blue: 0.18).opacity(0.16)
        }
    }

    var body: some View {
        // Button removed - interaction handled by FloatingIndicatorWindow
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = max(0, min(1, inputLevel))
            let visibleLevel = max(0.10, level)
            let pulse = 0.5 + 0.5 * sin(t * 4.2)
            let activeBlue = Color.blue
            let errorRed = Color(red: 1.0, green: 0.08, blue: 0.18)
            let processingRedOrange = Color(red: 1.0, green: 0.28, blue: 0.12)

            let baseColor: Color = {
                switch status {
                case .idle:
                    return Color.white.opacity(0.18)
                case .listening:
                    return Color.white.opacity(0.24 + 0.18 * visibleLevel)
                case .processing, .agentProcessing:
                    return processingRedOrange.opacity(0.30 + 0.20 * pulse)
                case .success, .agentSuccess:
                    return Color.green.opacity(0.50)
                case .error:
                    return errorRed.opacity(0.56)
                }
            }()

            let outerGlow: Color = {
                switch status {
                case .listening:
                    return activeBlue.opacity(0.22 + 0.46 * visibleLevel)
                case .processing, .agentProcessing:
                    return processingRedOrange.opacity(0.24 + 0.28 * pulse)
                case .success, .agentSuccess:
                    return Color.green.opacity(0.34)
                case .error:
                    return errorRed.opacity(0.38)
                case .idle:
                    return Color.white.opacity(0.10)
                }
            }()

            ZStack {
                Circle()
                    .fill(baseColor)
                    .blur(radius: 5)

                Circle()
                    .stroke(outerGlow, lineWidth: 4)
                    .blur(radius: 4)
                    .scaleEffect(status == .listening ? 1.0 + 0.12 * visibleLevel : 1.0 + 0.08 * pulse)

                stateGlyph(level: visibleLevel, pulse: pulse)
            }
            .frame(width: 44, height: 44)
            .elsonGlassSurface(.bubble, in: Circle(), tint: glassTint)
        }
    }

    @ViewBuilder
    private func stateGlyph(level: Double, pulse: Double) -> some View {
        switch status {
        case .listening:
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let emphasis = [0.68, 1.0, 0.78][index]
                    Capsule()
                        .fill(index == 1 ? Color.blue : Color.white.opacity(0.88))
                        .frame(width: 5, height: 9 + 23 * level * emphasis)
                        .shadow(color: Color.blue.opacity(0.32 + 0.28 * level), radius: 5)
                }
            }
            .frame(width: 30, height: 32)
        case .processing, .agentProcessing:
            Circle()
                .fill(Color(red: 1.0, green: 0.28, blue: 0.12).opacity(0.78 + 0.20 * pulse))
                .frame(width: 18 + 5 * pulse, height: 18 + 5 * pulse)
        case .success, .agentSuccess:
            Circle()
                .fill(Color.green.opacity(0.92))
                .frame(width: 20, height: 20)
        case .error:
            Circle()
                .fill(Color(red: 1.0, green: 0.08, blue: 0.18).opacity(0.92))
                .frame(width: 20, height: 20)
        case .idle:
            Circle()
                .fill(Color.white.opacity(0.56))
                .frame(width: 12, height: 12)
        }
    }
}

#Preview {
    ZStack {
        // Show against a background to see glass effect
        LinearGradient(
            colors: [.blue, Color(red: 107.0 / 255.0, green: 38.0 / 255.0, blue: 217.0 / 255.0), .pink],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        VStack(spacing: 30) {
            GlassBubble(status: .idle, inputLevel: 0, action: {})
            GlassBubble(status: .listening, inputLevel: 0.8, action: {})
            GlassBubble(status: .processing, inputLevel: 0, action: {})
            GlassBubble(status: .agentProcessing, inputLevel: 0, action: {})
            GlassBubble(status: .success, inputLevel: 0, action: {})
            GlassBubble(status: .agentSuccess, inputLevel: 0, action: {})
            GlassBubble(status: .error, inputLevel: 0, action: {})
        }
    }
}
