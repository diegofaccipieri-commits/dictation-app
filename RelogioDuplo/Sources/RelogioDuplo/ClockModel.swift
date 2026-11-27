import AppKit
import Observation
import RelogioDuploCore

@MainActor
@Observable
final class ClockModel {
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?

    var text: String {
        MenuBarText.make(now: now, systemCalendar: .autoupdatingCurrent)
    }

    init() {
        schedule()
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        let center = NotificationCenter.default
        for name: Notification.Name in [.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            center.addObserver(forName: name, object: nil, queue: .main, using: refresh)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: refresh)
    }

    func refresh() {
        now = Date()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let next = Timer(fire: MinuteTicker.nextFire(after: Date()), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}
