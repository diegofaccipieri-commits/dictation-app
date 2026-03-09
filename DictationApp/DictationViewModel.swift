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
            self?.transcribe(url: url)
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

    private var transcriptionTask: Task<Void, Never>?

    private func transcribe(url: URL) {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard fileSize > 0 else {
            errorMessage = "Recording was empty"
            state = .idle
            return
        }

        let manager = transcriptionManager
        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let text = try await manager.transcribe(url: url)
                await MainActor.run {
                    if text.isEmpty {
                        self?.errorMessage = "No speech detected"
                    } else {
                        self?.transcribedText = text
                        self?.copyToClipboard(text)
                        self?.errorMessage = nil
                    }
                    self?.state = .idle
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage = "Transcription failed: \(error.localizedDescription)"
                    self?.state = .idle
                }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
