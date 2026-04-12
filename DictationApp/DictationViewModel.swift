import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

@MainActor
class DictationViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var transcribedText: String = ""
    @Published var errorMessage: String? = nil
    @Published var isModelLoaded: Bool = false
    @Published var isModelLoading: Bool = false
    @Published var isFinalModelReady: Bool = false
    @Published var history: [String] = (UserDefaults.standard.array(forKey: "transcriptionHistory") as? [String]) ?? []
    @Published var isWakeWordEnabled: Bool = UserDefaults.standard.bool(forKey: "wakeWordEnabled")
    @Published var batchStatus: String? = nil
    @Published var liveModel: WhisperModel = WhisperModel(rawValue: UserDefaults.standard.string(forKey: "liveModel") ?? "") ?? .defaultLive
    @Published var batchModel: WhisperModel = WhisperModel(rawValue: UserDefaults.standard.string(forKey: "batchModel") ?? "") ?? .defaultBatch
    @Published var translationMode: TranslationMode = TranslationMode(rawValue: UserDefaults.standard.string(forKey: "translationMode") ?? "") ?? .off
    @Published var isTranslating: Bool = false

    private let recorder = AudioRecorder()
    private let transcriptionManager = TranscriptionManager()
    private let translator = OllamaTranslator()
    var finalTranscriber: FinalTranscriber { transcriptionManager.final_ }
    private let hud = DictationHUD()
    private let wakeWordMonitor = WakeWordMonitor()
    private var transcriptionTask: Task<Void, Never>?

    init() {
        wakeWordMonitor.onWakeWord = { [weak self] in
            guard let self, self.state == .idle else { return }
            self.toggle()
        }
        recorder.onRecordingInterrupted = { [weak self] in
            guard let self, self.state == .recording else { return }
            NSLog("DictationApp: recording interrupted — finalizing with captured audio")
            self.stopRecording()
        }
        Task { await self.loadModels(liveModel: liveModel, batchModel: batchModel) }
    }

    func setWakeWord(enabled: Bool) {
        isWakeWordEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "wakeWordEnabled")
        if enabled {
            wakeWordMonitor.requestAuthorization { [weak self] granted in
                guard granted else { return }
                self?.wakeWordMonitor.start()
            }
        } else {
            wakeWordMonitor.stop()
        }
    }

    func setLiveModel(_ model: WhisperModel) {
        NSLog("DictationApp: [VM] setLiveModel called: %@", model.displayName)
        liveModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "liveModel")
        Task { await transcriptionManager.updateModels(liveModel: model, batchModel: batchModel) }
    }

    func setBatchModel(_ model: WhisperModel) {
        NSLog("DictationApp: [VM] setBatchModel called: %@", model.displayName)
        batchModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "batchModel")
        Task { await transcriptionManager.updateModels(liveModel: liveModel, batchModel: model) }
    }

    func setTranslationMode(_ mode: TranslationMode) {
        translationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "translationMode")
        NSLog("DictationApp: [VM] translationMode -> %@", mode.displayName)
    }

    private func loadModels(liveModel: WhisperModel = .defaultLive, batchModel: WhisperModel = .defaultBatch) async {
        isModelLoading = true
        NSLog("DictationApp: [VM] loading models: live=%@ batch=%@", liveModel.displayName, batchModel.displayName)
        await transcriptionManager.loadModels(liveModel: liveModel, batchModel: batchModel)
        isModelLoaded = true
        isModelLoading = false
        NSLog("DictationApp: [VM] whisper.cpp server ready, isModelLoaded=true")
        Task.detached(priority: .background) { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let ready = await self?.transcriptionManager.isFinalModelReady ?? false
                if ready {
                    await MainActor.run { self?.isFinalModelReady = true }
                    break
                }
            }
        }
    }

    func toggle() {
        guard isModelLoaded else { return }
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .transcribing, .correcting:
            break
        }
    }

    func cancel() {
        guard state == .recording || state == .transcribing else { return }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        recorder.stopRecording()
        state = .idle
        hud.hide()
        if isWakeWordEnabled { wakeWordMonitor.start() }
    }

    private func startRecording() {
        NSLog("DictationApp: [VM] startRecording called")
        transcribedText = ""
        errorMessage = nil
        wakeWordMonitor.stop()
        do {
            try recorder.startRecording()
            state = .recording
            let cursor = NSEvent.mouseLocation
            hud.show(state: .recording, near: cursor)
        } catch {
            NSLog("DictationApp: [VM] ERROR starting recording: %@", error.localizedDescription)
            errorMessage = "Microphone error: \(error.localizedDescription)"
            if isWakeWordEnabled { wakeWordMonitor.start() }
        }
    }

    private func stopRecording() {
        NSLog("DictationApp: [VM] stopRecording called")
        state = .transcribing
        hud.update(state: .transcribing)

        let (allSamples, _) = recorder.currentSamples
        NSLog("DictationApp: [VM] captured %d samples (%.1fs)", allSamples.count, Double(allSamples.count) / 16000.0)

        finalizeTranscription(samples: allSamples)
        recorder.stopRecording()
    }

    // MARK: - Final transcription (whisper.cpp server)

    private func finalizeTranscription(samples: [Float]) {
        NSLog("DictationApp: [FINAL] finalizeTranscription called, %d samples (%.1fs)", samples.count, Double(samples.count) / 16000.0)

        guard samples.count >= 4800 else {
            NSLog("DictationApp: [FINAL] too short (%d samples) — skipping", samples.count)
            errorMessage = "Recording too short"
            state = .idle
            hud.hide()
            if isWakeWordEnabled { wakeWordMonitor.start() }
            return
        }

        let manager = transcriptionManager
        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            NSLog("DictationApp: [FINAL] calling transcribeSamplesFinal...")
            let result = await manager.transcribeSamplesFinal(samples)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            NSLog("DictationApp: [FINAL] transcribed %d chars in %.1fs: '%@'", result.count, elapsed, String(result.prefix(100)))

            // Translation step (if enabled)
            let mode = await MainActor.run { self?.translationMode ?? .off }
            var finalText = result
            if mode != .off && !result.isEmpty {
                await MainActor.run {
                    self?.isTranslating = true
                    self?.hud.updateText("Translating...")
                }
                NSLog("DictationApp: [TRANSLATE] starting %@ for %d chars", mode.displayName, result.count)
                if let translated = await self?.translator.translate(result, mode: mode) {
                    finalText = translated
                    NSLog("DictationApp: [TRANSLATE] done: %d chars", translated.count)
                } else {
                    NSLog("DictationApp: [TRANSLATE] failed — using original text")
                }
                await MainActor.run { self?.isTranslating = false }
            }

            await MainActor.run {
                guard let self else { return }
                if finalText.isEmpty {
                    NSLog("DictationApp: [FINAL] no text — nothing to paste")
                    self.errorMessage = "No speech detected"
                    self.state = .idle
                    self.hud.hide()
                    if self.isWakeWordEnabled { self.wakeWordMonitor.start() }
                } else {
                    NSLog("DictationApp: [FINAL] pasting %d chars", finalText.count)
                    self.transcribedText = finalText
                    self.addToHistory(finalText)
                    self.copyToClipboard(finalText)
                    self.pasteIntoFocusedApp()
                    self.errorMessage = nil
                    self.state = .correcting
                    self.hud.update(state: .correcting)
                }
            }

            guard !finalText.isEmpty else { return }

            // Show checkmark for 1 second then dismiss
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                guard let self else { return }
                self.state = .idle
                self.hud.hide()
                NSLog("DictationApp: [FINAL] state -> idle, done")
                if self.isWakeWordEnabled { self.wakeWordMonitor.start() }
            }
        }
    }

    // MARK: - Helpers

    func reuseHistoryItem(_ text: String) {
        copyToClipboard(text)
        pasteIntoFocusedApp()
    }

    private func addToHistory(_ text: String) {
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        if history.count > 5 { history = Array(history.prefix(5)) }
        UserDefaults.standard.set(history, forKey: "transcriptionHistory")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func pasteIntoFocusedApp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyV: CGKeyCode = 0x09
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
            cmdDown?.flags = .maskCommand
            cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
            cmdUp?.flags = .maskCommand
            cmdUp?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
