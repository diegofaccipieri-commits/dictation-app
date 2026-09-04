import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let viewModel = DictationViewModel()
    let hubRouter = MainHubRouter()
    private var cancellables = Set<AnyCancellable>()
    let fnMonitor = FnKeyMonitor()
    private let voiceMemosStore = VoiceMemosStore()
    private var mainWindow: NSWindow?
    private lazy var translationWorkspaceModel = TranslationWorkspaceViewModel(translator: viewModel.translator)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory policy: app name visible in menu bar but never steals keyboard focus.
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        requestAccessibilityAndSetupFnKey()
        // Check for updates silently on launch.
        UpdateChecker.checkForUpdates(userInitiated: false)
    }

    // Clicking the Dock icon shows the main hub.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.shutdown()
    }

    /// Menu bar icon as a template image so macOS tints it to match the bar
    /// (white on a dark menu bar, black on a light one).
    static func menuBarIcon(_ symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dictation")
        image?.isTemplate = true
        return image
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = Self.menuBarIcon("mic")
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        let contentView = MainHubView(
            router: hubRouter,
            viewModel: viewModel,
            translationModel: translationWorkspaceModel,
            voiceMemosStore: voiceMemosStore,
            fnMonitor: fnMonitor,
            onSelectFile: { [weak self] in self?.startFileTranscription() },
            onSelectFolder: { [weak self] in self?.startBatchTranscription() },
            onTranscribeMemos: { [weak self] ids, diarize in
                self?.transcribeMemos(ids: ids, diarize: diarize)
            },
            onCheckForUpdates: { [weak self] in self?.checkForUpdates() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictation"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 1080, height: 700)
        window.backgroundColor = AppColors.windowBGNS
        window.contentViewController = NSHostingController(rootView: contentView)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        window.isReleasedWhenClosed = false
        mainWindow = window

        viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                let iconName = state == .recording ? "mic.fill" : "mic"
                self?.statusItem?.button?.image = Self.menuBarIcon(iconName)
                // Template icon adapts to the menu bar (white on dark, black on light);
                // only recording overrides it with red.
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

        // Global keyboard shortcut (configurable by user)
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            NSLog("DictationApp: keyboard shortcut fired → calling toggle()")
            self?.viewModel.toggle()
        }

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

        menu.addItem(item(viewModel.state == .recording ? "Parar gravação" : "Iniciar ditado",
                          symbol: viewModel.state == .recording ? "stop.circle" : "record.circle",
                          action: #selector(toggleRecording)))
        menu.addItem(translationSelectorItem())

        menu.addItem(.separator())

        menu.addItem(item("Transcrever arquivo…", symbol: "doc.text", action: #selector(startFileTranscription)))
        menu.addItem(item("Transcrever pasta…", symbol: "folder", action: #selector(startBatchTranscription)))
        menu.addItem(item("Transcrever do Voice Memos…", symbol: "headphones", action: #selector(showVoiceMemos)))

        menu.addItem(.separator())

        menu.addItem(item("Tradução de texto…", symbol: "character.book.closed", action: #selector(showTranslationWorkspace)))
        menu.addItem(item("Reuniões…", symbol: "person.2.wave.2", action: #selector(showReunioes)))

        menu.addItem(.separator())

        menu.addItem(item("Buscar atualização…", symbol: "arrow.triangle.2.circlepath", action: #selector(checkForUpdates)))
        menu.addItem(item("Reiniciar", symbol: "arrow.counterclockwise.circle", action: #selector(restartApp)))

        let quitItem = NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil  // remove after showing so left-click still works
    }

    private func item(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return it
    }

    private func translationSelectorItem() -> NSMenuItem {
        let current = viewModel.translationMode
        let selector = NSMenuItem(
            title: "Tradução: \(current.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        selector.image = NSImage(
            systemSymbolName: current == .off ? "character.bubble" : "character.bubble.fill",
            accessibilityDescription: nil
        )

        let submenu = NSMenu(title: "Tradução do ditado")
        for mode in [TranslationMode.off] + TranslationMode.directModes {
            let option = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectTranslationMode(_:)),
                keyEquivalent: ""
            )
            option.target = self
            option.representedObject = mode.rawValue
            option.state = current == mode ? .on : .off
            submenu.addItem(option)
        }
        selector.submenu = submenu
        return selector
    }

    @objc private func selectTranslationMode(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let mode = TranslationMode(rawValue: rawValue),
            mode == .off || TranslationMode.directModes.contains(mode)
        else { return }

        viewModel.setTranslationMode(mode)
    }

    @objc func startFileTranscription() {
        let panel = NSOpenPanel()
        panel.title = "Selecionar arquivo de áudio ou vídeo"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .video, .mpeg4Movie, .quickTimeMovie]

        guard panel.runModal() == .OK, let file = panel.url else { return }

        let batch = BatchTranscriber.shared
        guard !batch.isRunning else {
            notify(title: "Transcrição em andamento", message: "Aguarde terminar antes de iniciar outra.")
            return
        }

        batch.onProgress = { [weak self] msg in
            self?.viewModel.batchStatus = msg
            self?.statusItem?.button?.image = Self.menuBarIcon("doc.text.magnifyingglass")
        }
        batch.onComplete = { [weak self] (done: Int, _: Int) in
            self?.viewModel.batchStatus = nil
            self?.statusItem?.button?.image = Self.menuBarIcon("mic")
            if done > 0 {
                let output = file.deletingPathExtension().appendingPathExtension("txt")
                self?.notify(title: "Transcrição concluída", message: output.lastPathComponent)
                NSWorkspace.shared.selectFile(output.path, inFileViewerRootedAtPath: output.deletingLastPathComponent().path)
            } else {
                self?.notify(title: "Transcrição falhou", message: "Verifique o arquivo e tente novamente.")
            }
        }

        batch.startSingleFile(file: file, transcriber: viewModel.finalTranscriber, model: viewModel.batchModel)
        viewModel.batchStatus = "Iniciando: \(file.lastPathComponent)"
        statusItem?.button?.image = Self.menuBarIcon("doc.text.magnifyingglass")
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
            self?.viewModel.batchStatus = msg
            self?.statusItem?.button?.image = Self.menuBarIcon("doc.text.magnifyingglass")
        }
        batch.onComplete = { [weak self] (done: Int, total: Int) in
            self?.viewModel.batchStatus = nil
            self?.statusItem?.button?.image = Self.menuBarIcon("mic")
            self?.notify(title: "Transcrição concluída", message: "\(done) de \(total) arquivo(s) transcritos.")
        }

        batch.start(folder: folder, transcriber: viewModel.finalTranscriber, model: viewModel.batchModel)
        viewModel.batchStatus = "Iniciando lote…"
        statusItem?.button?.image = Self.menuBarIcon("doc.text.magnifyingglass")
    }

    @objc func showReunioes() {
        guard #available(macOS 15, *) else {
            notify(title: "Reuniões", message: "O gravador de reuniões requer macOS 15 ou superior.")
            return
        }
        hubRouter.selection = .meetings
        showMainWindow()
    }

    @objc func showTranslationWorkspace() {
        hubRouter.selection = .translation
        translationWorkspaceModel.warmUp()
        showMainWindow()
    }

    @objc func showVoiceMemos() {
        voiceMemosStore.reload()
        hubRouter.selection = .voiceMemos
        showMainWindow()
    }

    private func transcribeMemos(ids: Set<String>, diarize: Bool) {
        let memos = voiceMemosStore.memos.filter { ids.contains($0.id) }
        guard !memos.isEmpty else { return }

        let batch = BatchTranscriber.shared
        guard !batch.isRunning else {
            notify(title: "Transcrição em andamento", message: "Aguarde terminar antes de iniciar outra.")
            return
        }

        let byURL = Dictionary(memos.map { ($0.fileURL, $0) }, uniquingKeysWith: { a, _ in a })
        batch.diarize = diarize
        batch.outputDirectory = VoiceMemosLibrary.outputFolder
        batch.nameProvider = { url in
            if let m = byURL[url] {
                return VoiceMemosLibrary.outputURL(for: m).deletingPathExtension().lastPathComponent
            }
            return url.deletingPathExtension().lastPathComponent
        }
        batch.onProgress = { [weak self] msg in
            self?.voiceMemosStore.status = msg
            self?.viewModel.batchStatus = msg
            self?.statusItem?.button?.image = Self.menuBarIcon("doc.text.magnifyingglass")
        }
        batch.onComplete = { [weak self] (done: Int, total: Int) in
            self?.voiceMemosStore.isTranscribing = false
            self?.voiceMemosStore.status = nil
            self?.voiceMemosStore.markTranscribed(ids: ids)
            self?.viewModel.batchStatus = nil
            self?.statusItem?.button?.image = Self.menuBarIcon("mic")
            self?.notify(title: "Voice Memos", message: "\(done) de \(total) transcrito(s).")
            try? FileManager.default.createDirectory(at: VoiceMemosLibrary.outputFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(VoiceMemosLibrary.outputFolder)
        }

        voiceMemosStore.isTranscribing = true
        voiceMemosStore.status = "Iniciando \(memos.count) memo(s)…"
        batch.startFiles(memos.map { $0.fileURL }, transcriber: viewModel.finalTranscriber, model: viewModel.batchModel)
        statusItem?.button?.image = Self.menuBarIcon("doc.text.magnifyingglass")
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
        if mainWindow?.isVisible == true {
            mainWindow?.orderOut(nil)
        } else {
            showMainWindow()
        }
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
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
