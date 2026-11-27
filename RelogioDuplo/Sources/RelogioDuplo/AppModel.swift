import AppKit
import Observation
import RelogioDuploCore

@MainActor
@Observable
final class AppModel {
    private(set) var now = Date()
    private(set) var settings: Settings
    let cities = CityCatalog.all(locale: .current)

    /// Chamado a cada virada de minuto (ou de segundo) e a cada mudança de ajustes.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = Settings.decode(defaults.string(forKey: "settings"), systemZone: .current)
        schedule()
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // O modelo vive enquanto o app vive, então os observadores nunca são removidos.
        let center = NotificationCenter.default
        for name: Notification.Name in [.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            center.addObserver(forName: name, object: nil, queue: .main, using: refresh)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: refresh)
    }

    var pieces: [MenuBarText.Piece] {
        MenuBarText.pieces(now: now, systemCalendar: .autoupdatingCurrent, settings: settings)
    }

    var plainText: String {
        MenuBarText.plain(now: now, systemCalendar: .autoupdatingCurrent, settings: settings)
    }

    func cityName(for clock: Clock) -> String {
        cities.first { $0.zoneID == clock.zoneID }?.name ?? CityCatalog.name(for: clock.zoneID, locale: .current)
    }

    // MARK: Ajustes

    func update(_ change: (inout Settings) -> Void) {
        var copy = settings
        change(&copy)
        copy = copy.normalized(systemZone: .current)
        guard copy != settings else { return }
        settings = copy
        defaults.set(copy.encoded(), forKey: "settings")
        // Reagenda: ligar ou desligar os segundos muda o passo do relógio.
        refresh()
    }

    func addClock() {
        update { $0.clocks.append(Settings.defaultClock(systemZone: .current)) }
    }

    func removeClock(_ id: UUID) {
        update { settings in
            guard settings.clocks.count > 1 else { return }
            settings.clocks.removeAll { $0.id == id }
        }
    }

    func moveClock(_ id: UUID, by offset: Int) {
        update { settings in
            guard let index = settings.clocks.firstIndex(where: { $0.id == id }) else { return }
            let target = index + offset
            guard settings.clocks.indices.contains(target) else { return }
            settings.clocks.swapAt(index, target)
        }
    }

    func setCity(_ city: City, for id: UUID) {
        update { settings in
            guard let index = settings.clocks.firstIndex(where: { $0.id == id }) else { return }
            settings.clocks[index].zoneID = city.zoneID
            settings.clocks[index].label = CityCatalog.suggestedLabel(for: city.name)
        }
    }

    func setLabel(_ raw: String, for id: UUID) {
        update { settings in
            guard let index = settings.clocks.firstIndex(where: { $0.id == id }) else { return }
            settings.clocks[index].label = raw
        }
    }

    // MARK: Relógio

    func refresh() {
        now = Date()
        schedule()
        onChange?()
    }

    private func schedule() {
        timer?.invalidate()
        let next = Timer(fire: MinuteTicker.nextFire(after: Date(), everySecond: settings.showsSeconds), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}
