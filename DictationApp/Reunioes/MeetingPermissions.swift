import Foundation
import AVFoundation
import CoreGraphics
import AppKit

struct MeetingPermissions: Equatable {
    var microphone = false
    var screenRecording = false
    /// Only the microphone gates recording. System audio uses a Core Audio process tap whose
    /// "Gravação de Áudio do Sistema" permission is prompted by macOS automatically on the first
    /// recording; Screen Recording is now just the OPTIONAL fallback (ScreenCaptureKit) permission.
    var allGranted: Bool { microphone }
}

enum MeetingPermissionsManager {
    static func snapshot() -> MeetingPermissions {
        var p = MeetingPermissions()
        p.microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        p.screenRecording = CGPreflightScreenCaptureAccess()
        return p
    }

    static func requestMicrophone() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// The system modal for Screen Recording only ever appears ONCE per app; afterwards
    /// `CGRequestScreenCaptureAccess` is a silent no-op. So we also open System Settings straight
    /// at the Screen Recording pane, where the user can toggle the app manually.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        let shown = CGRequestScreenCaptureAccess()
        if !CGPreflightScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return shown
    }
}
