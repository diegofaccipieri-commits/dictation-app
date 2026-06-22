import Foundation
import AVFoundation
import CoreGraphics

struct MeetingPermissions: Equatable {
    var microphone = false
    var screenRecording = false
    var allGranted: Bool { microphone && screenRecording }
}

/// Microphone is already granted for dictation; system-audio capture (ScreenCaptureKit) is gated
/// by the Screen Recording permission, which we request the first time the user records a meeting.
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

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
