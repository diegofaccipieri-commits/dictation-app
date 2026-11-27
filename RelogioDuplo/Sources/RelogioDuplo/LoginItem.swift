import os
import ServiceManagement

/// O calendário sempre abre no login, a menos que o DictationApp o tenha desligado.
enum LoginItem {
    /// Devolve `true` se o app deve continuar rodando.
    static func apply(disabledByHost: Bool) -> Bool {
        let log = Logger(subsystem: "com.diegofaccipieri.RelogioDuplo", category: "login")
        let service = SMAppService.mainApp
        do {
            if disabledByHost {
                if service.status == .enabled { try service.unregister() }
            } else if service.status != .enabled {
                try service.register()
            }
        } catch {
            log.error("Ajuste do login falhou: \(error.localizedDescription)")
        }
        return !disabledByHost
    }
}
