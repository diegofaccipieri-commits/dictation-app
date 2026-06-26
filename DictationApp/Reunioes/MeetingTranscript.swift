import Foundation
import SwiftUI

/// One transcribed utterance, attributed to a speaker. For now the attribution is track-based:
/// "Você" = microphone track, "Outros" = system-audio track. Multi-speaker diarization of the
/// "Outros" track (via FluidAudio) is a follow-up.
struct MeetingSegment: Identifiable, Hashable, Codable {
    var id = UUID()
    let speaker: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    var isMe: Bool { speaker == MeetingSegment.meLabel }
    static let meLabel = "Você"
    static let othersLabel = "Outros"
}

/// Persists a meeting transcript as a JSON sidecar next to the audio.
enum MeetingTranscriptStore {
    private static func url(for id: String) -> URL {
        MeetingPaths.audioDir.appendingPathComponent("meeting_\(id)_transcript.json")
    }
    static func save(_ segments: [MeetingSegment], id: String) {
        guard let data = try? JSONEncoder().encode(segments) else { return }
        try? data.write(to: url(for: id), options: .atomic)
    }
    static func load(id: String) -> [MeetingSegment]? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONDecoder().decode([MeetingSegment].self, from: data)
    }
}

/// Groups fine-grained whisper segments into readable paragraphs (new block on speaker change,
/// long pause, or length).
enum MeetingGrouping {
    static func cleanText(_ t: String) -> String {
        var s = t.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func paragraphs(from segs: [MeetingSegment], gap: Double = 1.5, maxChars: Int = 500) -> [MeetingSegment] {
        let sorted = segs.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return [] }
        var out: [MeetingSegment] = []
        var speaker = first.speaker
        var start = first.start
        var end = first.end
        var texts = [first.text]
        func flush() {
            let text = texts.joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(MeetingSegment(speaker: speaker, text: text, start: start, end: end)) }
        }
        for seg in sorted.dropFirst() {
            let running = texts.joined(separator: " ").count
            if seg.speaker != speaker || (seg.start - end) >= gap || running >= maxChars {
                flush()
                speaker = seg.speaker; start = seg.start; end = seg.end; texts = [seg.text]
            } else {
                end = seg.end; texts.append(seg.text)
            }
        }
        flush()
        return out
    }
}

/// Drives Whisper transcription of meetings, reusing the app's existing WhisperCppCLI + AudioDecoder.
/// Transcribes the mic and system tracks separately (labels "Você" / "Outros") and merges by time.
@MainActor
final class MeetingTranscriber: ObservableObject {
    enum Status: Equatable {
        case idle, running(String), done, failed(String)
    }

    @Published private var statusById: [String: Status] = [:]
    @Published private var segmentsById: [String: [MeetingSegment]] = [:]

    func loadExisting(_ items: [MeetingItem]) {
        for item in items where segmentsById[item.id] == nil {
            if let segs = MeetingTranscriptStore.load(id: item.id), !segs.isEmpty {
                segmentsById[item.id] = segs
                statusById[item.id] = .done
            }
        }
    }

    func status(for id: String) -> Status { statusById[id] ?? .idle }
    func segments(for id: String) -> [MeetingSegment] { segmentsById[id] ?? [] }

    func contains(id: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return segments(for: id).contains { MeetingSearch.matches($0, query: q) }
    }

    func matchCount(id: String, query: String) -> Int {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return 0 }
        return segments(for: id).filter { MeetingSearch.matches($0, query: q) }.count
    }

    func clear(id: String) {
        segmentsById.removeValue(forKey: id)
        statusById.removeValue(forKey: id)
    }

    func transcribe(_ item: MeetingItem, language: String) {
        statusById[item.id] = .running("Preparando Whisper...")
        segmentsById[item.id] = []

        Task {
            do {
                var all: [MeetingSegment] = []
                try await transcribeTrack(item.micURL, speaker: MeetingSegment.meLabel,
                                          label: "sua voz", language: language, id: item.id, into: &all)
                try await transcribeTrack(item.systemURL, speaker: MeetingSegment.othersLabel,
                                          label: "os outros", language: language, id: item.id, into: &all)

                let grouped = MeetingGrouping.paragraphs(from: all)
                segmentsById[item.id] = grouped
                statusById[item.id] = grouped.isEmpty ? .failed("Nenhuma fala reconhecida.") : .done
                MeetingTranscriptStore.save(grouped, id: item.id)
            } catch {
                statusById[item.id] = .failed(error.localizedDescription)
            }
        }
    }

    private func transcribeTrack(_ url: URL?, speaker: String, label: String,
                                 language: String, id: String, into all: inout [MeetingSegment]) async throws {
        guard let url else { return }
        statusById[id] = .running("Convertendo \(label)...")
        let wav = try await AudioDecoder.decodeToWav(url)
        defer { try? FileManager.default.removeItem(at: wav) }

        statusById[id] = .running("Transcrevendo \(label)... 0%")
        let segs = try await WhisperCppCLI.transcribeSegments(wav: wav, language: language) { [weak self] pct in
            Task { @MainActor in self?.statusById[id] = .running("Transcrevendo \(label)... \(pct)%") }
        }
        all += segs.map {
            MeetingSegment(speaker: speaker, text: MeetingGrouping.cleanText($0.text), start: $0.start, end: $0.end)
        }
    }
}

enum MeetingSearch {
    static func matches(_ segment: MeetingSegment, query: String) -> Bool {
        segment.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || segment.speaker.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
