import WhisperKit
import Foundation

// Two independent actors — one per role.
// StreamingTranscriber (small) handles live preview.
// FinalTranscriber handles HD finalization + batch, with per-call model selection.

actor StreamingTranscriber {
    private var kit: WhisperKit?

    func load() async throws {
        NSLog("DictationApp: [STREAMING] loading small model...")
        kit = try await WhisperKit(model: WhisperModel.small.rawValue)
        NSLog("DictationApp: [STREAMING] small model loaded OK")
    }

    var isReady: Bool { kit != nil }

    func transcribe(_ samples: [Float]) async -> String {
        guard let kit else { return "" }
        let results = await kit.transcribe(audioArrays: [samples], decodeOptions: decodingOptions)
        return TextCleaner.clean(results.compactMap { $0 }.flatMap { $0 })
    }

    private var decodingOptions: DecodingOptions {
        DecodingOptions(task: .transcribe, language: nil, temperature: 0.0,
                        usePrefillPrompt: true, detectLanguage: true, noSpeechThreshold: 0.3)
    }
}

actor FinalTranscriber {
    // Cache of loaded models — avoids reloading the same model twice.
    private var cache: [String: WhisperKit] = [:]
    private(set) var isReady = false          // large-v3 ready
    private(set) var isBatchReady = false     // batch model ready

    func load(liveModel: WhisperModel, batchModel: WhisperModel) async {
        await ensureLoaded(liveModel)
        isReady = cache[liveModel.rawValue] != nil

        if batchModel != liveModel {
            await ensureLoaded(batchModel)
        }
        isBatchReady = cache[batchModel.rawValue] != nil || isReady
    }

    private func ensureLoaded(_ model: WhisperModel) async {
        guard cache[model.rawValue] == nil else { return }
        do {
            let kit = try await WhisperKit(WhisperKitConfig(
                model: model.rawValue,
                verbose: false
            ))
            cache[model.rawValue] = kit
            NSLog("DictationApp: \(model.displayName) loaded")
        } catch {
            NSLog("DictationApp: failed to load \(model.displayName) — \(error)")
        }
    }

    func kit(for model: WhisperModel) -> WhisperKit? {
        cache[model.rawValue]
    }

    func transcribeSamples(_ samples: [Float], model: WhisperModel) async -> String {
        guard let kit = cache[model.rawValue] else { return "" }
        let results = await kit.transcribe(audioArrays: [samples], decodeOptions: decodingOptions)
        return TextCleaner.clean(results.compactMap { $0 }.flatMap { $0 })
    }

    func transcribeFile(url: URL, model: WhisperModel) async throws -> String {
        guard let kit = cache[model.rawValue] else { throw TranscriptionError.notLoaded }
        let results = await kit.transcribe(audioPaths: [url.path], decodeOptions: decodingOptions)
        return TextCleaner.clean(results.compactMap { $0 }.flatMap { $0 })
    }

    func transcribeWithSegments(url: URL, model: WhisperModel, onProgress: ((Float) -> Void)? = nil) async throws -> [TranscriptionSegment] {
        guard let kit = cache[model.rawValue] else { throw TranscriptionError.notLoaded }
        if let onProgress {
            kit.segmentDiscoveryCallback = { segments in
                if let lastEnd = segments.last?.end { onProgress(lastEnd) }
            }
        }
        let results = await kit.transcribe(audioPaths: [url.path], decodeOptions: decodingOptions)
        kit.segmentDiscoveryCallback = nil
        return results.compactMap { $0 }.flatMap { $0 }.flatMap { $0.segments }
    }

    private var decodingOptions: DecodingOptions {
        DecodingOptions(task: .transcribe, language: nil, temperature: 0.0,
                        usePrefillPrompt: true, detectLanguage: true, noSpeechThreshold: 0.3)
    }
}

// Thin facade used by DictationViewModel.
class TranscriptionManager {
    let streaming = StreamingTranscriber()
    let final_ = FinalTranscriber()

    private var liveModel: WhisperModel = .defaultLive
    private var batchModel: WhisperModel = .defaultBatch

    var isFinalModelReady: Bool {
        get async { await final_.isReady }
    }

    func loadModels(liveModel: WhisperModel = .defaultLive, batchModel: WhisperModel = .defaultBatch) async throws {
        NSLog("DictationApp: [TM] loadModels: setting liveModel=%@ batchModel=%@", liveModel.displayName, batchModel.displayName)
        self.liveModel = liveModel
        self.batchModel = batchModel
        try await streaming.load()
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.final_.load(liveModel: liveModel, batchModel: batchModel)
            NSLog("DictationApp: [TM] final models loaded, liveModel is now %@", self.liveModel.displayName)
        }
    }

    func updateModels(liveModel: WhisperModel, batchModel: WhisperModel) async {
        NSLog("DictationApp: [TM] updateModels: setting liveModel=%@ batchModel=%@", liveModel.displayName, batchModel.displayName)
        self.liveModel = liveModel
        self.batchModel = batchModel
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.final_.load(liveModel: liveModel, batchModel: batchModel)
        }
    }

    func transcribeSamples(_ samples: [Float]) async -> String {
        await streaming.transcribe(samples)
    }

    // Dedicated Turbo WhisperKit instance for final transcription — avoids actor deadlock
    // with the streaming actor that may still have a pending transcription.
    private var finalTurboKit: WhisperKit?

    func transcribeSamplesFinal(_ samples: [Float]) async -> String {
        NSLog("DictationApp: [TRANSCRIBE] transcribeSamplesFinal: %d samples (%.1fs), Turbo audioArrays", samples.count, Double(samples.count) / 16000.0)

        // Load dedicated Turbo kit on first use — cpuAndGPU to avoid ANE hang on macOS 26
        if finalTurboKit == nil {
            NSLog("DictationApp: [TRANSCRIBE] loading dedicated Turbo model (cpuAndGPU)...")
            finalTurboKit = try? await WhisperKit(WhisperKitConfig(
                model: WhisperModel.turbo.rawValue,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndGPU
                ),
                verbose: false
            ))
            NSLog("DictationApp: [TRANSCRIBE] dedicated Turbo loaded: %@", finalTurboKit != nil ? "OK" : "FAILED")
        }
        guard let kit = finalTurboKit else {
            NSLog("DictationApp: [TRANSCRIBE] ERROR: Turbo not available")
            return ""
        }

        NSLog("DictationApp: [TRANSCRIBE] starting Turbo transcribe(audioArrays:) on %d samples...", samples.count)
        let results = await kit.transcribe(audioArrays: [samples], decodeOptions: Self.defaultDecodingOptions)
        let text = TextCleaner.clean(results.compactMap { $0 }.flatMap { $0 })
        NSLog("DictationApp: [TRANSCRIBE] Turbo done: %d chars", text.count)
        return text
    }

    // Runs transcription OUTSIDE the FinalTranscriber actor so a hung
    // transcription doesn't block subsequent calls on different models.
    func transcribeFinal(url: URL) async throws -> String {
        NSLog("DictationApp: [TRANSCRIBE] transcribeFinal called, liveModel=%@ (.rawValue=%@)", liveModel.displayName, liveModel.rawValue)

        // Try liveModel first, then try all models in priority order
        var kit = await final_.kit(for: liveModel)
        var usedModel = liveModel.displayName

        if kit == nil {
            NSLog("DictationApp: [TRANSCRIBE] liveModel %@ not in cache, trying fallbacks...", liveModel.displayName)
            for model in [WhisperModel.turbo, .small] where model != liveModel {
                kit = await final_.kit(for: model)
                if kit != nil {
                    usedModel = model.displayName
                    NSLog("DictationApp: [TRANSCRIBE] using fallback model: %@", usedModel)
                    break
                }
            }
        }

        guard let kit else {
            NSLog("DictationApp: [TRANSCRIBE] ERROR: no models available in FinalTranscriber!")
            throw TranscriptionError.notLoaded
        }

        NSLog("DictationApp: [TRANSCRIBE] starting transcription of %@ with %@", url.lastPathComponent, usedModel)
        let results = await kit.transcribe(audioPaths: [url.path], decodeOptions: Self.defaultDecodingOptions)
        let text = TextCleaner.clean(results.compactMap { $0 }.flatMap { $0 })
        NSLog("DictationApp: [TRANSCRIBE] transcribeFinal done, %d chars", text.count)
        return text
    }

    private static let defaultDecodingOptions = DecodingOptions(
        task: .transcribe, language: nil, temperature: 0.0,
        usePrefillPrompt: true, detectLanguage: true, noSpeechThreshold: 0.3
    )

    var currentLiveModel: WhisperModel { liveModel }
    var currentBatchModel: WhisperModel { batchModel }
}

// MARK: - Text cleanup

enum TextCleaner {
    static func clean(_ results: [TranscriptionResult]) -> String {
        let segments = results.flatMap { $0.segments }
        var parts: [String] = []

        for segment in segments {
            var text = stripWhisperTokens(segment.text).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let prev = parts.last, let lastChar = prev.last {
                if lastChar != "." && lastChar != "!" && lastChar != "?" {
                    text = text.prefix(1).lowercased() + text.dropFirst()
                }
            }
            parts.append(text)
        }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let dehalluced = stripHallucinations(joined)
        return applyPunctuationCommands(dehalluced)
    }

    private static func stripWhisperTokens(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<\\|[^|]*\\|>") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static let punctuationCommands: [(word: String, symbol: String)] = [
        ("ponto de interrogação", "?"), ("ponto de exclamação", "!"),
        ("ponto e vírgula", ";"),       ("ponto final", "."),
        ("dois pontos", ":"),           ("nova linha", "\n"),
        ("parágrafo", "\n\n"),          ("reticências", "..."),
        ("interrogação", "?"),          ("exclamação", "!"),
        ("vírgula", ","),               ("question mark", "?"),
        ("exclamation mark", "!"),      ("semicolon", ";"),
        ("comma", ","),                 ("colon", ":"),
        ("period", "."),                ("dot", "."),
    ]

    private static func applyPunctuationCommands(_ text: String) -> String {
        var result = text
        for (word, symbol) in punctuationCommands {
            let escaped = NSRegularExpression.escapedPattern(for: word)
            let pattern = "(?i)(^|\\s)\(escaped)[.,!?;:]*(?=[\\s.,!?;:]|$)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: symbol)
        }
        result = capitalizeAfterSentenceEnd(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizeAfterSentenceEnd(_ text: String) -> String {
        var chars = Array(text)
        var capitalizeNext = false
        for i in chars.indices {
            let c = chars[i]
            if c == "." || c == "?" || c == "!" { capitalizeNext = true }
            else if capitalizeNext && c != " " && c != "\n" {
                chars[i] = Character(c.uppercased()); capitalizeNext = false
            } else if c != " " && c != "\n" { capitalizeNext = false }
        }
        return String(chars)
    }

    private static let hallucinations: [String] = [
        "thank you", "thank you.", "thank you!", "thanks for watching",
        "thanks for watching!", "thank you for watching", "thank you for watching.",
        "thanks for listening", "please subscribe", "subtitles by",
        "transcribed by", "obrigado", "obrigada", "obrigado.", "obrigada.",
    ]

    private static func stripHallucinations(_ text: String) -> String {
        var result = text
        for phrase in hallucinations {
            let lower = result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if lower == phrase { return "" }
            if lower.hasSuffix(" " + phrase) || lower.hasSuffix(". " + phrase) {
                result = String(result.dropLast(phrase.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if result.hasSuffix(".") || result.hasSuffix(",") { result = String(result.dropLast()) }
            }
        }
        return result
    }
}

enum TranscriptionError: Error {
    case notLoaded
}
