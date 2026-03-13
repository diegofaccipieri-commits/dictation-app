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
    private let hud = DictationHUD()
    private let wakeWordMonitor = WakeWordMonitor()
    private var transcriptionTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var finalStreamingTask: Task<Void, Never>?

    // Streaming: accumulated committed text + current chunk pointer.
    // Small model commits chunks during recording as a live preview.
    // Large-v3 replaces everything with accurate result when recording stops.
    private var committedText: String = ""
    private var committedSampleIndex: Int = 0
    private let chunkSeconds = 7

    // Progressive large-v3 tracking: processes same committed chunks in background.
    // When recording stops, only the remaining unprocessed tail needs final transcription.
    private var finalCommittedText: String = ""
    private var finalCommittedSampleIndex: Int = 0

    init() {
        wakeWordMonitor.onWakeWord = { [weak self] in
            guard let self, self.state == .idle else { return }
            self.toggle()
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
            // loadModels() returns after small model is ready.
            // Large-v3 loads in the background inside TranscriptionManager.
            try await transcriptionManager.loadModels()
            isModelLoaded = true
            // Poll until large-v3 is ready, then expose it to the UI.
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
        finalStreamingTask?.cancel()
        finalStreamingTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        recorder.onRecordingFinished = { url in try? FileManager.default.removeItem(at: url) }
        recorder.stopRecording()
        resetStreamingState()
        state = .idle
        hud.hide()
        if isWakeWordEnabled { wakeWordMonitor.start() }
    }

    private func startRecording() {
        resetStreamingState()
        transcribedText = ""
        errorMessage = nil
        wakeWordMonitor.stop()
        do {
            try recorder.startRecording()
            state = .recording
            let cursor = NSEvent.mouseLocation
            hud.show(state: .recording, near: cursor)
            startStreamingLoop()
            startFinalStreamingLoop()
        } catch {
            errorMessage = "Microphone error: \(error.localizedDescription)"
            if isWakeWordEnabled { wakeWordMonitor.start() }
        }
    }

    private func stopRecording() {
        streamingTask?.cancel()
        streamingTask = nil
        finalStreamingTask?.cancel()
        finalStreamingTask = nil
        state = .transcribing
        hud.update(state: .transcribing)

        // Snapshot streaming text now — used as fallback if final transcription times out.
        let fallback = committedText

        // Capture large-v3 progress and full sample buffer before stopping the recorder.
        let progressText = finalCommittedText
        let progressIdx = finalCommittedSampleIndex
        let (samplesAtStop, _) = recorder.currentSamples

        recorder.onRecordingFinished = { [weak self] url in
            self?.finalizeTranscription(url: url, fallback: fallback,
                                        finalProgressText: progressText,
                                        finalProgressIdx: progressIdx,
                                        samplesAtStop: samplesAtStop)
        }
        recorder.stopRecording()
        resetStreamingState()
    }

    // MARK: - Final streaming loop (large-v3, background during recording)
    //
    // Mirrors the small-model committed chunks but processes them with large-v3.
    // When recording stops, only the unprocessed tail needs final transcription.

    private func startFinalStreamingLoop() {
        let manager = transcriptionManager
        let chunk = chunkSeconds

        finalStreamingTask = Task.detached(priority: .background) { [weak self] in
            // Wait up to 60s for large-v3 to finish loading.
            var waitAttempts = 0
            while !Task.isCancelled && waitAttempts < 60 {
                if await manager.isFinalModelReady { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waitAttempts += 1
            }
            guard !Task.isCancelled else { return }
            let finalReady = await manager.isFinalModelReady
            guard finalReady else { return }
            NSLog("DictationApp: final streaming loop started — large-v3 ready")

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let (allSamples, sampleRate) = await self.samplesSnapshot()
                let smallCommittedIdx = await self.committedSampleIndex
                let finalIdx = await self.finalCommittedSampleIndex
                let finalText = await self.finalCommittedText

                let chunkSize = Int(sampleRate) * chunk
                let safeIdx = min(finalIdx, allSamples.count)
                let available = smallCommittedIdx - safeIdx

                guard available >= chunkSize else { continue }

                let endIdx = min(safeIdx + chunkSize, allSamples.count)
                let chunkSamples = Array(allSamples[safeIdx..<endIdx])
                guard chunkSamples.count >= chunkSize else { continue }

                NSLog("DictationApp: final loop — transcribing chunk [\(safeIdx)..<\(endIdx)] samples with large-v3")
                let chunkFinalText = await manager.transcribeSamplesFinal(chunkSamples)

                guard !Task.isCancelled else { break }
                await MainActor.run {
                    if !chunkFinalText.isEmpty {
                        self.finalCommittedText = finalText.isEmpty ? chunkFinalText : finalText + " " + chunkFinalText
                    }
                    self.finalCommittedSampleIndex = endIdx
                    NSLog("DictationApp: final loop committed chunk, idx=\(endIdx), text='\(chunkFinalText.prefix(40))'")
                }
            }
        }
    }

    // MARK: - Streaming loop (small model, live preview during recording)
    //
    // Commits 7-second chunks of audio as "done" — doesn't re-transcribe them.
    // Shows a rolling preview of the current in-progress chunk.
    // Text accumulates visibly as the user speaks.

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

    // MARK: - Final transcription (large-v3, full WAV file)
    //
    // Replaces the streaming preview with the accurate multilingual result.
    // Large-v3 correctly preserves code-switching (PT/EN/ES).

    private func finalizeTranscription(url: URL, fallback: String,
                                        finalProgressText: String = "",
                                        finalProgressIdx: Int = 0,
                                        samplesAtStop: [Float] = []) {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard fileSize > 0 else {
            errorMessage = "Recording was empty"
            state = .idle
            hud.hide()
            return
        }

        let manager = transcriptionManager
        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Race transcription against a 20s timeout.
            // If it times out, use the streaming preview text as result.
            let text: String = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    return nil  // timeout sentinel
                }
                group.addTask {
                    // If large-v3 pre-processed chunks during recording,
                    // only transcribe the unprocessed tail — much faster for long recordings.
                    if finalProgressIdx > 0 && finalProgressIdx < samplesAtStop.count {
                        let remainderSamples = Array(samplesAtStop[finalProgressIdx...])
                        NSLog("DictationApp: finalizing with pre-processed \(finalProgressIdx) samples, remainder=\(remainderSamples.count) samples")
                        if remainderSamples.isEmpty { return finalProgressText }
                        let remainderText = await manager.transcribeSamplesFinal(remainderSamples)
                        if finalProgressText.isEmpty { return remainderText }
                        if remainderText.isEmpty { return finalProgressText }
                        return finalProgressText + " " + remainderText
                    } else {
                        // No pre-processing — full transcription as before.
                        NSLog("DictationApp: finalizing — no pre-processed chunks, full large-v3 transcription")
                        return try? await manager.transcribeFinal(url: url)
                    }
                }
                // Take whichever finishes first
                for await result in group {
                    group.cancelAll()
                    if let result { return result }  // transcription finished in time
                    return fallback                   // timeout — use streaming preview
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

    private func resetStreamingState() {
        committedText = ""
        committedSampleIndex = 0
        finalCommittedText = ""
        finalCommittedSampleIndex = 0
    }

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
