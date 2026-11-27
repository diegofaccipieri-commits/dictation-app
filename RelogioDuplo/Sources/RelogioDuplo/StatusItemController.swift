import AppKit
import SwiftUI

/// Item da barra: clique esquerdo abre o calendário, clique direito abre o menu de ajustes.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var citiesWindow: NSWindow?

    private static let autosaveName = "RelogioDuplo"

    /// Sem posição salva, o item nasce encostado na Central de Controle e no relógio do macOS
    /// (o sistema guarda a distância até a borda direita). Chamar antes de criar o item.
    static func preferFirstPosition(defaults: UserDefaults = .standard) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        if defaults.object(forKey: key) == nil { defaults.set(0, forKey: key) }
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        // Nome fixo: a posição escolhida com Command + arrastar sobrevive a reinícios e atualizações.
        statusItem.autosaveName = Self.autosaveName
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.onChange = { [weak self] in self?.render() }
        render()
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let darkBar = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        button.image = MenuBarImage.make(pieces: model.pieces, darkBar: darkBar)
        button.setAccessibilityLabel(model.plainText)
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggleCalendar()
        }
    }

    // MARK: Calendário

    private func toggleCalendar() {
        if panel != nil {
            closeCalendar()
        } else {
            openCalendar()
        }
    }

    /// Painel colado logo abaixo da barra, na mesma posição em que o menu do clique direito aparece.
    private func openCalendar() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        // View nova a cada abertura: o calendário sempre volta ao mês atual.
        let hosting = NSHostingView(rootView: CalendarPopover(model: model))
        let size = hosting.fittingSize

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)

        let panel = CalendarPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.contentView = background

        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        let x = min(max(anchor.minX, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        // Qualquer clique fora do painel fecha, como um menu. O clique no próprio item da barra
        // também chega aqui (o sistema desenha o item fora do nosso processo); esse fica para
        // `clicked`, senão o painel fecharia e reabriria no mesmo clique.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isMouseOverButton else { return }
                self.closeCalendar()
            }
        }
    }

    private var isMouseOverButton: Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    private func closeCalendar() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: Menu

    private func showMenu() {
        closeCalendar()
        let menu = NSMenu()
        menu.addItem(item("Cidades e relógios…", #selector(openCities)))
        menu.addItem(.separator())
        menu.addItem(item("Mês e dia da semana", #selector(toggleDate), checked: model.settings.showsDate))
        menu.addItem(item("Segundos", #selector(toggleSeconds), checked: model.settings.showsSeconds))
        menu.addItem(item("Formato 24 horas", #selector(toggle24Hour), checked: model.settings.uses24Hour))
        menu.addItem(item("Domingo em vermelho", #selector(toggleRedSunday), checked: model.settings.redSunday))
        menu.addItem(.separator())
        menu.addItem(item(
            "Relógio do macOS analógico e sem data", #selector(toggleSystemClock),
            checked: model.settings.compactSystemClock))

        // Atribuir o menu só durante o clique mantém o clique esquerdo livre para o calendário.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    @objc private func toggleDate() {
        model.update { $0.showsDate.toggle() }
    }

    @objc private func toggleSeconds() {
        model.update { $0.showsSeconds.toggle() }
    }

    @objc private func toggleSystemClock() {
        model.update { $0.compactSystemClock.toggle() }
    }

    @objc private func toggle24Hour() {
        model.update { $0.uses24Hour.toggle() }
    }

    @objc private func toggleRedSunday() {
        model.update { $0.redSunday.toggle() }
    }

    @objc private func openCities() {
        if citiesWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: CitiesView(model: model)))
            window.title = "Cidades e relógios"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            citiesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        citiesWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Painel sem borda que aceita foco, para os botões do calendário responderem ao primeiro clique.
private final class CalendarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct CalendarPopover: View {
    let model: AppModel

    var body: some View {
        CalendarView(today: model.now, redSunday: model.settings.redSunday)
            .padding(12)
            .fixedSize()
    }
}
