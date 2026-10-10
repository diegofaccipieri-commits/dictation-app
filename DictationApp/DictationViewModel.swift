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
    @Published var dictationEngine: DictationEngine = DictationEngine.current
    @Published var isVoxtralReady: Bool = false
    @Published var isVoxtralLoading: Bool = false
    @Published var voxtralDownloadProgress: Double? = nil   // non-nil while the model downloads
    @Published var voxtralFailure: String? = nil   // set when this Mac failed the Voxtral self-test

    private let recorder = AudioRecorder()
    private let transcriptionManager = TranscriptionManager()
    let translator = ClaudeTranslator()  // shared with the manual translation workspace
    var finalTranscriber: FinalTranscriber { transcriptionManager.final_ }
    private let hud = DictationHUD()
    private let wakeWordMonitor = WakeWordMonitor()
    private var transcriptionTask: Task<Void, Never>?
    private var currentRecordingID: String?
    private let voxtral = VoxtralServer()
    private let apple = AppleSpeechEngine()
    @Published var isAppleReady: Bool = false
    @Published var isAppleLoading: Bool = false
    @Published var appleFailure: String? = nil
    private var voxtralSessionActive = false   // a live session (Voxtral or Apple) is open
    private var liveSession: LiveTranscriber?
    private var recordingActivity: NSObjectProtocol?
    private var keepWarmTimer: Timer?
    @Published var typesLive: Bool = UserDefaults.standard.object(forKey: "voxtralTypeLive") as? Bool ?? true
    /// Text already typed at the cursor in this session; nil when the session is not typing live.
    private var liveTypedText: String?

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
        let onLiveText: (String) -> Void = { [weak self] text in
            guard let self, self.voxtralSessionActive, self.state == .recording else { return }
            if self.liveTypedText != nil {
                self.typeLiveDelta(Self.normalizeLive(text))
            } else {
                self.hud.updateLive(text)
            }
        }
        voxtral.onText = onLiveText
        apple.onText = onLiveText
        if dictationEngine == .voxtral { startVoxtral() }
        if dictationEngine == .apple { startApple() }
        // Idle for hours, macOS pages the Voxtral weights out and the first dictation runs ~3x slower
        // than speech. A 1 s warm pass every 5 idle minutes, and right after wake, keeps it resident.
        keepWarmTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .idle else { return }
                self.voxtral.keepWarm()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.state == .idle else { return }
                self.voxtral.keepWarm()
            }
        }
        // Test hook (off unless enabled): lets a script start/stop dictation to measure Voxtral.
        if UserDefaults.standard.bool(forKey: "debugRemoteToggle") {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.diego.dictationapp.debugToggle"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.toggle() }
            }
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.diego.dictationapp.debugFeed"), object: nil, queue: .main
            ) { [weak self] note in
                guard let path = note.object as? String else { return }
                Task { @MainActor in await self?.debugFeed(wavPath: path) }
            }
        }
        Task { await self.translator.warmUp(mode: self.translationMode) }
    }

    /// Called on app termination: stop the whisper.cpp server so it doesn't outlive the app.
    func shutdown() {
        transcriptionManager.shutdownServer()
        voxtral.stop()
        apple.stop()
    }

    func setDictationEngine(_ engine: DictationEngine) {
        dictationEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: "dictationEngine")
        NSLog("DictationApp: [VM] dictationEngine -> %@", engine.rawValue)
        if engine == .voxtral {
            // Choosing Voxtral again by hand retries even after failed self-tests.
            UserDefaults.standard.removeObject(forKey: "voxtralFailures")
            voxtralFailure = nil
            startVoxtral()
        } else {
            // Voxtral paused: free the ~4.5 GB its model holds. It stays installed.
            voxtral.stop()
            isVoxtralReady = false
        }
        if engine == .apple {
            startApple()
        } else {
            apple.stop()
            isAppleReady = false
        }
    }

    private func startApple() {
        guard !isAppleLoading, !apple.isReady else { return }
        guard AppleSpeechEngine.isSupported else {
            appleFailure = "precisa do macOS 26"
            return
        }
        isAppleLoading = true
        let language = transcriptionLanguage
        Task {
            let ok = await apple.start(language: language)
            isAppleLoading = false
            isAppleReady = ok && dictationEngine == .apple
            if ok && dictationEngine != .apple { apple.stop() }
            appleFailure = ok ? nil : (apple.lastError ?? "desconhecido")
            DictationDiagnostics.record("apple_start", fields: ["ready": ok, "language": language.rawValue, "error": appleFailure ?? ""])
        }
    }

    var isVoxtralInstalled: Bool { VoxtralServer.isInstalled }

    /// Test hook: plays a 16 kHz WAV into Voxtral in real time with the recording HUD on screen,
    /// as a dictation would, and logs how long the final flush took.
    private func debugFeed(wavPath: String) async {
        let eng: LiveTranscriber = dictationEngine == .apple ? apple : voxtral
        guard eng.isReady, state == .idle, let data = FileManager.default.contents(atPath: wavPath),
              data.count > 44 else { return }
        let samples: [Float] = data.dropFirst(44).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
        }
        hud.show(state: .recording, near: NSEvent.mouseLocation)
        if !typesLive { hud.showLive() }
        eng.begin()
        voxtralSessionActive = true
        state = .recording
        let start = Date()
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1365, samples.count)
            eng.feed(Array(samples[offset..<end]))
            offset = end
            let due = start.addingTimeInterval(Double(offset) / 16000)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        voxtralSessionActive = false
        state = .transcribing
        hud.update(state: .transcribing)
        let t0 = ProcessInfo.processInfo.systemUptime
        let text = await eng.finishSession() ?? ""
        let finish = ProcessInfo.processInfo.systemUptime - t0
        state = .idle
        hud.hide()
        DictationDiagnostics.record("debug_feed", fields: [
            "audio_seconds": Double(samples.count) / 16000, "finish_seconds": finish, "text": text, "engine": dictationEngine.rawValue
        ])
    }

    func setTypesLive(_ enabled: Bool) {
        typesLive = enabled
        UserDefaults.standard.set(enabled, forKey: "voxtralTypeLive")
    }

    /// Streamed text as it should land at the cursor: no leading space, and no trailing
    /// replacement character from a multi-byte piece that has not fully arrived yet.
    nonisolated static func normalizeLive(_ text: String) -> String {
        var t = Substring(text)
        while t.last == "\u{FFFD}" { t = t.dropLast() }
        while let first = t.first, first.isWhitespace { t = t.dropFirst() }
        return String(t)
    }

    private func typeLiveDelta(_ text: String) {
        guard let typed = liveTypedText, text != typed else { return }
        if text.hasPrefix(typed) {
            KeyboardTyper.type(String(text.dropFirst(typed.count)))
            liveTypedText = text
            return
        }
        // Apple revises its latest words as it hears more; fix a short tail with backspaces.
        // Voxtral only appends, so this path is Apple's.
        let common = zip(typed, text).prefix { $0 == $1 }.count
        let erase = typed.count - common
        guard erase <= 40 else { return }
        KeyboardTyper.backspace(erase)
        KeyboardTyper.type(String(text.dropFirst(common)))
        liveTypedText = text
    }

    private func downloadVoxtral() {
        guard voxtralDownloadProgress == nil, VoxtralInstaller.isSupported else { return }
        guard VoxtralInstaller.hasDiskSpace() else {
            NSLog("DictationApp: [VM] not enough disk space for Voxtral — staying on Whisper")
            return
        }
        voxtralDownloadProgress = 0
        DictationDiagnostics.record("voxtral_download_started")
        Task {
            let ok = await VoxtralInstaller.install { [weak self] fraction in
                self?.voxtralDownloadProgress = fraction
            }
            voxtralDownloadProgress = nil
            DictationDiagnostics.record("voxtral_download_finished", fields: ["ok": ok])
            if ok && dictationEngine == .voxtral { startVoxtral() }
        }
    }

    private func startVoxtral() {
        guard !isVoxtralLoading, !voxtral.isReady else { return }
        guard VoxtralServer.isInstalled else {
            NSLog("DictationApp: [VM] Voxtral not installed — dictation uses Whisper")
            downloadVoxtral()
            return
        }
        // Self-test: READY only arrives after a warm-up inference, so a successful start proves the
        // Metal kernels run on this Mac. Two failures on the same app build stop the retries (each
        // attempt loads ~5 GB), so an unsupported Mac settles on Whisper instead of struggling.
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let failures = UserDefaults.standard.dictionary(forKey: "voxtralFailures") as? [String: Int] ?? [:]
        if (failures[build] ?? 0) >= 2 {
            voxtralFailure = UserDefaults.standard.string(forKey: "voxtralLastFailure") ?? "falhou no teste"
            NSLog("DictationApp: [VM] Voxtral failed its self-test twice on build %@ — using Whisper", build)
            return
        }
        isVoxtralLoading = true
        Task {
            let ok = await voxtral.start()
            isVoxtralLoading = false
            isVoxtralReady = ok && dictationEngine == .voxtral
            if ok && dictationEngine != .voxtral { voxtral.stop() }
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            if ok {
                UserDefaults.standard.removeObject(forKey: "voxtralFailures")
                voxtralFailure = nil
                DictationDiagnostics.record("voxtral_start", fields: ["ready": true, "os": os])
            } else {
                let reason = voxtral.lastError ?? "desconhecido"
                UserDefaults.standard.set([build: (failures[build] ?? 0) + 1], forKey: "voxtralFailures")
                UserDefaults.standard.set(reason, forKey: "voxtralLastFailure")
                voxtralFailure = reason
                DictationDiagnostics.record("voxtral_start", fields: ["ready": false, "os": os, "error": reason])
            }
        }
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
        if dictationEngine == .apple {
            apple.stop()
            isAppleReady = false
            startApple()
        }
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
        recorder.onNewSamples = nil
        recorder.stopRecording()
        endRecordingActivity()
        endVoxtralSession(cancel: true)
        state = .idle
        hud.hide()
        if isWakeWordEnabled { wakeWordMonitor.start() }
    }

    private func endRecordingActivity() {
        if let activity = recordingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            recordingActivity = nil
        }
    }

    private func endVoxtralSession(cancel: Bool) {
        liveTypedText = nil
        guard voxtralSessionActive else { return }
        voxtralSessionActive = false
        if cancel { liveSession?.cancel() }
        liveSession = nil
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
            liveTypedText = nil
            let engine: LiveTranscriber? = switch dictationEngine {
            case .voxtral: voxtral.isReady ? voxtral : nil
            case .apple: apple.isReady ? apple : nil
            case .whisper: nil
            }
            liveSession = engine
            if let server = engine {
                server.begin()
                voxtralSessionActive = true
                // Off by default: dropping silent stretches made Voxtral stop transcribing before the end.
                if dictationEngine == .voxtral, UserDefaults.standard.object(forKey: "voxtralSkipSilence") as? Bool ?? false {
                    let gate = SilenceGate()
                    recorder.onNewSamples = { server.feed(gate.process($0)) }
                } else {
                    recorder.onNewSamples = { server.feed($0) }
                }
                if typesLive && translationMode == .off {
                    liveTypedText = ""
                } else {
                    liveTypedText = nil
                    hud.showLive()
                }
            } else {
                recorder.onNewSamples = nil
            }
            try recorder.startRecording()
            // Keep App Nap from throttling the audio hand-off while the user is speaking.
            recordingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Dictation")
            state = .recording
            DictationDiagnostics.record("recording_started", fields: ["recording_id": recordingID])
        } catch {
            recorder.onNewSamples = nil
            endVoxtralSession(cancel: true)
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
        recorder.onNewSamples = nil
        endRecordingActivity()
        let useVoxtral = voxtralSessionActive
        voxtralSessionActive = false

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
            if useVoxtral { liveSession?.cancel() }
            liveSession = nil
            liveTypedText = nil
            return
        }

        finalizeTranscription(samples: allSamples, recordingID: recordingID, useVoxtral: useVoxtral)
        recorder.stopRecording()
    }

    // MARK: - Final transcription (whisper.cpp server)

    private func finalizeTranscription(samples: [Float], recordingID: String, useVoxtral: Bool = false) {
        NSLog("DictationApp: [FINAL] finalizeTranscription called, %d samples (%.1fs)", samples.count, Double(samples.count) / 16000.0)

        guard samples.count >= 4800 else {
            NSLog("DictationApp: [FINAL] too short (%d samples) — skipping", samples.count)
            errorMessage = "Recording too short"
            if useVoxtral { liveSession?.cancel() }
            liveSession = nil
            liveTypedText = nil
            state = .idle
            hud.hide()
            if isWakeWordEnabled { wakeWordMonitor.start() }
            return
        }

        let manager = transcriptionManager
        let server = liveSession
        let liveName = dictationEngine.rawValue
        liveSession = nil
        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            if Task.isCancelled { return }
            let start = ProcessInfo.processInfo.systemUptime
            var transcript = ""
            var usedEngine = "whisper"
            var voxtralSeconds = 0.0
            var voxtralRaw = ""
            if useVoxtral, let server {
                if let text = await server.finishSession() {
                    voxtralRaw = text
                    transcript = TextCleaner.cleanPlain(text)
                    usedEngine = liveName
                }
                voxtralSeconds = ProcessInfo.processInfo.systemUptime - start
                NSLog("DictationApp: [FINAL] voxtral returned %d chars in %.2fs", transcript.count, voxtralSeconds)
            }
            if transcript.isEmpty {
                if useVoxtral { NSLog("DictationApp: [FINAL] voxtral empty/failed — falling back to whisper") }
                NSLog("DictationApp: [FINAL] calling transcribeSamplesFinal...")
                transcript = await manager.transcribeSamplesFinal(samples)
                usedEngine = "whisper"
            }
            let result = transcript
            let engine = usedEngine
            let voxtralFinishSeconds = voxtralSeconds
            let voxtralFull = Self.normalizeLive(voxtralRaw)
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
                    self.liveTypedText = nil
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
                        "source_text_length": result.count,
                        "engine": engine,
                        "voxtral_finish_seconds": voxtralFinishSeconds
                    ])
                    self.transcribedText = finalText
                    self.addToHistory(finalText)
                    if let typed = self.liveTypedText {
                        // Live typing: the text is already at the cursor; just complete the tail.
                        self.liveTypedText = nil
                        if engine != "whisper", voxtralFull.hasPrefix(typed) {
                            KeyboardTyper.type(String(voxtralFull.dropFirst(typed.count)))
                        } else if engine == "apple", !typed.isEmpty {
                            self.liveTypedText = typed
                            self.typeLiveDelta(voxtralFull)
                            self.liveTypedText = nil
                        } else if typed.isEmpty {
                            self.copyToClipboard(finalText)
                            self.pasteIntoFocusedApp()
                        } else {
                            NSLog("DictationApp: [FINAL] live text diverged from final — leaving typed text as is")
                        }
                    } else {
                        self.copyToClipboard(finalText)
                        self.pasteIntoFocusedApp()
                    }
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
        if UserDefaults.standard.bool(forKey: "debugNoPaste") { return }
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
