import Foundation

public enum MinuteTicker {
    public static func nextFire(after date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60 + 60)
    }
}
