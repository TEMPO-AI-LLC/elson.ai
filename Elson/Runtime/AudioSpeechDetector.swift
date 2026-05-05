import AVFoundation
import Foundation

struct AudioSpeechAnalysis: Equatable, Sendable {
    let duration: TimeInterval
    let rms: Double
    let peak: Double
    let activeWindowRatio: Double
    let containsSpeech: Bool
    let reason: String?
}

enum AudioSpeechDetector {
    private static let minimumAnalyzableDuration: TimeInterval = 0.25
    private static let silenceRMSFloor = 0.006
    private static let silencePeakFloor = 0.035
    private static let activeWindowRMSFloor = 0.012
    private static let minimumActiveWindowRatio = 0.03
    private static let analysisFrameCapacity: AVAudioFrameCount = 4096
    private static let windowDuration: TimeInterval = 0.02

    static func analyze(audioURL: URL) throws -> AudioSpeechAnalysis {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let duration = sampleRate > 0 ? TimeInterval(file.length) / sampleRate : 0

        guard duration >= minimumAnalyzableDuration else {
            return AudioSpeechAnalysis(
                duration: duration,
                rms: 0,
                peak: 0,
                activeWindowRatio: 0,
                containsSpeech: true,
                reason: "too_short_for_energy_analysis"
            )
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: analysisFrameCapacity) else {
            return AudioSpeechAnalysis(
                duration: duration,
                rms: 0,
                peak: 0,
                activeWindowRatio: 0,
                containsSpeech: true,
                reason: "pcm_buffer_unavailable"
            )
        }

        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else {
            return AudioSpeechAnalysis(
                duration: duration,
                rms: 0,
                peak: 0,
                activeWindowRatio: 0,
                containsSpeech: false,
                reason: "no_audio_channels"
            )
        }

        let targetWindowFrames = max(1, Int(sampleRate * windowDuration))
        var totalSquare: Double = 0
        var totalFrames = 0
        var peak: Double = 0
        var windowSquare: Double = 0
        var windowFrames = 0
        var totalWindows = 0
        var activeWindows = 0

        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                return AudioSpeechAnalysis(
                    duration: duration,
                    rms: 0,
                    peak: 0,
                    activeWindowRatio: 0,
                    containsSpeech: true,
                    reason: "non_float_pcm_layout"
                )
            }

            for frameIndex in 0..<frameLength {
                var frameSquare: Double = 0
                var framePeak: Double = 0

                for channelIndex in 0..<channelCount {
                    let sample = Double(channels[channelIndex][frameIndex])
                    let absolute = abs(sample)
                    framePeak = max(framePeak, absolute)
                    frameSquare += sample * sample
                }

                frameSquare /= Double(channelCount)
                totalSquare += frameSquare
                peak = max(peak, framePeak)
                totalFrames += 1

                windowSquare += frameSquare
                windowFrames += 1
                if windowFrames >= targetWindowFrames {
                    if sqrt(windowSquare / Double(windowFrames)) >= activeWindowRMSFloor {
                        activeWindows += 1
                    }
                    totalWindows += 1
                    windowSquare = 0
                    windowFrames = 0
                }
            }
        }

        if windowFrames > 0 {
            if sqrt(windowSquare / Double(windowFrames)) >= activeWindowRMSFloor {
                activeWindows += 1
            }
            totalWindows += 1
        }

        guard totalFrames > 0, totalWindows > 0 else {
            return AudioSpeechAnalysis(
                duration: duration,
                rms: 0,
                peak: 0,
                activeWindowRatio: 0,
                containsSpeech: false,
                reason: "empty_audio"
            )
        }

        let rms = sqrt(totalSquare / Double(totalFrames))
        let activeWindowRatio = Double(activeWindows) / Double(totalWindows)
        let looksSilent = rms < silenceRMSFloor
            && peak < silencePeakFloor
            && activeWindowRatio < minimumActiveWindowRatio

        return AudioSpeechAnalysis(
            duration: duration,
            rms: rms,
            peak: peak,
            activeWindowRatio: activeWindowRatio,
            containsSpeech: !looksSilent,
            reason: looksSilent ? "low_energy_audio" : nil
        )
    }
}
