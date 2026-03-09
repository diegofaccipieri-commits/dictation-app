import WhisperKit
import Foundation

// NOT @MainActor — transcription is CPU/GPU heavy and must run off the main thread
class TranscriptionManager {
    private var whisperKit: WhisperKit?

    func loadModel() async throws {
        whisperKit = try await WhisperKit(model: "openai_whisper-small")
    }

    func transcribe(url: URL) async throws -> String {
        guard let whisperKit else { throw TranscriptionError.notLoaded }

        let results = await whisperKit.transcribe(audioPaths: [url.path])
        let text = results
            .compactMap { $0 }
            .flatMap { $0 }
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if text.isEmpty { throw TranscriptionError.emptyResult }
        return text
    }
}

enum TranscriptionError: Error {
    case notLoaded
    case emptyResult
}
