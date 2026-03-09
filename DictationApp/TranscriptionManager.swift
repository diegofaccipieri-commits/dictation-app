import WhisperKit
import Foundation

// NOT @MainActor — transcription is CPU/GPU heavy and must run off the main thread
class TranscriptionManager {
    private var whisperKit: WhisperKit?

    func loadModel() async throws {
        whisperKit = try await WhisperKit(model: "openai_whisper-large-v3")
    }

    func transcribe(url: URL) async throws -> String {
        guard let whisperKit else { throw TranscriptionError.notLoaded }

        let options = DecodingOptions(
            task: .transcribe,
            language: nil,          // auto-detect per segment — allows PT/EN/ES mixing
            temperature: 0.0,
            usePrefillPrompt: true,
            detectLanguage: true,
            noSpeechThreshold: 0.3  // more sensitive (default 0.6 rejects too much)
        )

        let results = await whisperKit.transcribe(audioPaths: [url.path], decodeOptions: options)
        let text = results
            .compactMap { $0 }
            .flatMap { $0 }
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        // Return empty string for silence — not an error
        return text
    }
}

enum TranscriptionError: Error {
    case notLoaded
}
