import Foundation

public struct MonthGrid: Equatable, Sendable {
    public struct Day: Equatable, Sendable, Identifiable {
        public let date: Date
        public let number: Int
        public let inMonth: Bool
        public let isWeekend: Bool
        public let isSunday: Bool
        public let isToday: Bool
        public var id: Date { date }
    }

    public struct Week: Equatable, Sendable, Identifiable {
        public let number: Int
        public let days: [Day]
        public var id: Date { days[0].date }
    }

    public let weeks: [Week]
    public let weekdaySymbols: [String]
    /// Índice da coluna do domingo (0 a 6).
    public let sundayColumn: Int

    public static func make(month: Date, calendar: Calendar, today: Date) -> MonthGrid {
        let monthStart = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let lead = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7

        let weeks = (0..<6).map { row in
            let days = (0..<7).map { column in
                let offset = row * 7 + column - lead
                let raw = calendar.date(byAdding: .day, value: offset, to: monthStart) ?? monthStart
                let date = calendar.startOfDay(for: raw)
                return Day(
                    date: date,
                    number: calendar.component(.day, from: date),
                    inMonth: calendar.isDate(date, equalTo: monthStart, toGranularity: .month),
                    isWeekend: calendar.isDateInWeekend(date),
                    isSunday: calendar.component(.weekday, from: date) == 1,
                    isToday: calendar.isDate(date, inSameDayAs: today)
                )
            }
            return Week(number: calendar.component(.weekOfYear, from: days[0].date), days: days)
        }

        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return MonthGrid(
            weeks: weeks,
            weekdaySymbols: Array(symbols[first...] + symbols[..<first]),
            sundayColumn: (7 - first) % 7)
    }
}
