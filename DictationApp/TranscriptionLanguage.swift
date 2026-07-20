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

    /// Compact form for segmented controls (popover Ajustes).
    var shortLabel: String {
        switch self {
        case .auto: return "Auto"
        case .pt: return "PT"
        case .en: return "EN"
        case .es: return "ES"
        }
    }

    static var current: TranscriptionLanguage {
        TranscriptionLanguage(rawValue: UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "") ?? .auto
    }
}
