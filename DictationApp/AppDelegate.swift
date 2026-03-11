import AppKit
import Combine
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let viewModel = DictationViewModel()
    private var cancellables = Set<AnyCancellable>()
    private let fnMonitor = FnKeyMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupFnKey()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dictation")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let contentView = ContentView(viewModel: viewModel)
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 260)
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: contentView)
        self.popover = popover

        viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                let iconName = state == .recording ? "mic.fill" : "mic"
                self?.statusItem?.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Dictation")
                self?.statusItem?.button?.contentTintColor = state == .recording ? .systemRed : nil
            }
            .store(in: &cancellables)
    }

    func setupFnKey() {
        fnMonitor.onDoubleTap = { [weak self] in self?.viewModel.toggle() }
        fnMonitor.onEscape = { [weak self] in self?.viewModel.cancel() }
        fnMonitor.start()
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
