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
        requestAccessibilityAndSetupFnKey()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dictation")
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    func requestAccessibilityAndSetupFnKey() {
        fnMonitor.onDoubleTap = { [weak self] in
            NSLog("DictationApp: onDoubleTap fired → calling toggle()")
            self?.viewModel.toggle()
        }
        fnMonitor.onEscape = { [weak self] in self?.viewModel.cancel() }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("DictationApp: AXIsProcessTrustedWithOptions = \(trusted)")
        if trusted {
            NSLog("DictationApp: Accessibility granted — starting monitor")
            fnMonitor.start()
        } else {
            NSLog("DictationApp: Accessibility NOT granted — polling...")
            Task.detached { [weak self] in
                var attempt = 0
                while true {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    attempt += 1
                    if AXIsProcessTrusted() {
                        NSLog("DictationApp: Accessibility granted after \(attempt)s — starting monitor")
                        await MainActor.run { self?.fnMonitor.start() }
                        break
                    }
                }
            }
        }
    }

    @objc func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func showContextMenu() {
        let menu = NSMenu()

        let stateItem = NSMenuItem(title: viewModel.state == .recording ? "Stop Recording" : "Start Recording",
                                   action: #selector(toggleRecording), keyEquivalent: "")
        stateItem.target = self
        menu.addItem(stateItem)

        menu.addItem(.separator())

        let restartItem = NSMenuItem(title: "Restart", action: #selector(restartApp), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil  // remove after showing so left-click still works
    }

    @objc func toggleRecording() {
        viewModel.toggle()
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc func restartApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [url.path]
        task.launch()
        NSApp.terminate(nil)
    }
}
