import WhisperKit
import Foundation

// Two independent actors — one per model.
// This prevents large-v3 (slow) from blocking the small model (fast streaming).

actor StreamingTranscriber {
    private var kit: WhisperKit?

    func load() async throws {
        kit = try await WhisperKit(model: "openai_whisper-small")
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
    private var kit: WhisperKit?
    private(set) var isReady = false

    func load() async {
        do {
            kit = try await WhisperKit(model: "openai_whisper-large-v3")
            isReady = true
        } catch {
            // Non-fatal: ViewModel falls back to small model.
            NSLog("DictationApp: large-v3 failed to load — \(error)")
        }
    }

    func transcribeSamples(_ samples: [Float]) async -> String {
        guard let kit else { return "" }
        let results = await kit.transcribe(audioArrays: [samples], decodeOptions: decodingOptions)
        return TextCleaner.clean(results.compactMap { $0 }.flatMap { $0 })
    }

    func transcribeFile(url: URL) async throws -> String {
        guard let kit else { throw TranscriptionError.notLoaded }
        let results = await kit.transcribe(audioPaths: [url.path], decodeOptions: decodingOptions)
        return TextCleaner.clean(results.compactMap { $0 }.flatMap { $0 })
    }

    // Returns raw segments with timestamps — used by BatchTranscriber.
    func transcribeWithSegments(url: URL) async throws -> [TranscriptionSegment] {
        guard let kit else { throw TranscriptionError.notLoaded }
        let results = await kit.transcribe(audioPaths: [url.path], decodeOptions: decodingOptions)
        return results.compactMap { $0 }.flatMap { $0 }.flatMap { $0.segments }
    }

    private var decodingOptions: DecodingOptions {
        DecodingOptions(task: .transcribe, language: nil, temperature: 0.0,
                        usePrefillPrompt: true, detectLanguage: true, noSpeechThreshold: 0.3)
    }
}

// Thin facade — ViewModel talks to this, not to the two actors directly.
class TranscriptionManager {
    let streaming = StreamingTranscriber()
    let final_ = FinalTranscriber()

    var isFinalModelReady: Bool {
        get async { await final_.isReady }
    }

    func loadModels() async throws {
        try await streaming.load()
        Task.detached(priority: .background) { [weak self] in
            await self?.final_.load()
        }
    }

    func transcribeSamples(_ samples: [Float]) async -> String {
        await streaming.transcribe(samples)
    }

    func transcribeSamplesFinal(_ samples: [Float]) async -> String {
        if await final_.isReady {
            return await final_.transcribeSamples(samples)
        }
        return await streaming.transcribe(samples)
    }

    func transcribeFinal(url: URL) async throws -> String {
        if await final_.isReady {
            return try await final_.transcribeFile(url: url)
        }
        // large-v3 not ready — load audio manually and use small model
        let audioData = try Data(contentsOf: url)
        let samples = Self.pcmSamples(from: audioData)
        return await streaming.transcribe(samples)
    }

    // Minimal WAV PCM extractor for fallback path (16-bit LE, mono/stereo → mono).
    private static func pcmSamples(from data: Data) -> [Float] {
        guard data.count > 44 else { return [] }
        let body = data.subdata(in: 44..<data.count)
        var samples = [Float]()
        samples.reserveCapacity(body.count / 2)
        body.withUnsafeBytes { ptr in
            let shorts = ptr.bindMemory(to: Int16.self)
            for s in shorts { samples.append(Float(s) / 32768.0) }
        }
        return samples
    }
}

// MARK: - Text cleanup (shared between both actors)

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

    // Converts spoken punctuation words into symbols.
    // Longer phrases must appear before shorter ones to avoid partial matches.
    private static let punctuationCommands: [(word: String, symbol: String)] = [
        ("ponto de interrogação", "?"),
        ("ponto de exclamação", "!"),
        ("ponto e vírgula", ";"),
        ("ponto final", "."),
        ("dois pontos", ":"),
        ("nova linha", "\n"),
        ("parágrafo", "\n\n"),
        ("reticências", "..."),
        ("interrogação", "?"),
        ("exclamação", "!"),
        ("vírgula", ","),
        ("question mark", "?"),
        ("exclamation mark", "!"),
        ("semicolon", ";"),
        ("comma", ","),
        ("colon", ":"),
        ("period", "."),
        ("dot", "."),
    ]

    private static func applyPunctuationCommands(_ text: String) -> String {
        var result = text
        for (word, symbol) in punctuationCommands {
            let escaped = NSRegularExpression.escapedPattern(for: word)
            // preceded by space (or start), followed by space or end
            // Also eat any auto-punctuation the model added right after the word (e.g. "Interrogação.")
            let pattern = "(?i)(^|\\s)\(escaped)[.,!?;:]*(?=[\\s.,!?;:]|$)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: symbol)
        }
        // Capitalize first letter after sentence-ending punctuation
        result = capitalizeAfterSentenceEnd(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizeAfterSentenceEnd(_ text: String) -> String {
        var chars = Array(text)
        var capitalizeNext = false
        for i in chars.indices {
            let c = chars[i]
            if c == "." || c == "?" || c == "!" {
                capitalizeNext = true
            } else if capitalizeNext && c != " " && c != "\n" {
                chars[i] = Character(c.uppercased())
                capitalizeNext = false
            } else if c != " " && c != "\n" {
                capitalizeNext = false
            }
        }
        return String(chars)
    }

    private static func stripWhisperTokens(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<\\|[^|]*\\|>") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
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
                if result.hasSuffix(".") || result.hasSuffix(",") {
                    result = String(result.dropLast())
                }
            }
        }
        return result
    }
}

enum TranscriptionError: Error {
    case notLoaded
}
