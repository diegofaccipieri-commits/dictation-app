import WhisperKit
import Foundation

// FinalTranscriber handles HD finalization + batch, with per-call model selection.
// Live preview via streaming was removed in v1.22.6 — whisper.cpp server handles all transcription.

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
            // Use cpuAndGPU for Turbo — ANE hangs on macOS 26.x
            let config: WhisperKitConfig
            if model == .turbo {
                config = WhisperKitConfig(
                    model: model.rawValue,
                    computeOptions: ModelComputeOptions(
                        audioEncoderCompute: .cpuAndGPU,
                        textDecoderCompute: .cpuAndGPU
                    ),
                    verbose: false
                )
            } else {
                config = WhisperKitConfig(model: model.rawValue, verbose: false)
            }
            let kit = try await WhisperKit(config)
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
    let final_ = FinalTranscriber()

    private var liveModel: WhisperModel = .defaultLive
    private var batchModel: WhisperModel = .defaultBatch

    var isFinalModelReady: Bool {
        get async {
            if serverKeeper != nil { return true }
            return await final_.isReady
        }
    }

    func loadModels(liveModel: WhisperModel = .defaultLive, batchModel: WhisperModel = .defaultBatch) async {
        NSLog("DictationApp: [TM] loadModels: liveModel=%@ batchModel=%@", liveModel.displayName, batchModel.displayName)
        self.liveModel = liveModel
        self.batchModel = batchModel
        // Load whisper.cpp server first — this is the primary transcription engine
        await loadWhisperCpp()
        // WhisperKit is not loaded up front: batch and meetings use whisper.cpp, and dictation only
        // needs it if the whisper.cpp server is missing. Loading it at launch competed for the GPU
        // during the first dictations, so it now loads on demand (see fallback below).
    }

    func updateModels(liveModel: WhisperModel, batchModel: WhisperModel) async {
        NSLog("DictationApp: [TM] updateModels: setting liveModel=%@ batchModel=%@", liveModel.displayName, batchModel.displayName)
        self.liveModel = liveModel
        self.batchModel = batchModel
    }

    // whisper.cpp server for final transcription (separate process). WhisperServerKeeper owns its
    // lifecycle: started at launch, stopped after 30 min without a dictation, restarted on demand.
    private var serverKeeper: WhisperServerKeeper?

    func loadWhisperCpp() async {
        let modelPath = NSHomeDirectory() + "/Documents/huggingface/models/whisper.cpp/ggml-large-v3-turbo-q5_0.bin"
        let serverPath = Bundle.main.resourcePath! + "/whisper-server"
        // Without this model the final pass falls back to WhisperKit, measured 6-9 s per dictation
        // on an M4 versus ~2 s here. Fetch it on first launch.
        if !Self.hasWhisperCppModel(at: modelPath) {
            guard await Self.downloadWhisperCppModel(to: modelPath) else { return }
        }
        guard FileManager.default.fileExists(atPath: serverPath) else {
            NSLog("DictationApp: [TM] whisper.cpp server not available: binary missing")
            return
        }
        let keeper = WhisperServerKeeper(modelPath: modelPath, serverPath: serverPath)
        if await keeper.ensure(timeout: 120, cleanupOrphans: true) != nil {
            serverKeeper = keeper
        } else {
            NSLog("DictationApp: [TM] whisper.cpp server failed to start")
        }
    }

    /// Called when a recording starts: brings a stopped server back while the user is speaking.
    func prewarmServer() {
        serverKeeper?.prewarm()
    }

    private static let whisperCppModelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
    private static let whisperCppModelBytes: Int64 = 574_041_195

    private static func hasWhisperCppModel(at path: String) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
        return size == whisperCppModelBytes
    }

    /// Downloads to a temporary file and moves it into place only when complete.
    private static func downloadWhisperCppModel(to path: String) async -> Bool {
        NSLog("DictationApp: [TM] whisper.cpp model missing — downloading")
        DictationDiagnostics.record("whisper_model_download_started")
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let (temp, response) = try await URLSession.shared.download(from: whisperCppModelURL)
            let size = (try FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0
            guard (response as? HTTPURLResponse)?.statusCode == 200, size == whisperCppModelBytes else {
                try? FileManager.default.removeItem(at: temp)
                throw NSError(domain: "WhisperModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "download incompleto (\(size) bytes)"])
            }
            let dest = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
            DictationDiagnostics.record("whisper_model_download_finished", fields: [
                "ok": true, "seconds": ProcessInfo.processInfo.systemUptime - start
            ])
            return true
        } catch {
            NSLog("DictationApp: [TM] whisper.cpp model download failed: %@", error.localizedDescription)
            DictationDiagnostics.record("whisper_model_download_finished", fields: ["ok": false, "error": error.localizedDescription])
            return false
        }
    }

    /// Stop the whisper.cpp server (called on app termination so no orphan survives).
    func shutdownServer() {
        serverKeeper?.shutdown()
        serverKeeper = nil
    }

    func transcribeSamplesFinal(_ samples: [Float]) async -> String {
        NSLog("DictationApp: [TRANSCRIBE] transcribeSamplesFinal: %d samples (%.1fs)", samples.count, Double(samples.count) / 16000.0)

        if let keeper = serverKeeper, let wcpp = await keeper.ensure() {
            NSLog("DictationApp: [TRANSCRIBE] using whisper.cpp server...")
            let start = ProcessInfo.processInfo.systemUptime
            let language = TranscriptionLanguage.current.whisperCode
            let text = await transcribeSamplesWithWhisperCpp(samples, language: language, server: wcpp)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            keeper.touch()
            NSLog("DictationApp: [TRANSCRIBE] whisper.cpp done: %d chars in %.1fs", text.count, elapsed)
            return text
        }

        // Fallback to WhisperKit if whisper.cpp not available
        NSLog("DictationApp: [TRANSCRIBE] whisper.cpp not loaded, falling back to WhisperKit...")
        await final_.load(liveModel: liveModel, batchModel: liveModel)
        guard let kit = await final_.kit(for: liveModel) else {
            NSLog("DictationApp: [TRANSCRIBE] ERROR: no model available")
            return ""
        }
        let results = await kit.transcribe(audioArrays: [samples], decodeOptions: Self.defaultDecodingOptions)
        return TextCleaner.clean(results.compactMap { $0 }.flatMap { $0 })
    }

    private func transcribeSamplesWithWhisperCpp(_ samples: [Float], language: String, server: WhisperCppServer) async -> String {
        let sampleRate = 16_000
        if samples.count <= sampleRate * 60 {
            return await server.transcribe(samples: samples, language: language)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return await transcribeChunksWithWhisperCpp(samples, language: language, server: server,
                                                   chunkSeconds: 30, overlapSeconds: 1, minTailSeconds: 8)
    }

    private func transcribeChunksWithWhisperCpp(_ samples: [Float], language: String, server: WhisperCppServer,
                                                chunkSeconds: Int, overlapSeconds: Int, minTailSeconds: Int) async -> String {
        let sampleRate = 16_000
        let chunkSamples = sampleRate * chunkSeconds
        let overlapSamples = sampleRate * overlapSeconds
        let minTailSamples = sampleRate * minTailSeconds
        var parts: [String] = []
        var start = 0
        var index = 1
        let stepSamples = chunkSamples - overlapSamples
        let total = Int(ceil(Double(max(0, samples.count - overlapSamples)) / Double(stepSamples)))
        while start < samples.count {
            if Task.isCancelled { break }
            var end = min(samples.count, start + chunkSamples)
            if samples.count - end < minTailSamples {
                end = samples.count
            }
            let chunk = Array(samples[start..<end])
            NSLog("DictationApp: [TRANSCRIBE] whisper.cpp chunk %d/%d: %.1fs",
                  index, total, Double(chunk.count) / Double(sampleRate))
            let text = await server.transcribe(samples: chunk, language: language)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if Task.isCancelled { break }
            if !text.isEmpty {
                parts.append(text)
            }
            if end == samples.count { break }
            start += stepSamples
            index += 1
        }
        return WhisperCppServer.joinTranscriptionParts(parts)
    }

    // Runs transcription OUTSIDE the FinalTranscriber actor so a hung
    // transcription doesn't block subsequent calls on different models.
    func transcribeFinal(url: URL) async throws -> String {
        NSLog("DictationApp: [TRANSCRIBE] transcribeFinal called, liveModel=%@ (.rawValue=%@)", liveModel.displayName, liveModel.rawValue)

        await final_.load(liveModel: liveModel, batchModel: liveModel)
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
        let joined = smartJoin(parts).trimmingCharacters(in: .whitespaces)
        let merged = WhisperCppServer.mergeFragmentedWords(joined)
        let dehalluced = stripHallucinations(merged)
        return applyPunctuationCommands(dehalluced)
    }

    /// Cleanup for engines that already return one plain string (Apple live dictation): no Whisper token or
    /// hallucination stripping, just spoken punctuation commands and capitalization.
    static func cleanPlain(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return applyPunctuationCommands(collapsed.trimmingCharacters(in: .whitespacesAndNewlines))
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

    // Pre-compiled regexes — built once, reused on every transcription.
    private static let punctuationRegexes: [(regex: NSRegularExpression, symbol: String)] = {
        punctuationCommands.compactMap { (word, symbol) in
            let escaped = NSRegularExpression.escapedPattern(for: word)
            let pattern = "(?i)(^|\\s)\(escaped)[.,!?;:]*(?=[\\s.,!?;:]|$)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, symbol)
        }
    }()

    private static func applyPunctuationCommands(_ text: String) -> String {
        var result = text
        for (regex, symbol) in punctuationRegexes {
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

    // Phrases Whisper hallucinates when audio is silent/noisy at the end
    private static let hallucinations: [String] = [
        // English
        "thank you", "thank you.", "thank you!", "thank you so much",
        "thanks for watching", "thanks for watching!", "thank you for watching",
        "thank you for watching.", "thanks for listening", "thanks for listening.",
        "please subscribe", "subtitles by", "transcribed by",
        "like and subscribe", "see you next time", "bye bye", "bye.",
        "ok", "ok.", "okay", "okay.", "you're welcome",
        "i'm sorry", "sorry", "yes", "yes.", "no", "no.",
        "hmm", "hmm.", "uh", "um", "so",
        // Portuguese
        "obrigado", "obrigada", "obrigado.", "obrigada.",
        "tchau", "tchau.", "até logo", "até mais",
        "tá bom", "tá.", "né", "então é isso",
        "legendas por", "transcrição por",
        // Spanish
        "gracias", "gracias.", "adiós", "hasta luego",
        "subtítulos por", "ok gracias",
    ]

    /// Join segment parts with spaces. Actual fragment merging is handled
    /// by mergeFragmentedWords (spell-checker based) after joining.
    private static func smartJoin(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func stripHallucinations(_ text: String) -> String {
        var result = text
        // Remove CJK characters (Japanese/Chinese/Korean hallucinations)
        result = stripCJK(result)

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // If the entire text is a hallucination, return empty
        for phrase in hallucinations {
            if lower == phrase { return "" }
        }

        // Strip hallucinations from the end (Whisper adds them when audio trails off)
        var changed = true
        while changed {
            changed = false
            let currentLower = result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            for phrase in hallucinations {
                if currentLower.hasSuffix(" " + phrase) || currentLower.hasSuffix(". " + phrase) || currentLower.hasSuffix(", " + phrase) {
                    result = String(result.dropLast(phrase.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Clean trailing punctuation
                    while result.hasSuffix(".") || result.hasSuffix(",") || result.hasSuffix(" ") {
                        result = String(result.dropLast())
                    }
                    changed = true
                    NSLog("DictationApp: [CLEAN] stripped trailing hallucination: '%@'", phrase)
                    break
                }
            }
        }
        return result
    }

    private static func stripCJK(_ text: String) -> String {
        // Remove CJK Unified Ideographs, Hiragana, Katakana, Hangul, and fullwidth punctuation
        guard let regex = try? NSRegularExpression(
            pattern: "[\\u3000-\\u303F\\u3040-\\u309F\\u30A0-\\u30FF\\u4E00-\\u9FFF\\uAC00-\\uD7AF\\uFF00-\\uFFEF]+"
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleaned != text {
            NSLog("DictationApp: [CLEAN] stripped CJK hallucination: '%@' → '%@'", String(text.prefix(60)), String(cleaned.prefix(60)))
        }
        return cleaned
    }
}

enum TranscriptionError: Error {
    case notLoaded
}
