import Foundation

public enum MinuteTicker {
    /// Próxima virada de minuto ou, com `everySecond`, de segundo.
    public static func nextFire(after date: Date, everySecond: Bool = false) -> Date {
        let step: Double = everySecond ? 1 : 60
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / step).rounded(.down) * step + step)
    }
}
