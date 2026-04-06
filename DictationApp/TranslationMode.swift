import Foundation

enum TranslationMode: String, CaseIterable, Identifiable {
    case off
    case ptToEn = "pt_en"
    case ptToEs = "pt_es"
    case enToPt = "en_pt"
    case enToEs = "en_es"
    case esToPt = "es_pt"
    case esToEn = "es_en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .ptToEn: return "PT → EN"
        case .ptToEs: return "PT → ES"
        case .enToPt: return "EN → PT"
        case .enToEs: return "EN → ES"
        case .esToPt: return "ES → PT"
        case .esToEn: return "ES → EN"
        }
    }

    var prompt: String {
        let (source, target) = languages
        return "Translate the following text from \(source) to \(target). Output ONLY the translation, nothing else. Do not add explanations, notes, or quotes around the text.\n\nText: "
    }

    var languages: (source: String, target: String) {
        switch self {
        case .off: return ("", "")
        case .ptToEn: return ("Portuguese", "English")
        case .ptToEs: return ("Portuguese", "Spanish")
        case .enToPt: return ("English", "Portuguese")
        case .enToEs: return ("English", "Spanish")
        case .esToPt: return ("Spanish", "Portuguese")
        case .esToEn: return ("Spanish", "English")
        }
    }
}
