import Foundation
import Testing
@testable import RelogioDuploCore

func utc(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

func calendar(_ zone: String, identifier: Calendar.Identifier = .gregorian) -> Calendar {
    var c = Calendar(identifier: identifier)
    c.locale = Locale(identifier: "en_CA")
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

@Suite struct MenuBarTextTests {
    typealias Piece = MenuBarText.Piece

    let toronto = calendar("America/Toronto")
    static let to = Clock(zoneID: "America/Toronto", label: "TO")
    static let sp = Clock(zoneID: "America/Sao_Paulo", label: "SP")
    static let both = bare([to, sp])
    /// Barra só com dia e horas, como antes de existirem data por extenso e segundos.
    static func bare(_ clocks: [Clock], uses24Hour: Bool = true) -> Settings {
        Settings(clocks: clocks, uses24Hour: uses24Hour, showsDate: false, showsSeconds: false)
    }

    let evening = utc("2026-11-28T01:41:00Z") // 20:41 em Toronto, 22:41 em SP

    func plain(_ iso: String, _ settings: Settings = both, calendar: Calendar? = nil) -> String {
        MenuBarText.plain(now: utc(iso), systemCalendar: calendar ?? toronto, settings: settings)
    }

    @Test(arguments: [
        ("2026-11-28T01:41:00Z", "27 - 20:41 TO - 22:41 SP"), // inverno, 2h
        ("2026-07-15T12:05:00Z", "15 - 8:05 TO - 9:05 SP"),   // verão do Canadá, 1h
        ("2027-03-14T06:59:00Z", "14 - 1:59 TO - 3:59 SP"),   // antes de adiantar
        ("2027-03-14T07:00:00Z", "14 - 3:00 TO - 4:00 SP"),   // depois de adiantar
        ("2027-11-07T05:59:00Z", "7 - 1:59 TO - 2:59 SP"),    // antes de atrasar
        ("2027-11-07T06:00:00Z", "7 - 1:00 TO - 3:00 SP"),    // depois de atrasar
        ("2026-11-28T04:30:00Z", "27 - 23:30 TO - 1:30 SP"),  // SP já no dia seguinte
        ("2026-11-27T05:00:00Z", "27 - 0:00 TO - 2:00 SP"),   // meia-noite
    ])
    func twentyFourHour(iso: String, expected: String) {
        #expect(plain(iso) == expected)
    }

    @Test(arguments: [
        ("2026-11-27T05:05:00Z", "27 - 12:05 AM TO - 2:05 AM SP"),  // meia-noite
        ("2026-11-27T17:00:00Z", "27 - 12:00 PM TO - 2:00 PM SP"),  // meio-dia
        ("2026-11-28T01:41:00Z", "27 - 8:41 PM TO - 10:41 PM SP"),
        ("2026-11-27T16:59:00Z", "27 - 11:59 AM TO - 1:59 PM SP"),
    ])
    func twelveHour(iso: String, expected: String) {
        #expect(plain(iso, Self.bare([Self.to, Self.sp], uses24Hour: false)) == expected)
    }

    @Test func exactPiecesIn24Hour() {
        #expect(MenuBarText.pieces(now: evening, systemCalendar: toronto, settings: Self.both)
            == [.main("27 - 20:41"), .small(" TO"), .main(" - 22:41"), .small(" SP")])
    }

    @Test func exactPiecesIn12Hour() {
        let settings = Self.bare([Self.to, Self.sp], uses24Hour: false)
        #expect(MenuBarText.pieces(now: evening, systemCalendar: toronto, settings: settings)
            == [.main("27 - 8:41"), .small(" PM TO"), .main(" - 10:41"), .small(" PM SP")])
    }

    @Test func singleClock() {
        #expect(plain("2026-11-28T01:41:00Z", Self.bare([Self.sp])) == "27 - 22:41 SP")
    }

    @Test func fourClocks() {
        let settings = Self.bare([
            Self.to, Self.sp,
            Clock(zoneID: "Europe/Lisbon", label: "LIS"), Clock(zoneID: "Asia/Tokyo", label: "TYO"),
        ])
        #expect(plain("2026-11-28T01:41:00Z", settings) == "27 - 20:41 TO - 22:41 SP - 1:41 LIS - 10:41 TYO")
    }

    @Test func emptyLabelShowsOnlyTheTime() {
        let noLabel = Clock(zoneID: "America/Toronto", label: "")
        #expect(MenuBarText.pieces(now: evening, systemCalendar: toronto, settings: Self.bare([noLabel, Self.sp]))
            == [.main("27 - 20:41 - 22:41"), .small(" SP")])
        #expect(MenuBarText.pieces(now: evening, systemCalendar: toronto,
                                   settings: Self.bare([noLabel], uses24Hour: false))
            == [.main("27 - 8:41"), .small(" PM")])
    }

    @Test func invalidZoneShowsDashes() {
        let broken = Clock(zoneID: "Marte/Olympus_Mons", label: "MM")
        #expect(plain("2026-11-28T01:41:00Z", Self.bare([broken, Self.sp])) == "27 - --:-- MM - 22:41 SP")
        #expect(plain("2026-11-28T01:41:00Z", Self.bare([broken], uses24Hour: false)) == "27 - --:-- MM")
    }

    @Test func noClocksShowsOnlyTheDay() {
        #expect(plain("2026-11-28T01:41:00Z", Self.bare([])) == "27")
    }

    @Test func dayFollowsSystemZoneWhenTravelling() {
        #expect(plain("2026-11-28T01:41:00Z", calendar: calendar("Asia/Tokyo")) == "28 - 20:41 TO - 22:41 SP")
    }

    @Test func hoursIgnoreSystemCalendarKind() {
        #expect(plain("2026-11-28T01:41:00Z", calendar: calendar("America/Toronto", identifier: .buddhist))
            == "27 - 20:41 TO - 22:41 SP")
    }

    // MARK: Data por extenso e segundos

    @Test func defaultShowsWeekdayMonthAndSeconds() {
        // 27 de novembro de 2026 é sexta-feira.
        #expect(plain("2026-11-28T01:41:07Z", Settings(clocks: [Self.to, Self.sp]))
            == "Fri Nov 27 - 20:41:07 TO - 22:41:07 SP")
    }

    @Test func secondsAlwaysHaveTwoDigits() {
        let settings = Settings(clocks: [Self.to], showsDate: false)
        #expect(plain("2026-11-28T01:41:00Z", settings) == "27 - 20:41:00 TO")
        #expect(plain("2026-11-28T01:41:59Z", settings) == "27 - 20:41:59 TO")
        #expect(plain("2026-11-28T01:41:07Z", Settings(clocks: [Self.to], uses24Hour: false, showsDate: false))
            == "27 - 8:41:07 PM TO")
    }

    @Test func dateWithoutSeconds() {
        #expect(plain("2026-11-28T01:41:07Z", Settings(clocks: [Self.to], showsSeconds: false)) == "Fri Nov 27 - 20:41 TO")
    }

    @Test func sundayIsItsOwnRedPiece() {
        // 29 de novembro de 2026 é domingo.
        let sunday = utc("2026-11-29T17:00:00Z")
        #expect(MenuBarText.pieces(now: sunday, systemCalendar: toronto, settings: Settings(clocks: [Self.to], showsSeconds: false))
            == [.alert("Sun"), .main(" Nov 29 - 12:00"), .small(" TO")])
    }

    @Test func sundayIsPlainWhenRedSundayIsOff() {
        let sunday = utc("2026-11-29T17:00:00Z")
        let settings = Settings(clocks: [Self.to], redSunday: false, showsSeconds: false)
        #expect(MenuBarText.pieces(now: sunday, systemCalendar: toronto, settings: settings)
            == [.main("Sun Nov 29 - 12:00"), .small(" TO")])
    }

    @Test func otherDaysHaveNoRedPiece() {
        let saturday = utc("2026-11-28T17:00:00Z")
        #expect(MenuBarText.pieces(now: saturday, systemCalendar: toronto, settings: Settings(clocks: [Self.to], showsSeconds: false))
            == [.main("Sat Nov 28 - 12:00"), .small(" TO")])
    }

    @Test func weekdayFollowsSystemZoneAndLanguage() {
        var brazil = calendar("America/Sao_Paulo")
        brazil.locale = Locale(identifier: "pt_BR")
        // 23:30 de sábado em Toronto já é 1:30 de domingo em São Paulo.
        #expect(plain("2026-11-29T04:30:00Z", Settings(clocks: [Self.sp], showsSeconds: false), calendar: brazil)
            == "Dom Nov 29 - 1:30 SP")
    }
}
