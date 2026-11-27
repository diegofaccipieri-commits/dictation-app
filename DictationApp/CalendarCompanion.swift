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

    /// Copia o app embutido quando o instalado falta ou tem binário diferente.
    /// Devolve `true` se instalou. Sem app embutido, não faz nada.
    @discardableResult
    static func installIfNeeded(
        embedded: URL, installed: URL, fileManager: FileManager = .default, beforeReplace: () -> Void = {}
    ) throws -> Bool {
        let source = embedded.appendingPathComponent(binaryPath).path
        let target = installed.appendingPathComponent(binaryPath).path
        guard fileManager.fileExists(atPath: source) else { return false }
        if fileManager.fileExists(atPath: target), fileManager.contentsEqual(atPath: source, andPath: target) {
            return false
        }
        // Copia para o lado e só então troca: uma cópia interrompida não deixa o app pela metade.
        let staging = installed.deletingLastPathComponent().appendingPathComponent(".\(appName).instalando")
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: embedded, to: staging)
        beforeReplace()
        if fileManager.fileExists(atPath: installed.path) { try fileManager.removeItem(at: installed) }
        try fileManager.moveItem(at: staging, to: installed)
        return true
    }

    // MARK: Privado

    private static func enable(embedded: URL?) throws {
        setDisabledByHost(false)
        if let embedded {
            try installIfNeeded(embedded: embedded, installed: installedURL, beforeReplace: terminateRunning)
        }
        guard FileManager.default.fileExists(atPath: installedURL.path), running().isEmpty else { return }
        launch()
    }

    private static func disable() {
        guard FileManager.default.fileExists(atPath: installedURL.path) else { return }
        setDisabledByHost(true)
        terminateRunning()
        // Aberto com a chave gravada, o calendário sai do login e encerra sozinho.
        launch()
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
