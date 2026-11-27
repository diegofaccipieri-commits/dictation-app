import Foundation

public struct City: Equatable, Sendable, Identifiable {
    public let zoneID: String
    public let name: String
    public let region: String
    public var id: String { zoneID }
}

public enum CityCatalog {
    /// Todos os fusos do sistema que correspondem a uma cidade, ordenados por nome.
    public static func all(locale: Locale) -> [City] {
        let formatter = cityFormatter(locale: locale)
        return TimeZone.knownTimeZoneIdentifiers
            .filter { $0.contains("/") && !$0.hasPrefix("Etc/") }
            .map { id in
                City(zoneID: id, name: name(for: id, formatter: formatter),
                     region: String(id.split(separator: "/").first ?? ""))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func name(for zoneID: String, locale: Locale) -> String {
        name(for: zoneID, formatter: cityFormatter(locale: locale))
    }

    public static func search(_ query: String, in cities: [City]) -> [City] {
        let needle = fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return cities }
        return cities.filter {
            fold($0.name).contains(needle) || fold($0.zoneID.replacingOccurrences(of: "_", with: " ")).contains(needle)
        }
    }

    /// Iniciais das palavras ("São Paulo" vira "SP") ou as duas primeiras letras ("Toronto" vira "TO").
    public static func suggestedLabel(for name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let raw = words.count > 1 ? String(words.compactMap(\.first)) : String(name.prefix(2))
        return Clock.cleanLabel(raw)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func cityFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "VVV"
        return formatter
    }

    private static func name(for zoneID: String, formatter: DateFormatter) -> String {
        let fallback = (zoneID.split(separator: "/").last.map(String.init) ?? zoneID)
            .replacingOccurrences(of: "_", with: " ")
        guard let zone = TimeZone(identifier: zoneID) else { return fallback }
        formatter.timeZone = zone
        let name = formatter.string(from: Date(timeIntervalSinceReferenceDate: 0))
        return name.isEmpty ? fallback : name
    }
}
