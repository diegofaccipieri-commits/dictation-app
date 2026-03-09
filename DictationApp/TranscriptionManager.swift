import WhisperKit
import Foundation

// NOT @MainActor — transcription is CPU/GPU heavy and must run off the main thread
class TranscriptionManager {
    private var whisperKit: WhisperKit?

    func loadModel() async throws {
        whisperKit = try await WhisperKit(model: "openai_whisper-large-v3")
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

    // Final transcription from file — used after recording stops
    func transcribe(url: URL) async throws -> String {
        guard let whisperKit else { throw TranscriptionError.notLoaded }

        let results = await whisperKit.transcribe(audioPaths: [url.path], decodeOptions: decodingOptions)
        return results
            .compactMap { $0 }
            .flatMap { $0 }
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // Streaming transcription from raw samples — used during recording
    func transcribeSamples(_ samples: [Float]) async -> String {
        guard let whisperKit else { return "" }

        let results = await whisperKit.transcribe(audioArrays: [samples], decodeOptions: decodingOptions)
        return results
            .compactMap { $0 }
            .flatMap { $0 }
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

enum TranscriptionError: Error {
    case notLoaded
}
