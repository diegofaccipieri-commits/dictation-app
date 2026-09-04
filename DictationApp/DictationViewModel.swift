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
    @Published var transcriptionLanguage: TranscriptionLanguage = TranscriptionLanguage.current
    @Published var translationMode: TranslationMode = {
        let saved = TranslationMode(rawValue: UserDefaults.standard.string(forKey: "translationMode") ?? "") ?? .off
        return TranslationMode.directModes.contains(saved) ? saved : .off
    }()
    @Published var isTranslating: Bool = false

    private let recorder = AudioRecorder()
    private let transcriptionManager = TranscriptionManager()
    let translator = ClaudeTranslator()  // shared with the manual translation workspace
    var finalTranscriber: FinalTranscriber { transcriptionManager.final_ }
    private let hud = DictationHUD()
    private let wakeWordMonitor = WakeWordMonitor()
    private var transcriptionTask: Task<Void, Never>?
    private var currentRecordingID: String?

    init() {
        if translationMode == .off {
            UserDefaults.standard.set(TranslationMode.off.rawValue, forKey: "translationMode")
        }
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
        Task { await self.translator.warmUp(mode: self.translationMode) }
    }

    /// Called on app termination: stop the whisper.cpp server so it doesn't outlive the app.
    func shutdown() {
        transcriptionManager.shutdownServer()
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

    func setTranscriptionLanguage(_ language: TranscriptionLanguage) {
        transcriptionLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: "transcriptionLanguage")
        NSLog("DictationApp: [VM] transcriptionLanguage -> %@", language.whisperCode)
    }

    func setTranslationMode(_ mode: TranslationMode) {
        translationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "translationMode")
        NSLog("DictationApp: [VM] translationMode -> %@", mode.displayName)
        Task { await translator.warmUp(mode: mode) }
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
        // Show the HUD first: AVAudioEngine start takes 100-300 ms and the user should
        // see feedback the instant the double-tap is recognized.
        let cursor = NSEvent.mouseLocation
        hud.show(state: .recording, near: cursor, translationBadge: translationMode.hudBadge)
        do {
            let recordingID = UUID().uuidString
            currentRecordingID = recordingID
            try recorder.startRecording()
            state = .recording
            DictationDiagnostics.record("recording_started", fields: ["recording_id": recordingID])
        } catch {
            hud.hide()
            currentRecordingID = nil
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
        let duration = Double(allSamples.count) / 16000.0
        NSLog("DictationApp: [VM] captured %d samples (%.1fs)", allSamples.count, duration)
        let recordingID = currentRecordingID ?? UUID().uuidString
        currentRecordingID = nil
        var fields = audioActivityFields(samples: allSamples)
        fields["recording_id"] = recordingID
        fields["sample_count"] = allSamples.count
        fields["duration_seconds"] = duration
        DictationDiagnostics.record("recording_stopped", fields: fields)
        saveRecentDictationAudio(samples: allSamples, recordingID: recordingID, fields: fields)

        // Silence guard: whisper hallucinates text ("Thank you.") on near-silent audio.
        // Real speech peaks well above 0.02 (typical dictations ~0.4).
        let peak = fields["peak"] as? Float ?? 0
        if peak < 0.02 {
            NSLog("DictationApp: [VM] audio is silent (peak %.4f) — skipping transcription", peak)
            DictationDiagnostics.record("silent_recording_skipped", fields: [
                "recording_id": recordingID,
                "peak": peak
            ])
            errorMessage = "No speech detected"
            state = .idle
            hud.hide()
            if isWakeWordEnabled { wakeWordMonitor.start() }
            recorder.stopRecording()
            return
        }

        finalizeTranscription(samples: allSamples, recordingID: recordingID)
        recorder.stopRecording()
    }

    // MARK: - Final transcription (whisper.cpp server)

    private func finalizeTranscription(samples: [Float], recordingID: String) {
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
            if Task.isCancelled { return }
            let start = ProcessInfo.processInfo.systemUptime
            NSLog("DictationApp: [FINAL] calling transcribeSamplesFinal...")
            let result = await manager.transcribeSamplesFinal(samples)
            if Task.isCancelled { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            NSLog("DictationApp: [FINAL] transcribed %d chars in %.1fs: '%@'", result.count, elapsed, String(result.prefix(100)))

            // Translation step (if enabled)
            let mode = await MainActor.run { self?.translationMode ?? .off }
            var finalText = result
            if mode != .off && !result.isEmpty {
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.isTranslating = true
                    self?.hud.showTranslating()
                }
                NSLog("DictationApp: [TRANSLATE] starting %@ for %d chars", mode.displayName, result.count)
                // Direct language pairs go through Apple's offline translation when the
                // pair is installed; anything else (or any failure) falls back to Claude.
                var translated: String?
                if #available(macOS 15.0, *), TranslationMode.directModes.contains(mode) {
                    translated = await AppleTranslator.shared.translate(result, mode: mode)
                }
                if translated == nil {
                    translated = await self?.translator.translate(result, mode: mode)
                }
                if let translated {
                    if Task.isCancelled { return }
                    finalText = translated
                    NSLog("DictationApp: [TRANSLATE] done: %d chars", translated.count)
                } else {
                    NSLog("DictationApp: [TRANSLATE] failed — using original text")
                    await MainActor.run {
                        self?.errorMessage = "Translation unavailable (timeout/error); pasted original text."
                    }
                }
                await MainActor.run { self?.isTranslating = false }
            }

            await MainActor.run {
                guard let self else { return }
                if Task.isCancelled { return }
                if finalText.isEmpty {
                    NSLog("DictationApp: [FINAL] no text — nothing to paste")
                    self.errorMessage = "No speech detected"
                    self.state = .idle
                    self.hud.hide()
                    if self.isWakeWordEnabled { self.wakeWordMonitor.start() }
                } else {
                    NSLog("DictationApp: [FINAL] pasting %d chars", finalText.count)
                    DictationDiagnostics.record("final_paste", fields: [
                        "recording_id": recordingID,
                        "text": finalText,
                        "text_length": finalText.count,
                        "translation_mode": mode.rawValue,
                        "source_text": result,
                        "source_text_length": result.count
                    ])
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
            if Task.isCancelled { return }

            // Show checkmark for 1.5 seconds after transcription or translation completes.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                if Task.isCancelled { return }
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

    private func audioActivityFields(samples: [Float]) -> [String: Any] {
        let sampleRate = 16_000
        guard !samples.isEmpty else {
            return ["rms": 0.0, "peak": 0.0, "active_seconds": 0, "active_ratio": 0.0]
        }

        var sumSquares: Double = 0
        var peak: Float = 0
        var activeSeconds = 0
        let seconds = Int(ceil(Double(samples.count) / Double(sampleRate)))

        for second in 0..<seconds {
            let start = second * sampleRate
            let end = min(samples.count, start + sampleRate)
            guard start < end else { continue }

            var bucketSquares: Double = 0
            var bucketPeak: Float = 0
            for sample in samples[start..<end] {
                let absSample = abs(sample)
                if absSample > peak { peak = absSample }
                if absSample > bucketPeak { bucketPeak = absSample }
                let value = Double(sample)
                bucketSquares += value * value
            }
            sumSquares += bucketSquares

            let bucketRMS = sqrt(bucketSquares / Double(end - start))
            if bucketRMS > 0.01 || bucketPeak > 0.06 {
                activeSeconds += 1
            }
        }

        let rms = sqrt(sumSquares / Double(samples.count))
        return [
            "rms": rms,
            "peak": peak,
            "active_seconds": activeSeconds,
            "active_ratio": Double(activeSeconds) / max(1.0, Double(seconds))
        ]
    }

    private func saveRecentDictationAudio(samples: [Float], recordingID: String, fields: [String: Any]) {
        let samplesToSave = samples
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DictationApp/RecentDictations", isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let stamp = Self.fileStamp()
                let shortID = String(recordingID.prefix(8))
                let base = "dictation_\(stamp)_\(shortID)"
                let wavURL = dir.appendingPathComponent("\(base).wav")
                let jsonURL = dir.appendingPathComponent("\(base).json")

                WhisperCppServer.saveWav(samples: samplesToSave, to: wavURL)

                var metadata = fields
                metadata["recording_id"] = recordingID
                metadata["created_at"] = ISO8601DateFormatter().string(from: Date())
                metadata["audio_file"] = wavURL.lastPathComponent
                metadata["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                metadata["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
                let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: jsonURL, options: .atomic)

                Self.pruneRecentDictationAudio(in: dir, keeping: 5)
                DictationDiagnostics.record("dictation_audio_saved", fields: [
                    "recording_id": recordingID,
                    "path": wavURL.path
                ])
            } catch {
                NSLog("DictationApp: [DIAG] failed to save recent dictation audio: %@", error.localizedDescription)
            }
        }
    }

    private nonisolated static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private nonisolated static func pruneRecentDictationAudio(in dir: URL, keeping limit: Int) {
        let fm = FileManager.default
        guard let wavs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "wav" }) else { return }

        let sorted = wavs.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }

        for url in sorted.dropFirst(limit) {
            try? fm.removeItem(at: url)
            let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
            try? fm.removeItem(at: jsonURL)
        }
    }
}
