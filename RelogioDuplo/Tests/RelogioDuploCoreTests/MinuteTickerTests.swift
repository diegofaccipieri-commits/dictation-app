import Foundation
import Testing
@testable import RelogioDuploCore

@Suite struct MinuteTickerTests {
    @Test(arguments: [
        ("2026-11-27T20:41:00Z", 0.0),     // exatamente na virada
        ("2026-11-27T20:41:00Z", 0.004),   // logo depois
        ("2026-11-27T20:41:00Z", 30.0),    // meio do minuto
        ("2026-11-27T20:41:00Z", 59.996),  // timer adiantado em 4 ms
    ])
    func firesAtNextWholeMinute(iso: String, offset: Double) {
        let base = utc(iso)
        let fire = MinuteTicker.nextFire(after: base.addingTimeInterval(offset))
        #expect(fire == base.addingTimeInterval(60))
    }

    @Test func alwaysStrictlyAfterInput() {
        let input = utc("2026-11-27T20:42:00Z")
        #expect(MinuteTicker.nextFire(after: input) > input)
    }

    @Test(arguments: [0.0, 0.004, 0.5, 0.996])
    func firesAtNextWholeSecond(offset: Double) {
        let base = utc("2026-11-27T20:41:07Z")
        #expect(MinuteTicker.nextFire(after: base.addingTimeInterval(offset), everySecond: true) == base.addingTimeInterval(1))
    }
}
