import SwiftUI
import AppKit
import CoreGraphics

@MainActor
class DictationViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var transcribedText: String = ""
    @Published var errorMessage: String? = nil
    @Published var isModelLoaded: Bool = false
    @Published var isModelLoading: Bool = false

    private let recorder = AudioRecorder()
    private let transcriptionManager = TranscriptionManager()
    private var transcriptionTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?

    // Streaming: minimum samples before attempting transcription (~3 seconds at 44.1kHz)
    private let minSamplesForStreaming = 44100 * 3
    // Streaming interval in nanoseconds (5 seconds)
    private let streamingInterval: UInt64 = 5_000_000_000

    init() {
        recorder.onRecordingFinished = { [weak self] url in
            self?.finalizeTranscription(url: url)
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
            transcribedText = ""
            errorMessage = nil
            try recorder.startRecording()
            state = .recording
            startStreamingLoop()
        } catch {
            errorMessage = "Microphone error: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        streamingTask?.cancel()
        streamingTask = nil
        state = .transcribing
        recorder.stopRecording()
    }

    // MARK: - Streaming loop (runs during recording)

    private func startStreamingLoop() {
        let manager = transcriptionManager
        var lastSampleCount = 0

        streamingTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let (samples, _) = await self.currentSamplesSnapshot()
                let minSamples = await self.minSamplesForStreaming

                guard samples.count >= minSamples,
                      samples.count > lastSampleCount else { continue }
                lastSampleCount = samples.count

                let partialText = await manager.transcribeSamples(samples)
                guard !partialText.isEmpty else { continue }

                await MainActor.run {
                    self.transcribedText = partialText
                }
            }
        }
    }

    // MARK: - Final transcription (after recording stops)

    private func finalizeTranscription(url: URL) {
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
                        self?.pasteIntoFocusedApp()
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

    // MARK: - Helpers

    // Snapshot of current recorded samples via a continuation
    private func currentSamplesSnapshot() async -> ([Float], Double) {
        return await withCheckedContinuation { continuation in
            let current = recorder.currentSamples
            continuation.resume(returning: current)
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func pasteIntoFocusedApp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyV: CGKeyCode = 0x09
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
            cmdDown?.flags = .maskCommand
            cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
            cmdUp?.flags = .maskCommand
            cmdUp?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
