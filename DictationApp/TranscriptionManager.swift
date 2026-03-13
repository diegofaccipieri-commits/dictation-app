import WhisperKit
import Foundation

// Actor ensures transcription calls are serialized — no concurrent WhisperKit access.
actor TranscriptionManager {

    // whisper-small: loads fast, ~5-10x real-time. Used for live preview during recording.
    private var streamingKit: WhisperKit?

    // whisper-large-v3: loads in background. Used for final accurate transcription.
    // Handles code-switching (PT/EN/ES mixed) correctly. Falls back to small if not ready.
    private var finalKit: WhisperKit?
    private(set) var isFinalModelReady = false

    func loadModels() async throws {
        // 1. Load small first — user can start recording within seconds.
        streamingKit = try await WhisperKit(model: "openai_whisper-small")

        // 2. Load large-v3 in the background. Actor re-entrance means other calls
        //    (transcribeSamples) proceed normally while this is awaiting.
        Task {
            do {
                let kit = try await WhisperKit(model: "openai_whisper-large-v3")
                self.finalKit = kit
                self.isFinalModelReady = true
            } catch {
                // Non-fatal: will use small for final transcription.
            }
        }
    }

    private var decodingOptions: DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: nil,
            temperature: 0.0,
            usePrefillPrompt: true,
            detectLanguage: true,
            noSpeechThreshold: 0.3
        )
    }

    // Fast streaming transcription using whisper-small.
    // Samples must be 16kHz (AudioRecorder resamples before buffering).
    func transcribeSamples(_ samples: [Float]) async -> String {
        guard let kit = streamingKit else { return "" }
        let results = await kit.transcribe(audioArrays: [samples], decodeOptions: decodingOptions)
        return joinSegments(results.compactMap { $0 }.flatMap { $0 })
    }

    // Final accurate transcription from raw samples (used for partial/remainder transcription).
    // Uses large-v3 if loaded, falls back to small.
    func transcribeSamplesFinal(_ samples: [Float]) async -> String {
        let kit = finalKit ?? streamingKit
        guard let kit else { return "" }
        let results = await kit.transcribe(audioArrays: [samples], decodeOptions: decodingOptions)
        return joinSegments(results.compactMap { $0 }.flatMap { $0 })
    }

    // Final accurate transcription from WAV file.
    // Uses large-v3 if loaded, falls back to small. Large-v3 handles code-switching correctly.
    func transcribeFinal(url: URL) async throws -> String {
        let kit = finalKit ?? streamingKit
        guard let kit else { throw TranscriptionError.notLoaded }
        let results = await kit.transcribe(audioPaths: [url.path], decodeOptions: decodingOptions)
        return joinSegments(results.compactMap { $0 }.flatMap { $0 })
    }

    // MARK: - Text cleanup

    private func joinSegments(_ results: [TranscriptionResult]) -> String {
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
        return stripHallucinations(joined)
    }

    private func stripWhisperTokens(_ text: String) -> String {
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

    private func stripHallucinations(_ text: String) -> String {
        var result = text
        for phrase in Self.hallucinations {
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
