import Foundation
import Testing
@testable import RelogioDuploCore

func utc(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

func calendar(_ zone: String, identifier: Calendar.Identifier = .gregorian) -> Calendar {
    var c = Calendar(identifier: identifier)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

@Suite struct MenuBarTextTests {
    typealias Piece = MenuBarText.Piece

    let toronto = calendar("America/Toronto")
    static let to = Clock(zoneID: "America/Toronto", label: "TO")
    static let sp = Clock(zoneID: "America/Sao_Paulo", label: "SP")
    static let both = Settings(clocks: [to, sp])
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
        #expect(plain(iso, Settings(clocks: [Self.to, Self.sp], uses24Hour: false)) == expected)
    }

    @Test func exactPiecesIn24Hour() {
        #expect(MenuBarText.pieces(now: evening, systemCalendar: toronto, settings: Self.both)
            == [.main("27 - 20:41"), .small(" TO"), .main(" - 22:41"), .small(" SP")])
    }

    @Test func exactPiecesIn12Hour() {
        let settings = Settings(clocks: [Self.to, Self.sp], uses24Hour: false)
        #expect(MenuBarText.pieces(now: evening, systemCalendar: toronto, settings: settings)
            == [.main("27 - 8:41"), .small(" PM TO"), .main(" - 10:41"), .small(" PM SP")])
    }

    @Test func singleClock() {
        #expect(plain("2026-11-28T01:41:00Z", Settings(clocks: [Self.sp])) == "27 - 22:41 SP")
    }

    @Test func fourClocks() {
        let settings = Settings(clocks: [
            Self.to, Self.sp,
            Clock(zoneID: "Europe/Lisbon", label: "LIS"), Clock(zoneID: "Asia/Tokyo", label: "TYO"),
        ])
        #expect(plain("2026-11-28T01:41:00Z", settings) == "27 - 20:41 TO - 22:41 SP - 1:41 LIS - 10:41 TYO")
    }

    @Test func emptyLabelShowsOnlyTheTime() {
        let noLabel = Clock(zoneID: "America/Toronto", label: "")
        #expect(MenuBarText.pieces(now: evening, systemCalendar: toronto, settings: Settings(clocks: [noLabel, Self.sp]))
            == [.main("27 - 20:41 - 22:41"), .small(" SP")])
        #expect(MenuBarText.pieces(now: evening, systemCalendar: toronto,
                                   settings: Settings(clocks: [noLabel], uses24Hour: false))
            == [.main("27 - 8:41"), .small(" PM")])
    }

    @Test func invalidZoneShowsDashes() {
        let broken = Clock(zoneID: "Marte/Olympus_Mons", label: "MM")
        #expect(plain("2026-11-28T01:41:00Z", Settings(clocks: [broken, Self.sp])) == "27 - --:-- MM - 22:41 SP")
        #expect(plain("2026-11-28T01:41:00Z", Settings(clocks: [broken], uses24Hour: false)) == "27 - --:-- MM")
    }

    @Test func noClocksShowsOnlyTheDay() {
        #expect(plain("2026-11-28T01:41:00Z", Settings(clocks: [])) == "27")
    }

    @Test func dayFollowsSystemZoneWhenTravelling() {
        #expect(plain("2026-11-28T01:41:00Z", calendar: calendar("Asia/Tokyo")) == "28 - 20:41 TO - 22:41 SP")
    }

    @Test func hoursIgnoreSystemCalendarKind() {
        #expect(plain("2026-11-28T01:41:00Z", calendar: calendar("America/Toronto", identifier: .buddhist))
            == "27 - 20:41 TO - 22:41 SP")
    }
}
