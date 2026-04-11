import Foundation

enum RecordingState {
    case idle
    case recording
    case transcribing
    case correcting   // instant paste done, whisper.cpp refining in background
}
