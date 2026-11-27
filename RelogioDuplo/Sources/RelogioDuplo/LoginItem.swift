import os
import ServiceManagement

/// O app sempre abre no login: registra a cada inicialização, sem opção na interface.
enum LoginItem {
    static func ensureEnabled() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do { try SMAppService.mainApp.register() } catch {
            Logger(subsystem: "com.diegofaccipieri.RelogioDuplo", category: "login")
                .error("Abrir no login falhou: \(error.localizedDescription)")
        }
    }
}
