import Foundation
import Testing
@testable import RelogioDuploCore

@Suite struct CalendarScriptTests {
    @Test func buildsLocaleIndependentScriptForTheDay() {
        let cal = calendar("America/Toronto")
        let date = cal.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        #expect(CalendarScript.source(for: date, calendar: cal) == """
        tell application "Calendar"
            activate
            set d to current date
            set day of d to 1
            set year of d to 2026
            set month of d to 12
            set day of d to 31
            set time of d to 43200
            view calendar at d
        end tell
        """)
    }

    @Test func usesGregorianFieldsEvenWithOtherSystemCalendar() {
        let buddhist = calendar("America/Toronto", identifier: .buddhist)
        let date = calendar("America/Toronto").date(from: DateComponents(year: 2026, month: 2, day: 5))!
        let source = CalendarScript.source(for: date, calendar: buddhist)
        #expect(source.contains("set year of d to 2026"))
        #expect(source.contains("set month of d to 2"))
        #expect(source.contains("set day of d to 5"))
    }
}
