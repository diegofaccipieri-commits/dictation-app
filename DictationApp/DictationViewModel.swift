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
        // Verify the audio file exists and has content
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard fileSize > 0 else {
            errorMessage = "Recording was empty"
            state = .idle
            return
        }

        let manager = transcriptionManager
        do {
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask(priority: .userInitiated) {
                    try await manager.transcribe(url: url)
                }
                // 120 second timeout — large-v3 is slow on first run
                group.addTask {
                    try await Task.sleep(nanoseconds: 120_000_000_000)
                    throw TranscriptionError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            transcribedText = text
            copyToClipboard(text)
            state = .idle
        } catch TranscriptionError.timeout {
            errorMessage = "Timeout — model too slow. Try a shorter recording."
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
