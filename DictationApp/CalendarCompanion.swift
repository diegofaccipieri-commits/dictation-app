import AppKit
import os

/// Instala e controla o calendário de barra de menu (RelogioDuplo), que vai embutido
/// em `Contents/Resources`. Fonte do calendário: pasta `RelogioDuplo/` deste repositório.
enum CalendarCompanion {
    static let bundleID = "com.diegofaccipieri.RelogioDuplo"
    static let appName = "RelogioDuplo.app"
    static let enabledKey = "calendarCompanionEnabled"

    private static let binaryPath = "Contents/MacOS/RelogioDuplo"
    private static let installedURL = URL(fileURLWithPath: "/Applications").appendingPathComponent(appName)
    private static let queue = DispatchQueue(label: "com.diego.dictationapp.calendar-companion")
    private static let log = Logger(subsystem: "com.diego.dictationapp", category: "calendar")

    /// Ligado por padrão.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Deixa o calendário no estado pedido pela opção. Roda fora da thread principal.
    static func sync() {
        let enabled = isEnabled
        let embedded = Bundle.main.resourceURL?.appendingPathComponent(appName)
        queue.async {
            do {
                if enabled {
                    try enable(embedded: embedded)
                } else {
                    disable()
                }
            } catch {
                log.error("Calendário: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    enum InstallError: LocalizedError {
        case foreignApp(String)

        var errorDescription: String? {
            switch self {
            case .foreignApp(let path): return "\(path) não é o calendário do DictationApp; não foi alterado."
            }
        }
    }

    /// Copia o app embutido quando o instalado falta ou tem binário diferente.
    /// Devolve `true` se instalou. Sem app embutido, não faz nada.
    /// `beforeReplace` roda só quando um calendário já instalado vai ser trocado.
    @discardableResult
    static func installIfNeeded(
        embedded: URL, installed: URL, fileManager: FileManager = .default, beforeReplace: () -> Void = {}
    ) throws -> Bool {
        let source = embedded.appendingPathComponent(binaryPath).path
        let target = installed.appendingPathComponent(binaryPath).path
        guard fileManager.fileExists(atPath: source) else { return false }

        let exists = fileManager.fileExists(atPath: installed.path)
        if exists {
            // Nunca mexe num app de outra origem que por acaso esteja no mesmo caminho.
            guard Bundle(url: installed)?.bundleIdentifier == bundleID else {
                throw InstallError.foreignApp(installed.path)
            }
            if fileManager.contentsEqual(atPath: source, andPath: target) { return false }
        }

        // Copia para o lado e só então troca: uma cópia interrompida não deixa o app pela metade.
        let staging = installed.deletingLastPathComponent().appendingPathComponent(".\(appName).instalando")
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: embedded, to: staging)
        do {
            if exists {
                beforeReplace()
                // Troca atômica: se falhar, o app antigo continua no lugar.
                _ = try fileManager.replaceItemAt(installed, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: installed)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return true
    }

    // MARK: Privado

    private static func enable(embedded: URL?) throws {
        setDisabledByHost(false)
        var installError: Error?
        if let embedded {
            do {
                try installIfNeeded(embedded: embedded, installed: installedURL, beforeReplace: terminateRunning)
            } catch {
                installError = error
            }
        }
        // Mesmo com falha na troca, o calendário que estiver instalado volta a rodar.
        if isOurAppInstalled, running().isEmpty { launch() }
        if let installError { throw installError }
    }

    private static func disable() {
        guard isOurAppInstalled else { return }
        // Já desligado e parado: nada a fazer (evita abrir o calendário a cada início do DictationApp).
        if isDisabledByHost, running().isEmpty { return }
        setDisabledByHost(true)
        terminateRunning()
        // Aberto com a chave gravada, o calendário sai do login e encerra sozinho.
        launch()
    }

    private static var isOurAppInstalled: Bool {
        Bundle(url: installedURL)?.bundleIdentifier == bundleID
    }

    private static var isDisabledByHost: Bool {
        CFPreferencesAppSynchronize(bundleID as CFString)
        return CFPreferencesCopyAppValue("disabledByHost" as CFString, bundleID as CFString) as? Bool ?? false
    }

    private static func setDisabledByHost(_ disabled: Bool) {
        CFPreferencesSetAppValue("disabledByHost" as CFString, disabled as CFBoolean, bundleID as CFString)
        CFPreferencesAppSynchronize(bundleID as CFString)
    }

    private static func running() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    private static func terminateRunning() {
        running().forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while !running().isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        running().forEach { $0.forceTerminate() }
    }

    private static func launch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: installedURL, configuration: configuration) { _, error in
            if let error { log.error("Calendário não abriu: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
