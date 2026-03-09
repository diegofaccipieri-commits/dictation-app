import AVFoundation
import Foundation

class AudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private(set) var recordingURL: URL?

    // Accumulated samples for streaming transcription
    private var sampleBuffer: [Float] = []
    private var sampleRate: Double = 16000
    private let sampleLock = NSLock()

    var onRecordingFinished: ((URL) -> Void)?
    var onSamplesAvailable: (([Float], Double) -> Void)?  // samples + sampleRate

    var currentSamples: ([Float], Double) {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return (sampleBuffer, sampleRate)
    }

    func startRecording() throws {
        sampleBuffer = []

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        recordingURL = tempURL

        audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.audioFile?.write(from: buffer)

            // Accumulate mono samples for streaming
            if let channelData = buffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                self.sampleLock.lock()
                self.sampleBuffer.append(contentsOf: samples)
                let allSamples = self.sampleBuffer
                let rate = self.sampleRate
                self.sampleLock.unlock()
                self.onSamplesAvailable?(allSamples, rate)
            }
        }

        try engine.start()
    }

    func stopRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        sampleBuffer = []

        if let url = recordingURL {
            onRecordingFinished?(url)
        }
    }
}
