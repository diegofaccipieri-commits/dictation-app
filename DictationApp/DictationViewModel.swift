import SwiftUI
import AppKit
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

    private let recorder = AudioRecorder()
    private let transcriptionManager = TranscriptionManager()
    var finalTranscriber: FinalTranscriber { transcriptionManager.final_ }
    private let hud = DictationHUD()
    private let wakeWordMonitor = WakeWordMonitor()
    private var transcriptionTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?

    // Streaming: accumulated committed text + current chunk pointer.
    // Small model commits chunks during recording as a live preview.
    // Large-v3 replaces everything with accurate result when recording stops.
    private var committedText: String = ""
    private var committedSampleIndex: Int = 0
    private let chunkSeconds = 7

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
        Task { await self.loadModels() }
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

    private func loadModels() async {
        isModelLoading = true
        do {
            try await transcriptionManager.loadModels()
            isModelLoaded = true
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
        } catch {
            errorMessage = "Failed to load model: \(error.localizedDescription)"
        }
        isModelLoading = false
    }

    func toggle() {
        guard isModelLoaded else { return }
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .transcribing:
            break
        }
    }

    func cancel() {
        guard state == .recording || state == .transcribing else { return }
        streamingTask?.cancel()
        streamingTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        recorder.onRecordingFinished = { url in try? FileManager.default.removeItem(at: url) }
        recorder.stopRecording()
        committedText = ""
        committedSampleIndex = 0
        state = .idle
        hud.hide()
        if isWakeWordEnabled { wakeWordMonitor.start() }
    }

    private func startRecording() {
        committedText = ""
        committedSampleIndex = 0
        transcribedText = ""
        errorMessage = nil
        wakeWordMonitor.stop()
        do {
            try recorder.startRecording()
            state = .recording
            let cursor = NSEvent.mouseLocation
            hud.show(state: .recording, near: cursor)
            startStreamingLoop()
        } catch {
            errorMessage = "Microphone error: \(error.localizedDescription)"
            if isWakeWordEnabled { wakeWordMonitor.start() }
        }
    }

    private func stopRecording() {
        streamingTask?.cancel()
        streamingTask = nil
        state = .transcribing
        hud.update(state: .transcribing)

        // Snapshot streaming text — used as fallback if final transcription times out.
        let fallback = committedText

        recorder.onRecordingFinished = { [weak self] url in
            self?.finalizeTranscription(url: url, fallback: fallback)
        }
        recorder.stopRecording()
        committedText = ""
        committedSampleIndex = 0
    }

    // MARK: - Streaming loop (small model, live preview during recording)

    private func startStreamingLoop() {
        let manager = transcriptionManager
        let chunk = chunkSeconds

        streamingTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let (allSamples, sampleRate) = await self.samplesSnapshot()
                let commitIdx = await self.committedSampleIndex
                let committed = await self.committedText

                let safeIdx = min(commitIdx, allSamples.count)
                let pendingSamples = Array(allSamples[safeIdx...])
                let minSamples = Int(sampleRate)

                guard pendingSamples.count >= minSamples else { continue }

                let chunkSize = Int(sampleRate) * chunk

                if pendingSamples.count >= chunkSize {
                    let chunkSamples = Array(pendingSamples.prefix(chunkSize))
                    let chunkText = await manager.transcribeSamples(chunkSamples)

                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        if !chunkText.isEmpty {
                            self.committedText = committed.isEmpty ? chunkText : committed + " " + chunkText
                        }
                        self.committedSampleIndex = safeIdx + chunkSize
                        self.transcribedText = self.committedText
                        self.hud.updateText(self.committedText)
                    }
                } else {
                    let previewText = await manager.transcribeSamples(pendingSamples)

                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        if previewText.isEmpty {
                            self.transcribedText = committed
                        } else {
                            self.transcribedText = committed.isEmpty ? previewText : committed + " " + previewText
                        }
                        self.hud.updateText(self.transcribedText)
                    }
                }
            }
        }
    }

    // MARK: - Final transcription (large-v3)
    //
    // Replaces the streaming preview with the accurate multilingual result.
    // Timeout: 45s. If it times out, uses the streaming preview as result.

    private func finalizeTranscription(url: URL, fallback: String) {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard fileSize > 0 else {
            errorMessage = "Recording was empty"
            state = .idle
            hud.hide()
            return
        }

        let manager = transcriptionManager
        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            let text: String = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    NSLog("DictationApp: final transcription timed out — using streaming fallback")
                    return nil
                }
                group.addTask {
                    NSLog("DictationApp: starting final large-v3 transcription")
                    return try? await manager.transcribeFinal(url: url)
                }
                for await result in group {
                    group.cancelAll()
                    if let result { return result }
                    return fallback
                }
                return fallback
            }

            await MainActor.run {
                if text.isEmpty {
                    self?.errorMessage = "No speech detected"
                } else {
                    self?.transcribedText = text
                    self?.addToHistory(text)
                    self?.copyToClipboard(text)
                    self?.pasteIntoFocusedApp()
                    self?.errorMessage = nil
                }
                self?.state = .idle
                self?.hud.hide()
                if self?.isWakeWordEnabled == true { self?.wakeWordMonitor.start() }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private func samplesSnapshot() -> ([Float], Double) {
        recorder.currentSamples
    }

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
