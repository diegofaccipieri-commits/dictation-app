import AVFoundation
import Foundation

class AudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private(set) var recordingURL: URL?

    var onRecordingFinished: ((URL) -> Void)?

    func startRecording() throws {
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        recordingURL = tempURL

        audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            try? self?.audioFile?.write(from: buffer)
        }

        try engine.start()
    }

    func stopRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        if let url = recordingURL {
            onRecordingFinished?(url)
        }
    }
}
