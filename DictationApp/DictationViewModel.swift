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
    @Published var history: [String] = (UserDefaults.standard.array(forKey: "transcriptionHistory") as? [String]) ?? []
    @Published var isWakeWordEnabled: Bool = UserDefaults.standard.bool(forKey: "wakeWordEnabled")

    private let recorder = AudioRecorder()
    private let transcriptionManager = TranscriptionManager()
    private let hud = DictationHUD()
    private let wakeWordMonitor = WakeWordMonitor()
    private var transcriptionTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?

    // Chunked streaming state:
    // Instead of re-transcribing all audio every N seconds (O(n) growth),
    // we commit fixed-size chunks and only process new audio each cycle.
    // Transcription time stays constant regardless of total recording length.
    private var committedText: String = ""
    private var committedSampleIndex: Int = 0
    private let chunkSeconds = 7  // commit a chunk every 7 seconds of audio

    init() {
        wakeWordMonitor.onWakeWord = { [weak self] in
            guard let self, self.state == .idle else { return }
            self.toggle()
        }
        Task { await self.loadModel() }
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

    private func loadModel() async {
        isModelLoading = true
        do {
            try await transcriptionManager.loadModel()
            isModelLoaded = true
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
        resetCommittedState()
        state = .idle
        hud.hide()
        if isWakeWordEnabled { wakeWordMonitor.start() }
    }

    private func startRecording() {
        resetCommittedState()
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

        // Snapshot uncommitted audio BEFORE stopping — stopRecording() clears the buffer.
        let (allSamples, sampleRate) = recorder.currentSamples
        let safeIdx = min(committedSampleIndex, allSamples.count)
        let uncommitted = Array(allSamples[safeIdx...])
        let baseText = committedText

        // Use the WAV callback only to clean up the temp file.
        recorder.onRecordingFinished = { url in
            try? FileManager.default.removeItem(at: url)
        }
        recorder.stopRecording()

        finalizeWithSamples(committed: baseText, remaining: uncommitted, sampleRate: sampleRate)
    }

    // MARK: - Streaming loop (runs during recording)
    //
    // Every 2 seconds:
    //   - If pending audio >= chunkSeconds: commit that chunk (constant transcription cost)
    //   - Otherwise: show live preview of pending audio (small window, fast)
    //
    // Committed chunks are never re-processed. Total work per cycle = O(1).

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
                let minSamples = Int(sampleRate)  // need at least 1 second
                guard pendingSamples.count >= minSamples else { continue }

                let chunkSize = Int(sampleRate) * chunk

                if pendingSamples.count >= chunkSize {
                    // Full chunk ready — commit it. Cost: always chunkSeconds of audio.
                    let chunkSamples = Array(pendingSamples.prefix(chunkSize))
                    let chunkText = await manager.transcribeSamples(chunkSamples)

                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        if !chunkText.isEmpty {
                            self.committedText = committed.isEmpty ? chunkText : committed + " " + chunkText
                        }
                        self.committedSampleIndex = safeIdx + chunkSize
                        self.transcribedText = self.committedText
                    }
                } else {
                    // Not enough for a commit — live preview of the current in-progress chunk.
                    let previewText = await manager.transcribeSamples(pendingSamples)

                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        if previewText.isEmpty {
                            self.transcribedText = committed
                        } else {
                            self.transcribedText = committed.isEmpty ? previewText : committed + " " + previewText
                        }
                    }
                }
            }
        }
    }

    // MARK: - Final transcription (only uncommitted tail)
    //
    // Because chunks are committed during recording, on stop we only transcribe
    // the remaining unprocessed audio (< chunkSeconds). Stopping feels near-instant
    // regardless of how long the user recorded.

    private func finalizeWithSamples(committed: String, remaining: [Float], sampleRate: Double) {
        let manager = transcriptionManager
        let minSamples = Int(sampleRate)  // at least 1 second

        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            var finalText = committed

            if remaining.count >= minSamples {
                let remainingText = await manager.transcribeSamples(remaining)
                if !remainingText.isEmpty {
                    finalText = finalText.isEmpty ? remainingText : finalText + " " + remainingText
                }
            }

            await MainActor.run {
                self?.resetCommittedState()
                if finalText.isEmpty {
                    self?.errorMessage = "No speech detected"
                } else {
                    self?.transcribedText = finalText
                    self?.addToHistory(finalText)
                    self?.copyToClipboard(finalText)
                    self?.pasteIntoFocusedApp()
                    self?.errorMessage = nil
                }
                self?.state = .idle
                self?.hud.hide()
                if self?.isWakeWordEnabled == true { self?.wakeWordMonitor.start() }
            }
        }
    }

    // MARK: - Helpers

    private func resetCommittedState() {
        committedText = ""
        committedSampleIndex = 0
    }

    // Bridge to read recorder samples from a detached task (hops to MainActor).
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
