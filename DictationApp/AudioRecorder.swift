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
        sampleRate = 16000  // buffer is always resampled to 16kHz (WhisperKit requirement)

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let nativeSampleRate = format.sampleRate

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        recordingURL = tempURL

        audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.audioFile?.write(from: buffer)

            // Accumulate samples resampled to 16kHz — WhisperKit's transcribe(audioArrays:) expects 16kHz.
            // The WAV file stays at native rate (WhisperKit reads its header when using audioPaths).
            if let channelData = buffer.floatChannelData?[0] {
                let frameCount = Int(buffer.frameLength)
                let native = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
                let resampled = AudioRecorder.resampleTo16k(samples: native, fromRate: nativeSampleRate)
                self.sampleLock.lock()
                self.sampleBuffer.append(contentsOf: resampled)
                let allSamples = self.sampleBuffer
                self.sampleLock.unlock()
                self.onSamplesAvailable?(allSamples, 16000)
            }
        }

        try engine.start()
    }

    // Linear interpolation resample to 16kHz — accurate enough for speech.
    private static func resampleTo16k(samples: [Float], fromRate srcRate: Double) -> [Float] {
        guard srcRate != 16000, !samples.isEmpty else { return samples }
        let ratio = srcRate / 16000.0
        let targetCount = Int(Double(samples.count) / ratio)
        var out = [Float]()
        out.reserveCapacity(targetCount)
        for i in 0..<targetCount {
            let pos = Double(i) * ratio
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let s0 = samples[idx]
            let s1 = idx + 1 < samples.count ? samples[idx + 1] : s0
            out.append(s0 + frac * (s1 - s0))
        }
        return out
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
