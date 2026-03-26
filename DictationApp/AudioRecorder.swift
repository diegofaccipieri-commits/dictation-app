import AVFoundation
import Foundation

class AudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    // Accumulated samples for streaming transcription
    private var sampleBuffer: [Float] = []
    private var sampleRate: Double = 16000
    private let sampleLock = NSLock()

    var onSamplesAvailable: (([Float], Double) -> Void)?  // samples + sampleRate
    var onRecordingInterrupted: (() -> Void)?

    private var configChangeObserver: NSObjectProtocol?

    var currentSamples: ([Float], Double) {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return (sampleBuffer, sampleRate)
    }

    private var tapCallbackCount = 0

    func startRecording() throws {
        sampleBuffer = []
        sampleRate = 16000  // buffer is always resampled to 16kHz (WhisperKit requirement)
        tapCallbackCount = 0

        NSLog("DictationApp: [RECORDER] startRecording called")

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let nativeSampleRate = format.sampleRate
        NSLog("DictationApp: [RECORDER] input format: %.0f Hz, %d channels", nativeSampleRate, format.channelCount)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            self.tapCallbackCount += 1
            if self.tapCallbackCount == 1 {
                NSLog("DictationApp: [RECORDER] first audio buffer received (%d frames)", Int(buffer.frameLength))
            } else if self.tapCallbackCount % 100 == 0 {
                self.sampleLock.lock()
                let totalSamples = self.sampleBuffer.count
                self.sampleLock.unlock()
                NSLog("DictationApp: [RECORDER] %d buffers received, %d samples accumulated (%.1fs)", self.tapCallbackCount, totalSamples, Double(totalSamples) / 16000.0)
            }

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
        NSLog("DictationApp: [RECORDER] AVAudioEngine started successfully")

        // Remove any previous observer before adding a new one (prevents accumulation across sessions).
        if let prev = configChangeObserver {
            NotificationCenter.default.removeObserver(prev)
        }
        // If macOS reconfigures the audio hardware (device change, app switch with exclusive audio),
        // AVAudioEngine stops automatically. Catch this and notify the ViewModel to finalize gracefully.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            NSLog("DictationApp: AVAudioEngine configuration changed — stopping recording")
            self?.onRecordingInterrupted?()
        }
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
        NSLog("DictationApp: [RECORDER] stopRecording called (%d buffers total)", tapCallbackCount)
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        sampleBuffer = []
        NSLog("DictationApp: [RECORDER] stopped")
    }
}
