import Foundation

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case auto
    case pt
    case en
    case es

    var id: String { rawValue }

    var whisperCode: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (detectar)"
        case .pt: return "Português"
        case .en: return "English"
        case .es: return "Español"
        }
    }

    static var current: TranscriptionLanguage {
        TranscriptionLanguage(rawValue: UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "") ?? .auto
    }
}
