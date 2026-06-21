import Foundation
import FluidAudio

/// A speaker turn: which speaker spoke between start and end (seconds).
struct SpeakerTurn {
    let speakerId: String
    let start: Double
    let end: Double
}

/// Wraps FluidAudio's offline (batch) speaker diarization. Models are CoreML and run
/// on-device; they are downloaded once on first use. The actor serializes access so a
/// long diarization never overlaps another.
actor DiarizationService {
    static let shared = DiarizationService()

    private var manager: OfflineDiarizerManager?

    /// Diarize mono 16 kHz Float samples into speaker turns, sorted by start time.
    func diarize(samples: [Float]) async throws -> [SpeakerTurn] {
        let mgr: OfflineDiarizerManager
        if let existing = manager {
            mgr = existing
        } else {
            let created = OfflineDiarizerManager()
            try await created.prepareModels()   // downloads/compiles CoreML models on first run
            manager = created
            mgr = created
        }

        let result = try await mgr.process(audio: samples)
        return result.segments
            .map { SpeakerTurn(speakerId: $0.speakerId,
                               start: Double($0.startTimeSeconds),
                               end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
    }
}
