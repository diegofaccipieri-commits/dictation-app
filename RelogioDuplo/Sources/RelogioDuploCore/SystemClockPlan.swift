/// O que gravar nos ajustes do relógio do macOS (`com.apple.menuextra.clock`) para deixá-lo
/// compacto (analógico, sem data e sem dia da semana) e para devolver o que a pessoa tinha.
/// Valores como inteiros: booleanos são 0 ou 1; `ShowDate` 2 é "nunca".
public struct SystemClockPlan: Equatable, Sendable {
    public static let target = ["IsAnalog": 1, "ShowDate": 2, "ShowDayOfWeek": 0]
    public static let keys = target.keys.sorted()

    public var writes: [String: Int]
    public var removals: [String]
    /// O que deve ficar guardado depois de aplicar o plano; `nil` apaga a cópia.
    public var backup: [String: Int]?

    /// `current` traz só as chaves que existem. A primeira cópia do original nunca é sobrescrita.
    public static func compact(current: [String: Int], backup: [String: Int]?) -> SystemClockPlan {
        SystemClockPlan(
            writes: target.filter { current[$0.key] != $0.value },
            removals: [],
            backup: backup ?? current.filter { target[$0.key] != nil })
    }

    /// Sem cópia guardada, não há o que devolver.
    public static func restore(current: [String: Int], backup: [String: Int]?) -> SystemClockPlan? {
        guard let backup else { return nil }
        return SystemClockPlan(
            writes: backup.filter { target[$0.key] != nil && current[$0.key] != $0.value },
            removals: keys.filter { backup[$0] == nil && current[$0] != nil },
            backup: nil)
    }
}
