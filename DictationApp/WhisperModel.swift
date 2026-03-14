import Foundation

enum WhisperModel: String, CaseIterable, Identifiable {
    case small  = "openai_whisper-small"
    case turbo  = "openai_whisper-large-v3-turbo"
    case large  = "openai_whisper-large-v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .turbo: return "Turbo"
        case .large: return "HD"
        }
    }

    static var defaultLive:  WhisperModel { .large }
    static var defaultBatch: WhisperModel { .turbo }
}
