import AVFoundation
import Foundation
import Speech

/// A live dictation engine: audio goes in while the user speaks, text comes out as it decodes.
protocol LiveTranscriber: AnyObject, Sendable {
    /// Called on the main thread with the full transcript of the current session.
    var onText: ((String) -> Void)? { get set }
    var isReady: Bool { get }
    func begin()
    /// 16 kHz mono samples. Safe to call from the audio thread.
    func feed(_ samples: [Float])
    /// Ends the session and returns its full transcript, or nil on failure.
    func finishSession() async -> String?
    func cancel()
}

extension VoxtralServer: LiveTranscriber {
    func finishSession() async -> String? { await finish() }
}

/// Apple's on-device SpeechAnalyzer/SpeechTranscriber (macOS 26+). Runs on the Neural Engine, so it
/// does not compete with the GPU, and needs no model download beyond the system's language asset.
final class AppleSpeechEngine: LiveTranscriber, @unchecked Sendable {  // state is guarded by `lock`
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    var onText: ((String) -> Void)?
    private let lock = NSLock()
    private var ready = false
    private var locale = Locale(identifier: "pt-BR")
    private var session: AnyObject?   // AppleSpeechSession on macOS 26
    private var prepared: AnyObject?  // next session, built ahead so begin() is instant
    private(set) var lastError: String?

    var isReady: Bool { lock.withLock { ready } }

    /// Installs the language asset if needed and builds the first session.
    func start(language: TranscriptionLanguage) async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        let wanted: Locale
        switch language {
        case .en: wanted = Locale(identifier: "en-US")
        case .es: wanted = Locale(identifier: "es-ES")
        default: wanted = Locale(identifier: "pt-BR")
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            lastError = "idioma \(wanted.identifier) não suportado"
            return false
        }
        do {
            let probe = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                NSLog("DictationApp: [APPLE] installing speech asset for %@", supported.identifier)
                try await request.downloadAndInstall()
            }
            let next = try await AppleSpeechSession.make(locale: supported)
            lock.withLock {
                locale = supported
                prepared = next
                ready = true
            }
            return true
        } catch {
            lastError = error.localizedDescription
            NSLog("DictationApp: [APPLE] start failed: %@", error.localizedDescription)
            return false
        }
    }

    func stop() {
        lock.withLock {
            ready = false
            prepared = nil
        }
        cancel()
    }

    func begin() {
        guard #available(macOS 26.0, *) else { return }
        let next = lock.withLock { () -> AppleSpeechSession? in
            early.removeAll()
            let s = prepared as? AppleSpeechSession
            prepared = nil
            return s
        }
        if let next {
            activate(next)
        } else {
            // No session built ahead (first use or after a failure): audio waits in `early`.
            Task { [weak self] in
                guard let self else { return }
                if let s = try? await AppleSpeechSession.make(locale: self.lock.withLock { self.locale }) {
                    self.activate(s)
                }
            }
        }
    }

    @available(macOS 26.0, *)
    private func activate(_ s: AppleSpeechSession) {
        s.onText = { [weak self] text in
            DispatchQueue.main.async { self?.onText?(text) }
        }
        s.run()
        let held = lock.withLock { () -> [Float] in
            session = s
            defer { early.removeAll() }
            return early
        }
        if !held.isEmpty { s.feed(held) }
    }

    func feed(_ samples: [Float]) {
        guard #available(macOS 26.0, *), !samples.isEmpty else { return }
        lock.lock()
        guard let s = session as? AppleSpeechSession else {
            early.append(contentsOf: samples)
            lock.unlock()
            return
        }
        lock.unlock()
        s.feed(samples)
    }
    private var early: [Float] = []


    func finishSession() async -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        // Wait briefly for a session still being built by begin().
        for _ in 0..<40 where lock.withLock({ session == nil }) {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard let s = lock.withLock({ () -> AppleSpeechSession? in
            defer { session = nil }
            return session as? AppleSpeechSession
        }) else { return nil }
        let text = await s.finish()
        prepareNext()
        return text
    }

    func cancel() {
        guard #available(macOS 26.0, *) else { return }
        let s = lock.withLock { () -> AppleSpeechSession? in
            defer { session = nil; early.removeAll() }
            return session as? AppleSpeechSession
        }
        s?.cancel()
        prepareNext()
    }

    private func prepareNext() {
        guard #available(macOS 26.0, *) else { return }
        Task { [weak self] in
            guard let self, self.isReady else { return }
            let next = try? await AppleSpeechSession.make(locale: self.lock.withLock { self.locale })
            self.lock.withLock { if self.ready && self.prepared == nil { self.prepared = next } }
        }
    }
}

@available(macOS 26.0, *)
private final class AppleSpeechSession: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let format: AVAudioFormat
    private let converter: AVAudioConverter
    private let input: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    private var reader: Task<Void, Never>?
    var onText: ((String) -> Void)?

    private init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat) throws {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.format = format
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw NSError(domain: "AppleSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "conversor de áudio"])
        }
        self.converter = converter
        (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    }

    static func make(locale: Locale) async throws -> AppleSpeechSession {
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "AppleSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "sem formato de áudio"])
        }
        try await analyzer.prepareToAnalyze(in: format)
        return try AppleSpeechSession(analyzer: analyzer, transcriber: transcriber, format: format)
    }

    func run() {
        reader = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    let piece = String(result.text.characters)
                    let text: String = self.lock.withLock {
                        if result.isFinal {
                            self.finalized += piece
                            self.volatile = ""
                        } else {
                            self.volatile = piece
                        }
                        return self.finalized + self.volatile
                    }
                    self.onText?(text)
                }
            } catch {
                NSLog("DictationApp: [APPLE] results failed: %@", error.localizedDescription)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do { try await self.analyzer.start(inputSequence: self.input) } catch {
                NSLog("DictationApp: [APPLE] analyzer start failed: %@", error.localizedDescription)
            }
        }
    }

    func feed(_ samples: [Float]) {
        guard let buffer = convert(samples) else { return }
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    private func convert(_ samples: [Float]) -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let ratio = format.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return source
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    func finish() async -> String? {
        continuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            NSLog("DictationApp: [APPLE] finalize failed: %@", error.localizedDescription)
        }
        await reader?.value
        return lock.withLock { finalized + volatile }
    }

    func cancel() {
        continuation.finish()
        reader?.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }
}
