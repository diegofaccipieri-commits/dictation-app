import AppKit
import Speech

// Uses NSSpeechRecognizer — the macOS-native command recognition API.
// It's purpose-built for recognizing a fixed list of words/commands,
// making it ideal for wake word detection without manual audio engine setup.
class WakeWordMonitor: NSObject, NSSpeechRecognizerDelegate {
    var onWakeWord: (() -> Void)?

    private var recognizer: NSSpeechRecognizer?
    private var isRunning = false

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        // NSSpeechRecognizer uses the system speech recognition permission (same as Siri)
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                print("WakeWord: auth status = \(status.rawValue)")
                completion(status == .authorized)
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        guard let r = NSSpeechRecognizer() else {
            print("WakeWord: NSSpeechRecognizer unavailable")
            isRunning = false
            return
        }
        r.delegate = self
        // All phonetic variants Siri/macOS might produce for "Sileide"
        r.commands = ["Sileide", "Silei", "Sileidi", "Sileidy", "Sileite", "Silaide", "Seleide"]
        r.blocksOtherRecognizers = false
        r.startListening()
        recognizer = r

        print("WakeWord: NSSpeechRecognizer started, listening for Sileide...")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        recognizer?.stopListening()
        recognizer = nil
        print("WakeWord: stopped")
    }

    func speechRecognizer(_ sender: NSSpeechRecognizer, didRecognizeCommand command: String) {
        print("WakeWord: recognized '\(command)'")
        onWakeWord?()
    }
}
