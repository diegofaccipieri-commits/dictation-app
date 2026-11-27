import AppKit
import SwiftUI

/// Item da barra: clique esquerdo abre o calendário, clique direito abre o menu de ajustes.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var citiesWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
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
        button.image = MenuBarImage.make(pieces: model.pieces)
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
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // View nova a cada abertura: o calendário sempre volta ao mês atual.
        popover.contentViewController = NSHostingController(rootView: CalendarPopover(model: model))
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Menu

    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.addItem(item("Cidades e relógios…", #selector(openCities)))
        menu.addItem(.separator())
        menu.addItem(item("Formato 24 horas", #selector(toggle24Hour), checked: model.settings.uses24Hour))
        menu.addItem(item("Domingo em vermelho", #selector(toggleRedSunday), checked: model.settings.redSunday))

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

private struct CalendarPopover: View {
    let model: AppModel

    var body: some View {
        CalendarView(today: model.now, redSunday: model.settings.redSunday)
            .padding(12)
            .fixedSize()
    }
}
