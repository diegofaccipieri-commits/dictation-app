import Foundation

/// A recorded meeting = a (mic, system) pair of audio files sharing a timestamp id.
struct MeetingItem: Identifiable, Hashable {
    let id: String
    let date: Date
    let micURL: URL?
    let systemURL: URL?

    var displayTitle: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// Lists meetings by scanning the audio dir and pairing mic/system files by stamp.
enum MeetingsStore {
    static func load() -> [MeetingItem] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: MeetingPaths.audioDir, includingPropertiesForKeys: nil) else { return [] }

        var groups: [String: (mic: URL?, system: URL?)] = [:]
        for url in files where url.pathExtension == "m4a" {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("meeting_") else { continue }
            let isMic = name.hasSuffix("_mic")
            let isSys = name.hasSuffix("_system")
            guard isMic || isSys else { continue }
            let stamp = name
                .replacingOccurrences(of: "meeting_", with: "")
                .replacingOccurrences(of: "_mic", with: "")
                .replacingOccurrences(of: "_system", with: "")
            var entry = groups[stamp] ?? (nil, nil)
            if isMic { entry.mic = url } else { entry.system = url }
            groups[stamp] = entry
        }

        return groups
            .map { stamp, urls in
                MeetingItem(id: stamp,
                            date: MeetingPaths.date(fromStamp: stamp) ?? .distantPast,
                            micURL: urls.mic, systemURL: urls.system)
            }
            .sorted { $0.date > $1.date }
    }
}
