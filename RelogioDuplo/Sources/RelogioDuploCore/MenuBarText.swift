import Foundation

/// Texto da barra de menu: a data e a hora de cada relógio configurado.
public enum MenuBarText {
    /// `main` vai na fonte das horas; `small` (sigla, AM/PM) vai em fonte menor;
    /// `alert` é o domingo, na fonte das horas e em vermelho.
    public enum Piece: Equatable, Sendable {
        case main(String)
        case small(String)
        case alert(String)

        var text: String {
            switch self {
            case .main(let text), .small(let text), .alert(let text): return text
            }
        }
    }

    public static func pieces(now: Date, systemCalendar: Calendar, settings: Settings) -> [Piece] {
        var pieces: [Piece] = []
        var main = "\(systemCalendar.component(.day, from: now))"
        if settings.showsDate {
            let parts = systemCalendar.dateComponents([.weekday, .month], from: now)
            let weekday = symbol(systemCalendar.shortWeekdaySymbols, parts.weekday)
            let month = symbol(systemCalendar.shortMonthSymbols, parts.month)
            main = "\(month) \(main)"
            // O domingo é o dia 1 da semana em qualquer calendário do sistema.
            if settings.redSunday, parts.weekday == 1, !weekday.isEmpty {
                pieces.append(.alert(weekday))
                main = " \(main)"
            } else {
                main = "\(weekday) \(main)"
            }
        }
        for clock in settings.clocks {
            let (time, period) = time(
                now, zoneID: clock.zoneID, uses24Hour: settings.uses24Hour, showsSeconds: settings.showsSeconds)
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
    static func time(
        _ date: Date, zoneID: String, uses24Hour: Bool, showsSeconds: Bool = false
    ) -> (time: String, period: String) {
        guard let zone = TimeZone(identifier: zoneID) else { return ("--:--", "") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        guard let hour = parts.hour, let minute = parts.minute, let second = parts.second else { return ("--:--", "") }
        var minutes = twoDigits(minute)
        if showsSeconds { minutes += ":\(twoDigits(second))" }
        if uses24Hour { return ("\(hour):\(minutes)", "") }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return ("\(twelve):\(minutes)", hour < 12 ? "AM" : "PM")
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Nome curto sem ponto e com inicial maiúscula ("dom." vira "Dom"). Índice fora da lista: vazio.
    private static func symbol(_ symbols: [String], _ index: Int?) -> String {
        guard let index, symbols.indices.contains(index - 1) else { return "" }
        let name = symbols[index - 1].replacingOccurrences(of: ".", with: "")
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
