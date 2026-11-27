import Foundation
import Testing
@testable import RelogioDuploCore

@Suite struct MonthGridTests {
    // en_CA: semana começa no domingo, primeira semana tem pelo menos 1 dia.
    static func system(firstWeekday: Int = 1) -> Calendar {
        var c = calendar("America/Toronto")
        c.locale = Locale(identifier: "en_CA")
        c.firstWeekday = firstWeekday
        c.minimumDaysInFirstWeek = 1
        return c
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        system().date(from: DateComponents(year: y, month: m, day: d, hour: 15))!
    }

    func grid(_ y: Int, _ m: Int, today: Date = day(2000, 1, 1), firstWeekday: Int = 1) -> MonthGrid {
        MonthGrid.make(month: Self.day(y, m, 10), calendar: Self.system(firstWeekday: firstWeekday), today: today)
    }

    @Test(arguments: [(2026, 11), (2026, 8), (2028, 2), (2027, 3), (2026, 12)])
    func alwaysSixWeeksOfSevenConsecutiveDays(y: Int, m: Int) {
        let g = grid(y, m)
        #expect(g.weeks.count == 6)
        #expect(g.weeks.map(\.days.count) == Array(repeating: 7, count: 6))
        let days = g.weeks.flatMap(\.days)
        let cal = Self.system()
        for (a, b) in zip(days, days.dropFirst()) {
            #expect(cal.dateComponents([.day], from: a.date, to: b.date).day == 1)
            #expect(a.date == cal.startOfDay(for: a.date))
        }
    }

    @Test func monthStartingOnSunday() { // novembro de 2026
        let g = grid(2026, 11)
        #expect(g.weeks[0].days.map(\.number) == [1, 2, 3, 4, 5, 6, 7])
        #expect(g.weeks[0].days.map(\.inMonth) == Array(repeating: true, count: 7))
        #expect(g.weeks[4].days.map(\.number) == [29, 30, 1, 2, 3, 4, 5])
        #expect(g.weeks[4].days.map(\.inMonth) == [true, true, false, false, false, false, false])
    }

    @Test func monthStartingOnSaturday() { // agosto de 2026
        let g = grid(2026, 8)
        #expect(g.weeks[0].days.map(\.number) == [26, 27, 28, 29, 30, 31, 1])
        #expect(g.weeks[0].days.map(\.inMonth) == [false, false, false, false, false, false, true])
        #expect(g.weeks[5].days.map(\.number) == [30, 31, 1, 2, 3, 4, 5])
    }

    @Test func leapFebruary() { // fevereiro de 2028
        let inMonth = grid(2028, 2).weeks.flatMap(\.days).filter(\.inMonth).map(\.number)
        #expect(inMonth == Array(1...29))
    }

    @Test func weekNumbersAcrossYearEnd() { // dezembro de 2026
        #expect(grid(2026, 12).weeks.map(\.number) == [49, 50, 51, 52, 1, 2])
    }

    @Test func weekendFlags() {
        #expect(grid(2026, 11).weeks[1].days.map(\.isWeekend)
            == [true, false, false, false, false, false, true])
    }

    @Test func todayIsFlaggedOnce() {
        let days = grid(2026, 11, today: Self.day(2026, 11, 27)).weeks.flatMap(\.days)
        #expect(days.filter(\.isToday).map(\.number) == [27])
    }

    @Test func todayOutsideGridFlagsNothing() {
        #expect(grid(2026, 11, today: Self.day(2025, 1, 1)).weeks.flatMap(\.days).filter(\.isToday).isEmpty)
    }

    @Test func sundayFirstSymbols() {
        #expect(grid(2026, 11).weekdaySymbols == ["S", "M", "T", "W", "T", "F", "S"])
    }

    @Test func mondayFirstSystem() {
        let g = grid(2026, 11, firstWeekday: 2)
        #expect(g.weekdaySymbols == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(g.weeks[0].days.map(\.number) == [26, 27, 28, 29, 30, 31, 1])
        #expect(g.weeks[0].days.map(\.isWeekend) == [false, false, false, false, false, true, true])
    }

    @Test func sundayIsFlaggedInFirstColumnWhenWeekStartsOnSunday() {
        let g = grid(2026, 11)
        #expect(g.sundayColumn == 0)
        #expect(g.weeks[1].days.map(\.isSunday) == [true, false, false, false, false, false, false])
    }

    @Test func sundayIsFlaggedInLastColumnWhenWeekStartsOnMonday() {
        let g = grid(2026, 11, firstWeekday: 2)
        #expect(g.sundayColumn == 6)
        #expect(g.weeks[1].days.map(\.isSunday) == [false, false, false, false, false, false, true])
    }
}
