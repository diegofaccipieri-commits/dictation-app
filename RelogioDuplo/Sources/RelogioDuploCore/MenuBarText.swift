import Foundation

/// Texto da barra de menu: dia do mês e a hora de cada relógio configurado.
public enum MenuBarText {
    /// `main` vai na fonte das horas; `small` (sigla, AM/PM) vai em fonte menor.
    public enum Piece: Equatable, Sendable {
        case main(String)
        case small(String)

        var text: String {
            switch self {
            case .main(let text), .small(let text): return text
            }
        }
    }

    public static func pieces(now: Date, systemCalendar: Calendar, settings: Settings) -> [Piece] {
        var pieces: [Piece] = []
        var main = "\(systemCalendar.component(.day, from: now))"
        for clock in settings.clocks {
            let (time, period) = time(now, zoneID: clock.zoneID, uses24Hour: settings.uses24Hour)
            main += " - \(time)"
            let small = [period, clock.label].filter { !$0.isEmpty }.joined(separator: " ")
            if !small.isEmpty {
                pieces.append(.main(main))
                pieces.append(.small(" \(small)"))
                main = ""
            }
        }
        if !main.isEmpty { pieces.append(.main(main)) }
        return pieces
    }

    public static func plain(now: Date, systemCalendar: Calendar, settings: Settings) -> String {
        pieces(now: now, systemCalendar: systemCalendar, settings: settings).map(\.text).joined()
    }

    /// Devolve a hora e, em 12h, "AM" ou "PM". Fuso inválido: "--:--" sem período.
    static func time(_ date: Date, zoneID: String, uses24Hour: Bool) -> (time: String, period: String) {
        guard let zone = TimeZone(identifier: zoneID) else { return ("--:--", "") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return ("--:--", "") }
        let minutes = minute < 10 ? "0\(minute)" : "\(minute)"
        if uses24Hour { return ("\(hour):\(minutes)", "") }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return ("\(twelve):\(minutes)", hour < 12 ? "AM" : "PM")
    }
}
