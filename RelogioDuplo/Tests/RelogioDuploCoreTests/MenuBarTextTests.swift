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
    let toronto = calendar("America/Toronto")

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
    func formats(iso: String, expected: String) {
        #expect(MenuBarText.make(now: utc(iso), systemCalendar: toronto) == expected)
    }

    @Test func dayFollowsSystemZoneWhenTravelling() {
        let tokyo = calendar("Asia/Tokyo")
        #expect(MenuBarText.make(now: utc("2026-11-28T01:41:00Z"), systemCalendar: tokyo)
            == "28 - 20:41 TO - 22:41 SP")
    }

    @Test func hoursIgnoreSystemCalendarKind() {
        let buddhist = calendar("America/Toronto", identifier: .buddhist)
        #expect(MenuBarText.make(now: utc("2026-11-28T01:41:00Z"), systemCalendar: buddhist)
            == "27 - 20:41 TO - 22:41 SP")
    }

    @Test func missingZoneShowsDashes() {
        #expect(MenuBarText.time(utc("2026-11-28T01:41:00Z"), in: nil) == "--:--")
    }
}
