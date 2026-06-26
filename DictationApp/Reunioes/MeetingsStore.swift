import Foundation

/// A recorded meeting = a (mic, system) pair of audio files sharing a timestamp id.
struct MeetingItem: Identifiable, Hashable {
    let id: String
    let date: Date
    let micURL: URL?
    let systemURL: URL?
    let title: String?

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// Lists meetings by scanning the audio dir and pairing mic/system files by stamp.
enum MeetingsStore {
    private struct Metadata: Codable {
        var title: String
    }

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
                            micURL: urls.mic,
                            systemURL: urls.system,
                            title: loadTitle(id: stamp))
            }
            .sorted { $0.date > $1.date }
    }

    static func rename(_ item: MeetingItem, title: String) throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = metadataURL(id: item.id)
        if clean.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let data = try JSONEncoder().encode(Metadata(title: clean))
        try data.write(to: url, options: .atomic)
    }

    static func delete(_ item: MeetingItem) throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: MeetingPaths.audioDir, includingPropertiesForKeys: nil)
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("meeting_\(item.id)_") else { continue }
            try? fm.removeItem(at: url)
        }
    }

    private static func metadataURL(id: String) -> URL {
        MeetingPaths.audioDir.appendingPathComponent("meeting_\(id)_metadata.json")
    }

    private static func loadTitle(id: String) -> String? {
        guard let data = try? Data(contentsOf: metadataURL(id: id)),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
            return nil
        }
        return metadata.title
    }
}
