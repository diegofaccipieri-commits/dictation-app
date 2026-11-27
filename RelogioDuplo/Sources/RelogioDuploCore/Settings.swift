import Foundation

public struct Clock: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var zoneID: String
    public var label: String

    public init(id: UUID = UUID(), zoneID: String, label: String) {
        self.id = id
        self.zoneID = zoneID
        self.label = label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        zoneID = try c.decode(String.self, forKey: .zoneID)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    /// Sigla da barra: sem espaços e acentos, maiúsculas, até 4 caracteres.
    public static func cleanLabel(_ raw: String) -> String {
        let folded = raw.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.uppercased().filter { !$0.isWhitespace }.prefix(4))
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public static let maxClocks = 4

    public var clocks: [Clock]
    public var uses24Hour: Bool
    public var redSunday: Bool

    public init(clocks: [Clock], uses24Hour: Bool = true, redSunday: Bool = true) {
        self.clocks = clocks
        self.uses24Hour = uses24Hour
        self.redSunday = redSunday
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clocks = try c.decode([Clock].self, forKey: .clocks)
        uses24Hour = try c.decodeIfPresent(Bool.self, forKey: .uses24Hour) ?? true
        redSunday = try c.decodeIfPresent(Bool.self, forKey: .redSunday) ?? true
    }

    public static func defaultClock(systemZone: TimeZone) -> Clock {
        let name = CityCatalog.name(for: systemZone.identifier, locale: .current)
        return Clock(zoneID: systemZone.identifier, label: CityCatalog.suggestedLabel(for: name))
    }

    public static func defaults(systemZone: TimeZone) -> Settings {
        Settings(clocks: [defaultClock(systemZone: systemZone)])
    }

    /// Garante de 1 a 4 relógios e siglas limpas.
    public func normalized(systemZone: TimeZone) -> Settings {
        var copy = self
        copy.clocks = clocks.prefix(Self.maxClocks).map {
            Clock(id: $0.id, zoneID: $0.zoneID, label: Clock.cleanLabel($0.label))
        }
        if copy.clocks.isEmpty { copy.clocks = [Self.defaultClock(systemZone: systemZone)] }
        return copy
    }

    public static func decode(_ json: String?, systemZone: TimeZone) -> Settings {
        guard let data = json?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            return defaults(systemZone: systemZone)
        }
        return decoded.normalized(systemZone: systemZone)
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
