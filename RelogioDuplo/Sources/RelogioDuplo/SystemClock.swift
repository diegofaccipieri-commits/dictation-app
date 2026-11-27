import Foundation
import os
import RelogioDuploCore

/// Deixa o relógio do macOS compacto, já que ele não pode ser removido da barra,
/// e devolve o que a pessoa tinha quando a opção é desligada.
enum SystemClock {
    private static var domain: CFString { "com.apple.menuextra.clock" as CFString }
    private static let backupKey = "systemClockBackup"
    private static let log = Logger(subsystem: "com.diegofaccipieri.RelogioDuplo", category: "system-clock")

    static func sync(compact: Bool, defaults: UserDefaults = .standard) {
        let backup = defaults.dictionary(forKey: backupKey) as? [String: Int]
        let current = read()
        let plan = compact
            ? SystemClockPlan.compact(current: current, backup: backup)
            : SystemClockPlan.restore(current: current, backup: backup)
        guard let plan else { return }

        if let kept = plan.backup { defaults.set(kept, forKey: backupKey) } else { defaults.removeObject(forKey: backupKey) }
        guard !plan.writes.isEmpty || !plan.removals.isEmpty else { return }
        for (key, value) in plan.writes {
            // `ShowDate` é um número; as outras chaves são booleanas.
            let stored: CFPropertyList = key == "ShowDate" ? value as CFNumber : (value != 0) as CFBoolean
            CFPreferencesSetAppValue(key as CFString, stored, domain)
        }
        for key in plan.removals { CFPreferencesSetAppValue(key as CFString, nil, domain) }
        CFPreferencesAppSynchronize(domain)
        reloadMenuBarClock()
    }

    private static func read() -> [String: Int] {
        CFPreferencesAppSynchronize(domain)
        var values: [String: Int] = [:]
        for key in SystemClockPlan.keys {
            if let number = CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber { values[key] = number.intValue }
        }
        return values
    }

    /// O relógio da barra só relê os ajustes quando o processo que o desenha reinicia;
    /// o sistema o reabre sozinho em seguida.
    private static func reloadMenuBarClock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["ControlCenter"]
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { log.error("Relógio do macOS não recarregou: \(error.localizedDescription)") }
    }
}
