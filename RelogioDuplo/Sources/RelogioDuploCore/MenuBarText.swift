import Foundation

public enum MenuBarText {
    static let toronto = TimeZone(identifier: "America/Toronto")
    static let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")

    public static func make(now: Date, systemCalendar: Calendar) -> String {
        let day = systemCalendar.component(.day, from: now)
        return "\(day) - \(time(now, in: toronto)) TO - \(time(now, in: saoPaulo)) SP"
    }

    static func time(_ date: Date, in zone: TimeZone?) -> String {
        guard let zone else { return "--:--" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return "--:--" }
        return "\(hour):" + (minute < 10 ? "0\(minute)" : "\(minute)")
    }
}
