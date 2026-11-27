import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // O DictationApp desliga o calendário gravando esta chave no nosso domínio.
        let disabled = UserDefaults.standard.bool(forKey: "disabledByHost")
        guard LoginItem.apply(disabledByHost: disabled) else {
            NSApp.terminate(nil)
            return
        }
        StatusItemController.preferFirstPosition()
        controller = StatusItemController(model: AppModel())
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
