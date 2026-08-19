import Foundation

enum TranslationMode: String, CaseIterable, Identifiable {
    case off
    case lawyer = "lawyer"
    case ptEsArgentina = "pt_es_ar"
    case ptEnEveryday = "pt_en_everyday"
    case ptToEn = "pt_en"
    case ptToEs = "pt_es"
    case enToPt = "en_pt"
    case enToEs = "en_es"
    case esToPt = "es_pt"
    case esToEn = "es_en"

    var id: String { rawValue }

    static let profileModes: [TranslationMode] = [
        .lawyer,
        .ptEsArgentina,
        .ptEnEveryday,
    ]

    static let directModes: [TranslationMode] = [
        .ptToEn,
        .ptToEs,
        .enToPt,
        .enToEs,
        .esToPt,
        .esToEn,
    ]

    var displayName: String {
        switch self {
        case .off: return "Desligado"
        case .lawyer: return "LAWYER"
        case .ptEsArgentina: return "PT ↔ ES · Argentina"
        case .ptEnEveryday: return "PT ↔ EN · Dia a dia"
        case .ptToEn: return "PT → EN"
        case .ptToEs: return "PT → ES"
        case .enToPt: return "EN → PT"
        case .enToEs: return "EN → ES"
        case .esToPt: return "ES → PT"
        case .esToEn: return "ES → EN"
        }
    }

    var hudBadge: String? {
        switch self {
        case .off: return nil
        case .lawyer: return "LAWYER"
        case .ptEsArgentina: return "PT/ES AR"
        case .ptEnEveryday: return "PT/EN"
        case .ptToEn: return "PT/EN"
        case .ptToEs: return "PT/ES"
        case .enToPt: return "EN/PT"
        case .enToEs: return "EN/ES"
        case .esToPt: return "ES/PT"
        case .esToEn: return "ES/EN"
        }
    }

    var prompt: String {
        switch self {
        case .off:
            return ""
        case .lawyer:
            return """
            Produce polished Canadian legal English suitable for professional client correspondence, legal submissions, affidavits, and case notes. If the input is in Portuguese or Spanish, translate it into English. If it is already in English, rewrite it into clear legal English. Preserve the exact meaning, first-person perspective, names, dates, numbers, quotations, citations, and defined terms. Use Canadian spelling and established Canadian immigration terminology where applicable. Do not invent facts, arguments, authorities, or legal advice. Output ONLY the final English text.\n\nText:\n
            """
        case .ptEsArgentina:
            return """
            Detect whether the text is Brazilian Portuguese or Argentine Spanish and translate it into the other language. When translating into Spanish, use natural Argentine Rioplatense Spanish, including voseo when the tone calls for it, while preserving the original level of formality. When translating into Portuguese, use natural Brazilian Portuguese. Preserve names, dates, numbers, technical terms, and the speaker's tone. Prefer natural phrasing over literal word-for-word translation, and do not add information. Output ONLY the translation.\n\nText:\n
            """
        case .ptEnEveryday:
            return """
            Detect whether the text is Brazilian Portuguese or English and translate it into the other language. Use natural everyday North American English or natural Brazilian Portuguese, matching the original tone and level of formality. Prefer fluent conversational phrasing over literal word-for-word translation. Preserve names, dates, numbers, intent, and relevant terminology, and do not add information. Output ONLY the translation.\n\nText:\n
            """
        default:
            break
        }

        let (source, target) = languages
        return "Translate the following text from \(source) to \(target). Output ONLY the translation, nothing else. Do not add explanations, notes, or quotes around the text.\n\nText: "
    }

    var languages: (source: String, target: String) {
        switch self {
        case .off: return ("", "")
        case .lawyer: return ("Portuguese, Spanish, or English", "Canadian legal English")
        case .ptEsArgentina: return ("Brazilian Portuguese or Argentine Spanish", "the other language")
        case .ptEnEveryday: return ("Brazilian Portuguese or English", "the other language")
        case .ptToEn: return ("Portuguese", "English")
        case .ptToEs: return ("Portuguese", "Spanish")
        case .enToPt: return ("English", "Portuguese")
        case .enToEs: return ("English", "Spanish")
        case .esToPt: return ("Spanish", "Portuguese")
        case .esToEn: return ("Spanish", "English")
        }
    }
}
