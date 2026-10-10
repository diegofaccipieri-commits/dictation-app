import AVFoundation
import Foundation

class AudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    // Accumulated samples for streaming transcription
    private var sampleBuffer: [Float] = []
    private var sampleRate: Double = 16000
    private let sampleLock = NSLock()

    var onSamplesAvailable: (([Float], Double) -> Void)?  // samples + sampleRate
    var onNewSamples: (([Float]) -> Void)?  // only the newly captured 16kHz chunk (live streaming)
    var onRecordingInterrupted: (() -> Void)?

    private var configChangeObserver: NSObjectProtocol?
    private var isRecordingSession = false
    private var restartAttempts = 0
    // Config changes happen legitimately (default device switch, Continuity mic churn,
    // AUHAL re-selecting the input right after engine start). Restart transparently and
    // keep the accumulated samples; only give up after repeated failures in one session.
    private let maxRestartAttempts = 3

    var currentSamples: ([Float], Double) {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return (sampleBuffer, sampleRate)
    }

    private var tapCallbackCount = 0

    func startRecording() throws {
        sampleLock.lock()
        sampleBuffer = []
        sampleRate = 16000  // buffer is always resampled to 16kHz (WhisperKit requirement)
        sampleLock.unlock()
        tapCallbackCount = 0
        restartAttempts = 0
        isRecordingSession = true

        NSLog("DictationApp: [RECORDER] startRecording called")
        try startEngine()
    }

    private func startEngine() throws {
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
                let callbackSamples = self.onSamplesAvailable == nil ? nil : self.sampleBuffer
                self.sampleLock.unlock()
                if let callbackSamples {
                    self.onSamplesAvailable?(callbackSamples, 16000)
                }
                self.onNewSamples?(resampled)
            }
        }

        try engine.start()
        NSLog("DictationApp: [RECORDER] AVAudioEngine started successfully")

        // Remove any previous observer before adding a new one (prevents accumulation across sessions).
        if let prev = configChangeObserver {
            NotificationCenter.default.removeObserver(prev)
        }
        // If macOS reconfigures the audio hardware (device change, app switch with exclusive audio),
        // AVAudioEngine stops automatically. Restart transparently, keeping the captured samples.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        guard isRecordingSession else { return }

        restartAttempts += 1
        NSLog("DictationApp: [RECORDER] AVAudioEngine configuration changed — restart attempt %d/%d", restartAttempts, maxRestartAttempts)

        guard restartAttempts <= maxRestartAttempts else {
            NSLog("DictationApp: [RECORDER] too many configuration changes — finalizing with captured audio")
            onRecordingInterrupted?()
            return
        }

        teardownEngine()
        do {
            try startEngine()
            NSLog("DictationApp: [RECORDER] engine restarted, samples preserved")
        } catch {
            NSLog("DictationApp: [RECORDER] engine restart failed: %@ — finalizing with captured audio", error.localizedDescription)
            onRecordingInterrupted?()
        }
    }

    private func teardownEngine() {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
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
        isRecordingSession = false
        teardownEngine()
        sampleLock.lock()
        sampleBuffer = []
        sampleLock.unlock()
        NSLog("DictationApp: [RECORDER] stopped")
    }
}
