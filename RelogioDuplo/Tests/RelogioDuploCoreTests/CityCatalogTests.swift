import Foundation
import Testing
@testable import RelogioDuploCore

@Suite struct CityCatalogTests {
    let ptBR = Locale(identifier: "pt_BR")

    @Test func containsRealCitiesOnly() {
        let ids = Set(CityCatalog.all(locale: ptBR).map(\.zoneID))
        #expect(ids.contains("America/Toronto"))
        #expect(ids.contains("America/Sao_Paulo"))
        #expect(ids.filter { $0.hasPrefix("Etc/") || $0 == "GMT" || !$0.contains("/") }.isEmpty)
    }

    @Test func sortedByName() {
        let names = CityCatalog.all(locale: ptBR).map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func localizedCityName() {
        #expect(CityCatalog.name(for: "America/Sao_Paulo", locale: ptBR) == "São Paulo")
        #expect(CityCatalog.name(for: "America/Toronto", locale: ptBR) == "Toronto")
    }

    @Test func unknownZoneUsesLastPathComponent() {
        #expect(CityCatalog.name(for: "Marte/Olympus_Mons", locale: ptBR) == "Olympus Mons")
    }

    @Test func searchIgnoresCaseAndAccents() {
        let all = CityCatalog.all(locale: ptBR)
        #expect(CityCatalog.search("sao pa", in: all).map(\.zoneID) == ["America/Sao_Paulo"])
        #expect(CityCatalog.search("toronto", in: all).map(\.zoneID).contains("America/Toronto"))
        #expect(CityCatalog.search("  ", in: all).count == all.count)
        #expect(CityCatalog.search("zzzzqq", in: all).isEmpty)
    }

    @Test(arguments: [("São Paulo", "SP"), ("New York", "NY"), ("Toronto", "TO"), ("Rio de Janeiro", "RDJ"),
                      ("", ""), ("Port-au-Prince", "PAP"), ("A", "A"), ("Ho Chi Minh City Extra", "HCMC")])
    func suggestedLabel(name: String, expected: String) {
        #expect(CityCatalog.suggestedLabel(for: name) == expected)
    }
}
