import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import ApplicationServices

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

    func setTranslationMode(_ mode: TranslationMode) {
        translationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "translationMode")
        NSLog("DictationApp: [VM] translationMode -> %@", mode.displayName)
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
        case .transcribing, .correcting:
            break
        }
    }

    func cancel() {
        guard state == .recording || state == .transcribing else { return }
        streamingTask?.cancel()
        streamingTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
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

        // Use transcribedText (what user sees, includes uncommitted preview) not just committedText
        let fallback = transcribedText.isEmpty ? committedText : transcribedText
        NSLog("DictationApp: [VM] fallback text (%d chars): '%@'", fallback.count, fallback.prefix(100) as CVarArg)

        // Capture samples BEFORE stopRecording clears the buffer
        let (allSamples, _) = recorder.currentSamples
        NSLog("DictationApp: [VM] captured %d samples (%.1fs) for Turbo final", allSamples.count, Double(allSamples.count) / 16000.0)

        // Start transcription IMMEDIATELY — don't wait for recorder to finish
        finalizeTranscription(samples: allSamples, fallback: fallback)

        // Stop recorder in background (no file to clean up)
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

        // Instant paste: show streaming result immediately, correct silently when whisper.cpp finishes.
        // Skip when translation is active (fallback would be in wrong language).
        let instantFallback = (translationMode == .off && !fallback.isEmpty) ? fallback : ""
        var savedAXElement: AXUIElement? = nil
        var anchorStart: Int = -1

        if !instantFallback.isEmpty {
            // Save target element and cursor position BEFORE the paste happens.
            // After paste the cursor will be at anchorStart + instantFallback.count,
            // so we can reliably select exactly what was pasted for correction.
            let sysWide = AXUIElementCreateSystemWide()
            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(sysWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
               let focused = focusedRef {
                savedAXElement = (focused as! AXUIElement)
                var selRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(savedAXElement!, kAXSelectedTextRangeAttribute as CFString, &selRef) == .success,
                   let selVal = selRef {
                    var curRange = CFRange()
                    AXValueGetValue(selVal as! AXValue, .cfRange, &curRange)
                    anchorStart = curRange.location
                    NSLog("DictationApp: [FINAL] saved anchor: anchorStart=%d", anchorStart)
                }
            }

            copyToClipboard(instantFallback)
            pasteIntoFocusedApp()
            state = .correcting
            hud.show(state: .correcting, near: NSEvent.mouseLocation)
            NSLog("DictationApp: [FINAL] instant paste: %d chars at anchor %d — whisper.cpp correcting in background", instantFallback.count, anchorStart)
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

            // Translation step (if enabled)
            let mode = await MainActor.run { self?.translationMode ?? .off }
            var finalText = text
            if mode != .off && !text.isEmpty {
                await MainActor.run {
                    self?.isTranslating = true
                    self?.hud.updateText("Translating...")
                }
                NSLog("DictationApp: [TRANSLATE] starting %@ for %d chars", mode.displayName, text.count)
                if let translated = await self?.translator.translate(text, mode: mode) {
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
                    if instantFallback.isEmpty { self.errorMessage = "No speech detected" }
                } else if !instantFallback.isEmpty {
                    // Correct the instant-pasted text
                    self.transcribedText = finalText
                    self.addToHistory(finalText)
                    self.applyCorrection(fallback: instantFallback, finalText: finalText, element: savedAXElement, anchorStart: anchorStart)
                } else {
                    // No instant paste was done — paste normally now
                    NSLog("DictationApp: [FINAL] pasting %d chars to clipboard", finalText.count)
                    self.transcribedText = finalText
                    self.addToHistory(finalText)
                    self.copyToClipboard(finalText)
                    self.pasteIntoFocusedApp()
                    self.errorMessage = nil
                }
                self.state = .idle
                self.hud.hide()
                NSLog("DictationApp: [FINAL] state -> idle, done")
                if self.isWakeWordEnabled { self.wakeWordMonitor.start() }
            }
        }
    }

    /// Smart correction: append missing tail if whisper.cpp just got more words,
    /// or do a full replacement if the transcription differs from the start.
    private func applyCorrection(fallback: String, finalText: String, element: AXUIElement?, anchorStart: Int) {
        if finalText == fallback {
            NSLog("DictationApp: [CORRECT] identical — no correction needed")
            return
        }

        // Common case: whisper.cpp transcribed the full audio including the tail
        // that WhisperKit missed. Cursor is already at end of pasted fallback,
        // so just paste the missing suffix directly.
        if finalText.hasPrefix(fallback) {
            let tail = String(finalText.dropFirst(fallback.count))
            NSLog("DictationApp: [CORRECT] appending tail (%d chars): '%@'", tail.count, String(tail.prefix(80)))
            // Re-activate target app so Cmd+V lands in the right window.
            if let element {
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                if pid > 0, let targetApp = NSRunningApplication(processIdentifier: pid) {
                    targetApp.activate(options: .activateIgnoringOtherApps)
                }
            }
            copyToClipboard(tail)
            pasteIntoFocusedApp()
            return
        }

        // Texts differ from the beginning — full replacement via AX.
        NSLog("DictationApp: [CORRECT] full replacement: %d → %d chars", fallback.count, finalText.count)
        replaceLastPasted(count: fallback.count, with: finalText, element: element, anchorStart: anchorStart)
    }

    /// Replace the instant-pasted streaming text with the final whisper.cpp result.
    /// Uses the saved AX element and anchor position for reliable targeting.
    private func replaceLastPasted(count: Int, with newText: String, element: AXUIElement?, anchorStart: Int) {
        guard let element else {
            NSLog("DictationApp: [CORRECT] no saved element — paste appended")
            copyToClipboard(newText)
            pasteIntoFocusedApp()
            return
        }

        // Re-activate the target app so Cmd+V (fallback) goes to the right place.
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid > 0, let targetApp = NSRunningApplication(processIdentifier: pid) {
            NSLog("DictationApp: [CORRECT] activating target app (pid %d)", pid)
            targetApp.activate(options: .activateIgnoringOtherApps)
        }

        // Determine selection range: use saved anchor if available (reliable),
        // else fall back to cursor-relative (less reliable if user moved cursor).
        let location: Int
        if anchorStart >= 0 {
            location = anchorStart
            NSLog("DictationApp: [CORRECT] using anchor: loc=%d len=%d", anchorStart, count)
        } else {
            var selRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRef) == .success,
                  let selVal = selRef else {
                NSLog("DictationApp: [CORRECT] AX: no cursor — fallback paste")
                copyToClipboard(newText)
                pasteIntoFocusedApp()
                return
            }
            var curRange = CFRange()
            AXValueGetValue(selVal as! AXValue, .cfRange, &curRange)
            guard curRange.location >= count else {
                NSLog("DictationApp: [CORRECT] cursor too close to start — fallback paste")
                copyToClipboard(newText)
                pasteIntoFocusedApp()
                return
            }
            location = curRange.location - count
            NSLog("DictationApp: [CORRECT] cursor-relative: loc=%d len=%d", location, count)
        }

        // Select the range of the instant-pasted text.
        var replaceRange = CFRange(location: location, length: count)
        guard let axRange = AXValueCreate(.cfRange, &replaceRange) else {
            copyToClipboard(newText)
            pasteIntoFocusedApp()
            return
        }
        let selResult = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        NSLog("DictationApp: [CORRECT] set selection: %d", selResult.rawValue)

        // Try direct AX text write (fastest, no visual flicker).
        let writeResult = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFString)
        if writeResult == .success {
            NSLog("DictationApp: [CORRECT] AX direct write succeeded")
        } else {
            // AX write blocked — use Cmd+V to replace the selection we just set.
            NSLog("DictationApp: [CORRECT] AX write failed (%d) — using Cmd+V on selection", writeResult.rawValue)
            copyToClipboard(newText)
            pasteIntoFocusedApp()
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
