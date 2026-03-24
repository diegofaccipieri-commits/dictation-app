import Foundation

enum WhisperModel: String, CaseIterable, Identifiable {
    case small  = "openai_whisper-small"
    case turbo  = "openai_whisper-large-v3-v20240930_turbo_632MB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .turbo: return "Turbo"
        }
    }

    static var defaultLive:  WhisperModel { .turbo }
    static var defaultBatch: WhisperModel { .turbo }
}
