import Foundation

/// Decides when the system-audio capture should be restarted and when the user must be alerted,
/// based on the stream of (timestamp, RMS) observations from system-audio buffers.
///
/// Replaces `MeetingSystemAudioHealth`, whose recovery never fired when a meeting was digitally
/// silent from the very first buffer (it required prior audible audio) and reacted only after
/// 60s+30s. This watchdog counts silence from the first buffer:
///
///   zero-RMS run ≥ `restartAfter`               → `.restartCapture` (silent, transparent)
///   still zero  ≥ `alertAfter` after the restart → `.showAlert` (panel jumps to front)
///   audible audio at any point                   → run resets; `.clearAlert` if alert was shown
///
/// Pure state machine driven by buffer timestamps (no wall clock), so it is fully testable.
struct MeetingSilenceWatchdog {
    enum Action: Equatable {
        case none
        case restartCapture
        case showAlert(silentFor: Double)
        case clearAlert
    }

    /// RMS at or below this is considered digital silence (field failures produce exact zeros).
    let zeroThreshold: Float
    /// Seconds of continuous digital silence before a transparent capture restart.
    let restartAfter: Double
    /// Seconds of continuous digital silence after the restart before alerting the user.
    let alertAfter: Double

    init(zeroThreshold: Float = 0.00001, restartAfter: Double = 10, alertAfter: Double = 10) {
        self.zeroThreshold = zeroThreshold
        self.restartAfter = restartAfter
        self.alertAfter = alertAfter
    }

    private var silenceStart: Double?
    private var restartedThisRun = false
    private var restartPTS: Double?
    private var alertShown = false

    /// Feed one observation. Returns the action the capture layer must perform.
    mutating func observe(pts: Double, rms: Float) -> Action {
        guard rms <= zeroThreshold else {
            // Audible audio ends the silent run.
            let hadAlert = alertShown
            silenceStart = nil
            restartedThisRun = false
            restartPTS = nil
            alertShown = false
            return hadAlert ? .clearAlert : .none
        }

        let start = silenceStart ?? pts
        if silenceStart == nil { silenceStart = pts }
        let silentFor = pts - start

        if !restartedThisRun {
            guard silentFor >= restartAfter else { return .none }
            restartedThisRun = true
            restartPTS = pts
            return .restartCapture
        }

        if !alertShown, let restartPTS, pts - restartPTS >= alertAfter {
            alertShown = true
            return .showAlert(silentFor: silentFor)
        }
        return .none
    }

    /// Reset all state for a new recording session.
    mutating func reset() {
        silenceStart = nil
        restartedThisRun = false
        restartPTS = nil
        alertShown = false
    }
}
