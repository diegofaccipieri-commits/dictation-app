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

        let results = try await whisperKit.transcribe(audioPath: url.path)
        return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

enum TranscriptionError: Error {
    case notLoaded
}
