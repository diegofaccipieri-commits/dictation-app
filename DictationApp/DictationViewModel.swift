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

    private func loadModels(liveModel: WhisperModel = .defaultLive, batchModel: WhisperModel = .defaultBatch) async {
        isModelLoading = true
        NSLog("DictationApp: [VM] loading models: live=%@ batch=%@", liveModel.displayName, batchModel.displayName)
        do {
            try await transcriptionManager.loadModels(liveModel: liveModel, batchModel: batchModel)
            isModelLoaded = true
            NSLog("DictationApp: [VM] streaming model loaded, isModelLoaded=true")
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
            NSLog("DictationApp: [VM] ERROR loading models: %@", error.localizedDescription)
            errorMessage = "Failed to load model: \(error.localizedDescription)"
        }
        isModelLoading = false
        NSLog("DictationApp: [VM] loadModels done, isModelLoaded=%d", isModelLoaded ? 1 : 0)
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
        NSLog("DictationApp: [VM] startRecording called, state=%d isModelLoaded=%d", state == .idle ? 0 : state == .recording ? 1 : 2, isModelLoaded ? 1 : 0)
        committedText = ""
        committedSampleIndex = 0
        transcribedText = ""
        errorMessage = nil
        wakeWordMonitor.stop()
        do {
            try recorder.startRecording()
            state = .recording
            NSLog("DictationApp: [VM] state -> recording, starting streaming loop")
            let cursor = NSEvent.mouseLocation
            hud.show(state: .recording, near: cursor)
            startStreamingLoop()
        } catch {
            NSLog("DictationApp: [VM] ERROR starting recording: %@", error.localizedDescription)
            errorMessage = "Microphone error: \(error.localizedDescription)"
            if isWakeWordEnabled { wakeWordMonitor.start() }
        }
    }

    private func stopRecording() {
        NSLog("DictationApp: [VM] stopRecording called, committedText=%d chars", committedText.count)
        streamingTask?.cancel()
        streamingTask = nil
        state = .transcribing
        hud.update(state: .transcribing)

        let fallback = committedText
        NSLog("DictationApp: [VM] fallback text: '%@'", fallback.prefix(100) as CVarArg)

        // Capture samples BEFORE stopRecording clears the buffer
        let (allSamples, _) = recorder.currentSamples
        NSLog("DictationApp: [VM] captured %d samples (%.1fs) for Turbo final", allSamples.count, Double(allSamples.count) / 16000.0)

        recorder.onRecordingFinished = { [weak self] url in
            // Clean up WAV file, we use audioArrays now
            try? FileManager.default.removeItem(at: url)
            self?.finalizeTranscription(samples: allSamples, fallback: fallback)
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

                guard pendingSamples.count >= minSamples else {
                    NSLog("DictationApp: [STREAM] waiting for audio: %d samples (need %d)", pendingSamples.count, minSamples)
                    continue
                }

                let chunkSize = Int(sampleRate) * chunk
                NSLog("DictationApp: [STREAM] processing %d pending samples (chunk=%d)", pendingSamples.count, chunkSize)

                if pendingSamples.count >= chunkSize {
                    let chunkSamples = Array(pendingSamples.prefix(chunkSize))
                    let chunkText = await manager.transcribeSamples(chunkSamples)
                    NSLog("DictationApp: [STREAM] chunk transcribed: '%@'", chunkText.prefix(80) as CVarArg)

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
                    NSLog("DictationApp: [STREAM] preview transcribed: '%@'", previewText.prefix(80) as CVarArg)

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

    private func finalizeTranscription(samples: [Float], fallback: String) {
        NSLog("DictationApp: [FINAL] finalizeTranscription called, %d samples (%.1fs), fallback=%d chars", samples.count, Double(samples.count) / 16000.0, fallback.count)

        guard samples.count >= 4800 else {
            NSLog("DictationApp: [FINAL] too short (%d samples) — skipping", samples.count)
            errorMessage = "Recording too short"
            state = .idle
            hud.hide()
            if isWakeWordEnabled { wakeWordMonitor.start() }
            return
        }

        let manager = transcriptionManager
        NSLog("DictationApp: [FINAL] isFinalModelReady=%d, starting Turbo audioArrays transcription (45s timeout)", isFinalModelReady ? 1 : 0)
        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            let text: String = await withCheckedContinuation { continuation in
                let lock = NSLock()
                var resumed = false

                func finish(_ value: String) {
                    lock.lock()
                    if resumed { lock.unlock(); return }
                    resumed = true
                    lock.unlock()
                    continuation.resume(returning: value)
                }

                // Timeout (45s)
                Task {
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    NSLog("DictationApp: [FINAL] TIMED OUT after 45s — using fallback")
                    finish(fallback)
                }

                // Transcription via audioArrays with Turbo
                Task {
                    let start = ProcessInfo.processInfo.systemUptime
                    NSLog("DictationApp: [FINAL] calling transcribeSamplesFinal (Turbo audioArrays)...")
                    let result = await manager.transcribeSamplesFinal(samples)
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    NSLog("DictationApp: [FINAL] Turbo returned %d chars in %.1fs: '%@'", result.count, elapsed, String(result.prefix(100)))
                    finish(result.isEmpty ? fallback : result)
                }
            }

            NSLog("DictationApp: [FINAL] transcription race finished, result=%d chars: '%@'", text.count, String(text.prefix(100)))
            await MainActor.run {
                if text.isEmpty {
                    NSLog("DictationApp: [FINAL] no text — nothing to paste")
                    self?.errorMessage = "No speech detected"
                } else {
                    NSLog("DictationApp: [FINAL] pasting %d chars to clipboard", text.count)
                    self?.transcribedText = text
                    self?.addToHistory(text)
                    self?.copyToClipboard(text)
                    self?.pasteIntoFocusedApp()
                    self?.errorMessage = nil
                }
                self?.state = .idle
                self?.hud.hide()
                NSLog("DictationApp: [FINAL] state -> idle, done")
                if self?.isWakeWordEnabled == true { self?.wakeWordMonitor.start() }
            }
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
