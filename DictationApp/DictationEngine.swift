import Foundation

enum DictationEngine: String, CaseIterable, Identifiable {
    case apple
    case whisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple (ao vivo)"
        case .whisper: return "Whisper"
        }
    }

    /// Apple live dictation wherever macOS supports it (26+); Whisper elsewhere. A saved "voxtral"
    /// from earlier builds maps to the default.
    static var current: DictationEngine {
        let saved = DictationEngine(rawValue: UserDefaults.standard.string(forKey: "dictationEngine") ?? "")
        if saved == .whisper { return .whisper }
        return AppleSpeechEngine.isSupported ? .apple : .whisper
    }
}
