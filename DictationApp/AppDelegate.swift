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
        // Accessory policy: app name visible in menu bar but never steals keyboard focus.
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        requestAccessibilityAndSetupFnKey()
        // Check for updates silently on launch.
        UpdateChecker.checkForUpdates(userInitiated: false)
    }

    // Clicking the Dock icon shows the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        togglePopover()
        return false
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
                self?.fnMonitor.isRecording = (state == .recording)
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

        // Version header (disabled, info only)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "DictationApp v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(.separator())

        let stateItem = NSMenuItem(title: viewModel.state == .recording ? "Stop Recording" : "Start Recording",
                                   action: #selector(toggleRecording), keyEquivalent: "")
        stateItem.target = self
        menu.addItem(stateItem)

        menu.addItem(.separator())

        let batchItem = NSMenuItem(title: "Transcrever Pasta…", action: #selector(startBatchTranscription), keyEquivalent: "")
        batchItem.target = self
        menu.addItem(batchItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let restartItem = NSMenuItem(title: "Restart", action: #selector(restartApp), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil  // remove after showing so left-click still works
    }

    @objc func startBatchTranscription() {
        let panel = NSOpenPanel()
        panel.title = "Selecionar pasta com gravações"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let batch = BatchTranscriber.shared
        guard !batch.isRunning else {
            notify(title: "Transcrição em lote", message: "Já está rodando. Aguarde.")
            return
        }

        batch.onProgress = { [weak self] msg in
            self?.statusItem?.button?.toolTip = msg
        }
        batch.onComplete = { [weak self] (done: Int, total: Int) in
            self?.statusItem?.button?.toolTip = nil
            self?.notify(title: "Transcrição concluída", message: "\(done) de \(total) arquivo(s) transcritos.")
        }

        batch.start(folder: folder, transcriber: viewModel.finalTranscriber)
        notify(title: "Transcrição em lote iniciada", message: "Processando arquivos em background…")
    }

    private func notify(title: String, message: String) {
        let n = NSUserNotification()
        n.title = title
        n.informativeText = message
        NSUserNotificationCenter.default.deliver(n)
    }

    @objc func checkForUpdates() {
        UpdateChecker.checkForUpdates(userInitiated: true)
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
