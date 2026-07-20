import XCTest
@testable import ReunioesLogic

final class MeetingSilenceWatchdogTests: XCTestCase {

    /// Feeds `seconds` of observations at 10 Hz starting at `from`, returning all non-.none actions.
    private func feed(_ w: inout MeetingSilenceWatchdog,
                      from: Double, seconds: Double, rms: Float) -> [MeetingSilenceWatchdog.Action] {
        var actions: [MeetingSilenceWatchdog.Action] = []
        var t = from
        let end = from + seconds
        while t <= end {
            let a = w.observe(pts: t, rms: rms)
            if a != .none { actions.append(a) }
            t += 0.1
        }
        return actions
    }

    // The exact field failure: digital silence from the VERY FIRST buffer must trigger a restart
    // (the old health-check required prior audible audio and never fired).
    func testSilentFromStartTriggersRestart() {
        var w = MeetingSilenceWatchdog()
        let actions = feed(&w, from: 0, seconds: 11, rms: 0)
        XCTAssertEqual(actions, [.restartCapture])
    }

    // If silence persists after the restart, the user must be alerted exactly once.
    func testPersistentSilenceAfterRestartAlertsOnce() {
        var w = MeetingSilenceWatchdog()
        var actions = feed(&w, from: 0, seconds: 11, rms: 0)      // → restart at ~10s
        actions += feed(&w, from: 11.1, seconds: 30, rms: 0)      // still silent well past alertAfter
        XCTAssertEqual(actions.first, .restartCapture)
        let alerts = actions.filter { if case .showAlert = $0 { return true }; return false }
        XCTAssertEqual(alerts.count, 1, "alert must fire exactly once per silent run")
        if case .showAlert(let silentFor)? = alerts.first {
            XCTAssertGreaterThanOrEqual(silentFor, 20, "silentFor reports the whole silent run")
        }
    }

    // Audible audio arriving while the alert is up must clear it and reset the run.
    func testAudibleAudioClearsAlertAndResets() {
        var w = MeetingSilenceWatchdog()
        _ = feed(&w, from: 0, seconds: 25, rms: 0)                // restart + alert
        XCTAssertEqual(w.observe(pts: 25.2, rms: 0.05), .clearAlert)
        // A new silent run later must go through the whole cycle again (restart first).
        let again = feed(&w, from: 26, seconds: 11, rms: 0)
        XCTAssertEqual(again, [.restartCapture])
    }

    // Normal audio never produces actions.
    func testHealthyAudioProducesNothing() {
        var w = MeetingSilenceWatchdog()
        let actions = feed(&w, from: 0, seconds: 60, rms: 0.03)
        XCTAssertEqual(actions, [])
    }

    // Quiet-but-real audio (above the zero threshold) is NOT digital silence.
    func testQuietSpeechIsNotSilence() {
        var w = MeetingSilenceWatchdog()
        let actions = feed(&w, from: 0, seconds: 60, rms: 0.0005)
        XCTAssertEqual(actions, [])
    }

    // Short zero gaps (below restartAfter) are legitimate — e.g. nobody talking for a few seconds.
    func testShortSilenceGapsAreTolerated() {
        var w = MeetingSilenceWatchdog()
        var actions = feed(&w, from: 0, seconds: 8, rms: 0)       // 8s zero — below threshold
        actions += feed(&w, from: 8.1, seconds: 5, rms: 0.02)     // audio resumes
        actions += feed(&w, from: 13.2, seconds: 8, rms: 0)       // another short gap
        XCTAssertEqual(actions, [])
    }

    // reset() starts a completely fresh session (used when a new recording starts).
    func testResetStartsFreshSession() {
        var w = MeetingSilenceWatchdog()
        _ = feed(&w, from: 0, seconds: 25, rms: 0)                // restart + alert consumed
        w.reset()
        let actions = feed(&w, from: 100, seconds: 11, rms: 0)
        XCTAssertEqual(actions, [.restartCapture], "after reset the cycle begins anew")
    }
}
