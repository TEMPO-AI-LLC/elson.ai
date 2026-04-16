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

    @State private var isPulsing = false
    @State private var phaseA = Double.random(in: 0...(2 * Double.pi))
    @State private var phaseB = Double.random(in: 0...(2 * Double.pi))

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
            let lvl = max(0, min(1, inputLevel))

            // Make "no speech" still visible while listening.
            let recordingStrength = status == .listening ? max(0.08, lvl) : 0

            // Random-ish movement for purple/green.
            let a = 0.5 + 0.5 * sin(t * 1.25 + phaseA)
            let b = 0.5 + 0.5 * sin(t * 0.95 + phaseB)

            let baseScale = isPulsing ? 1.15 : 1.0

            // Keep transcription clearly orange, and error clearly red (not close to orange).
            let transcriptionOrange = Color(red: 1.0, green: 0.52, blue: 0.12)
            let activeBlue = Color.blue
            let errorRed = Color(red: 1.0, green: 0.08, blue: 0.18)

            let baseColor: Color = {
                switch status {
                case .idle:
                    return Color.gray.opacity(0.24)
                case .listening:
                    return activeBlue.opacity(0.46)
                case .processing:
                    return transcriptionOrange.opacity(0.46)
                case .agentProcessing:
                    return Color.purple.opacity(0.48)
                case .success:
                    return Color.green.opacity(0.46)
                case .agentSuccess:
                    return Color.purple.opacity(0.50)
                case .error:
                    return errorRed.opacity(0.58)
                }
            }()

            let accentColor: Color = {
                switch status {
                case .listening:
                    return activeBlue
                case .agentProcessing, .agentSuccess:
                    return Color.purple
                default:
                    return transcriptionOrange
                }
            }()

            let accentOpacity: Double = {
                switch status {
                case .listening:
                    return 0.10 + 0.56 * recordingStrength
                case .agentProcessing:
                    return 0.18 + 0.16 * a
                case .agentSuccess:
                    return 0.22 + 0.28 * b
                default:
                    return 0.0
                }
            }()

            let processingAccentOpacity: Double = {
                switch status {
                case .processing:
                    return 0.11 + 0.24 * a
                case .agentProcessing:
                    return 0.08 + 0.20 * b
                default:
                    return 0.0
                }
            }()

            let greenOpacity: Double = {
                switch status {
                case .success:
                    return 0.14 + 0.26 * b
                case .agentSuccess:
                    return 0.05 + 0.10 * a
                case .listening:
                    return 0.03 * (0.2 + 0.8 * b)
                case .processing:
                    return 0.04 * (0.2 + 0.8 * b)
                case .agentProcessing:
                    return 0.0
                case .idle, .error:
                    return 0.0
                }
            }()

            ZStack {
                // Base (existing look)
                Circle()
                    .fill(baseColor)
                    .blur(radius: 6)
                    .scaleEffect(baseScale)

                // Accent "sheen" (recording level + agent)
                Circle()
                    .stroke(accentColor.opacity(accentOpacity), lineWidth: 6)
                    .blur(radius: 5)
                    .scaleEffect(1.0 + 0.20 * recordingStrength)
                    .compositingGroup()
                    .mask {
                        Circle()
                            .inset(by: 3)
                            .fill(Color.white)
                            .blur(radius: 1)
                    }

                // Processing + Success shimmer (soft-clipped so it never reaches the 80x80 window edge)
                ZStack {
                    Circle()
                        .stroke(accentColor.opacity(processingAccentOpacity), lineWidth: 5)
                        .blur(radius: 7)
                        .scaleEffect(1.05 + 0.12 * a)

                    Circle()
                        .stroke(Color.green.opacity(greenOpacity), lineWidth: 5)
                        .blur(radius: 7)
                        .scaleEffect(1.03 + 0.12 * b)
                }
                .compositingGroup()
                .mask {
                    Circle()
                        .inset(by: 4)
                        .fill(Color.white)
                        .blur(radius: 2)
                }
            }
            .frame(width: 44, height: 44)
            .elsonGlassSurface(.bubble, in: Circle(), tint: glassTint)
        }
        .onAppear {
            handleStatusChange(status)
        }
        .onChange(of: status) { _, newStatus in
            handleStatusChange(newStatus)
        }
    }

    private func handleStatusChange(_ newStatus: Status) {
        // Reset animations
        isPulsing = false

        switch newStatus {
        case .listening:
            // Gentle pulse animation for recording
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                isPulsing = true
            }

        case .processing:
            // Gentle pulse for processing (no rotation)
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isPulsing = true
            }

        case .agentProcessing:
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                isPulsing = true
            }

        case .success:
            // Brief glow effect for success
            withAnimation(.easeOut(duration: 0.3)) {
                isPulsing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeIn(duration: 0.2)) {
                    isPulsing = false
                }
            }

        case .agentSuccess:
            withAnimation(.easeOut(duration: 0.2)) {
                isPulsing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.easeIn(duration: 0.2)) {
                    isPulsing = false
                }
            }

        case .error:
            // Brief pulse for error
            withAnimation(.easeOut(duration: 0.2)) {
                isPulsing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeIn(duration: 0.2)) {
                    isPulsing = false
                }
            }

        case .idle:
            // No animation for idle
            break
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
