import WhisperKit
import Foundation

@MainActor
class TranscriptionManager: ObservableObject {
    private var whisperKit: WhisperKit?

    func loadModel() async throws {
        whisperKit = try await WhisperKit(model: "openai/whisper-small")
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
