import SwiftUI
import AppKit

@MainActor
class DictationViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var transcribedText: String = ""
    @Published var errorMessage: String? = nil

    private let recorder = AudioRecorder()
    private let transcriptionManager = TranscriptionManager()

    init() {
        recorder.onRecordingFinished = { [weak self] url in
            Task { await self?.transcribe(url: url) }
        }
        Task { await self.loadModel() }
    }

    private func loadModel() async {
        do {
            try await transcriptionManager.loadModel()
        } catch {
            errorMessage = "Failed to load model: \(error.localizedDescription)"
        }
    }

    func toggle() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .transcribing:
            break
        }
    }

    private func startRecording() {
        do {
            try recorder.startRecording()
            state = .recording
            errorMessage = nil
        } catch {
            errorMessage = "Microphone error: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        state = .transcribing
        recorder.stopRecording()
    }

    private func transcribe(url: URL) async {
        do {
            let text = try await transcriptionManager.transcribe(url: url)
            transcribedText = text
            copyToClipboard(text)
            state = .idle
        } catch {
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            state = .idle
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
