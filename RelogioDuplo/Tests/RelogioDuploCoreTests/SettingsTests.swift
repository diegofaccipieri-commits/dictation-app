import Foundation
import Testing
@testable import RelogioDuploCore

@Suite struct SettingsTests {
    let toronto = TimeZone(identifier: "America/Toronto")!

    @Test func defaultsHaveOneClockForSystemZone() {
        let s = Settings.defaults(systemZone: toronto)
        #expect(s.clocks.map(\.zoneID) == ["America/Toronto"])
        #expect(s.clocks.map(\.label) == ["TO"])
        #expect(s.uses24Hour)
        #expect(s.redSunday)
    }

    @Test func roundTripsThroughJSON() {
        var s = Settings.defaults(systemZone: toronto)
        s.clocks.append(Clock(zoneID: "America/Sao_Paulo", label: "SP"))
        s.uses24Hour = false
        s.redSunday = false
        #expect(Settings.decode(s.encoded(), systemZone: toronto) == s)
    }

    @Test(arguments: [nil, "", "isto não é json", "[1,2,3]", "{\"clocks\": 7}"] as [String?])
    func unreadableFallsBackToDefaults(json: String?) {
        let s = Settings.decode(json, systemZone: toronto)
        #expect(s.clocks.map(\.zoneID) == ["America/Toronto"])
        #expect(s.uses24Hour)
        #expect(s.redSunday)
    }

    @Test func missingFieldsUseFieldDefaults() {
        let json = #"{"clocks":[{"zoneID":"America/Sao_Paulo","label":"SP"}]}"#
        let s = Settings.decode(json, systemZone: toronto)
        #expect(s.clocks.map(\.zoneID) == ["America/Sao_Paulo"])
        #expect(s.uses24Hour)
        #expect(s.redSunday)
    }

    @Test func emptyClockListBecomesOne() {
        let s = Settings.decode(#"{"clocks":[],"uses24Hour":false,"redSunday":false}"#, systemZone: toronto)
        #expect(s.clocks.map(\.zoneID) == ["America/Toronto"])
        #expect(!s.uses24Hour)
    }

    @Test func tooManyClocksAreCutToFour() {
        var s = Settings.defaults(systemZone: toronto)
        s.clocks = (1...6).map { Clock(zoneID: "America/Sao_Paulo", label: "C\($0)") }
        #expect(s.normalized(systemZone: toronto).clocks.map(\.label) == ["C1", "C2", "C3", "C4"])
    }

    @Test func normalizedCleansLabels() {
        var s = Settings.defaults(systemZone: toronto)
        s.clocks = [Clock(zoneID: "America/Sao_Paulo", label: " são paulo xx ")]
        #expect(s.normalized(systemZone: toronto).clocks.map(\.label) == ["SAOP"])
    }

    @Test(arguments: [(" são paulo xx ", "SAOP"), ("to", "TO"), ("", ""), ("  ", ""), ("N.Y.", "N.Y."), ("ÇÉ", "CE")])
    func cleanLabel(raw: String, expected: String) {
        #expect(Clock.cleanLabel(raw) == expected)
    }
}
