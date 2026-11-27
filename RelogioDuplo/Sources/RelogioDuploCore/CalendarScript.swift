import Foundation

/// AppleScript que mostra um dia no app Calendar. O macOS não tem esquema de URL para isso.
public enum CalendarScript {
    public static func source(for date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        // O dia vai para 1 antes de trocar o mês, para não estourar (ex.: 31 em mês de 30 dias).
        return """
        tell application "Calendar"
            activate
            set d to current date
            set day of d to 1
            set year of d to \(parts.year ?? 2000)
            set month of d to \(parts.month ?? 1)
            set day of d to \(parts.day ?? 1)
            set time of d to 43200
            view calendar at d
        end tell
        """
    }
}
