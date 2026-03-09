import SwiftUI
import AppKit

@MainActor
class DictationViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var transcribedText: String = ""
    @Published var errorMessage: String? = nil
    @Published var isModelLoaded: Bool = false
    @Published var isModelLoading: Bool = false

    private let recorder = AudioRecorder()
    private let transcriptionManager = TranscriptionManager()

    init() {
        recorder.onRecordingFinished = { [weak self] url in
            Task { await self?.transcribe(url: url) }
        }
        Task { await self.loadModel() }
    }

    private func loadModel() async {
        isModelLoading = true
        do {
            try await transcriptionManager.loadModel()
            isModelLoaded = true
        } catch {
            errorMessage = "Failed to load model: \(error.localizedDescription)"
        }
        isModelLoading = false
    }

    func toggle() {
        guard isModelLoaded else { return }
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
        let manager = transcriptionManager
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try await manager.transcribe(url: url)
            }.value
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
