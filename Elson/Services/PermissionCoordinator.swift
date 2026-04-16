import AppKit
import ApplicationServices
import AVFoundation
import Foundation

enum PermissionCoordinatorError: LocalizedError {
    case microphoneDenied
    case screenRecordingDenied
    case accessibilityDenied
    case fullDiskAccessDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone permission is required. Elson.ai opened System Settings > Privacy & Security > Microphone."
        case .screenRecordingDenied:
            return "Screen Recording permission is required. Use the macOS permission dialog to open System Settings, then fully quit and reopen Elson.ai after enabling it."
        case .accessibilityDenied:
            return "Accessibility permission is required. Use the macOS permission dialog and enable Elson there."
        case .fullDiskAccessDenied:
            return "Full Disk Access is required for external skill discovery. Open System Settings > Privacy & Security > Full Disk Access and enable Elson.ai."
        }
    }
}

@MainActor
enum PermissionCoordinator {
    static func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func hasMicrophonePermission() -> Bool {
        microphoneStatus() == .authorized
    }

    static func hasScreenRecordingPermission() -> Bool {
        ScreenSnapshotService.shared.hasPermission()
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func hasFullDiskAccessPermission() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Safari", isDirectory: true),
            home.appendingPathComponent("Library/Messages", isDirectory: true),
        ]

        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            do {
                _ = try fm.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil)
                return true
            } catch {
                continue
            }
        }

        return false
    }

    static func ensureAccessibilityPermission(
        requestIfNeeded: Bool = true,
        openSettingsOnFailure: Bool = false
    ) throws {
        if hasAccessibilityPermission() {
            return
        }

        if requestIfNeeded {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if AXIsProcessTrustedWithOptions(options), hasAccessibilityPermission() {
                return
            }
        }

        if openSettingsOnFailure {
            openAccessibilitySettings()
        }
        throw PermissionCoordinatorError.accessibilityDenied
    }

    static func ensureMicrophonePermission(
        requestIfNeeded: Bool = true,
        openSettingsOnFailure: Bool = true
    ) async throws {
        switch microphoneStatus() {
        case .authorized:
            return
        case .notDetermined:
            guard requestIfNeeded else {
                if openSettingsOnFailure {
                    openMicrophoneSettings()
                }
                throw PermissionCoordinatorError.microphoneDenied
            }

            let granted = await requestMicrophonePermission()
            guard granted else {
                if openSettingsOnFailure {
                    openMicrophoneSettings()
                }
                throw PermissionCoordinatorError.microphoneDenied
            }
        case .denied, .restricted:
            if openSettingsOnFailure {
                openMicrophoneSettings()
            }
            throw PermissionCoordinatorError.microphoneDenied
        @unknown default:
            if openSettingsOnFailure {
                openMicrophoneSettings()
            }
            throw PermissionCoordinatorError.microphoneDenied
        }
    }

    static func ensureScreenRecordingPermission(
        requestIfNeeded: Bool = true,
        openSettingsOnFailure: Bool = false
    ) throws {
        if hasScreenRecordingPermission() {
            return
        }

        if requestIfNeeded, ScreenSnapshotService.shared.requestAccessIfNeeded(), hasScreenRecordingPermission() {
            return
        }

        if openSettingsOnFailure {
            openScreenRecordingSettings()
        }
        throw PermissionCoordinatorError.screenRecordingDenied
    }

    static func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
