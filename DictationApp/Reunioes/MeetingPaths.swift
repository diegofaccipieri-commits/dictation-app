import Foundation

/// On-disk locations for the Reunioes (meeting recorder) module. Prefer Dropbox so recordings can
/// be made online-only by Dropbox after capture; fall back to Application Support if Dropbox is absent.
enum MeetingPaths {
    private static let fm = FileManager.default

    static let legacyRoot: URL = {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DictationApp/Meetings", isDirectory: true)
    }()

    static let root: URL = {
        let dropbox = fm.homeDirectoryForCurrentUser.appendingPathComponent("Dropbox", isDirectory: true)
        let dir = fm.fileExists(atPath: dropbox.path)
            ? dropbox.appendingPathComponent("DictationApp/Meetings", isDirectory: true)
            : legacyRoot
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var audioDir: URL {
        let d = root.appendingPathComponent("Audio", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        migrateLegacyAudioIfNeeded(to: d)
        return d
    }

    /// Local (non-Dropbox) spool for in-progress crash-safe PCM tracks. Kept out of Dropbox so
    /// multi-GB transient files never sync; final .m4a files land in `audioDir`.
    static var spoolDir: URL {
        let d = legacyRoot.appendingPathComponent("Spool", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var isUsingDropbox: Bool {
        root.path.hasPrefix(fm.homeDirectoryForCurrentUser.appendingPathComponent("Dropbox").path)
    }

    private static func migrateLegacyAudioIfNeeded(to destination: URL) {
        guard destination.standardizedFileURL != legacyRoot.appendingPathComponent("Audio", isDirectory: true).standardizedFileURL else { return }
        let legacyAudio = legacyRoot.appendingPathComponent("Audio", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: legacyAudio, includingPropertiesForKeys: nil), !files.isEmpty else { return }
        for source in files {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.moveItem(at: source, to: target)
        }
    }

    static func stamp(from date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: date)
    }

    static func date(fromStamp stamp: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        // Trimmed copies extend the stamp ("20260716_110056_r1"); parse the date prefix.
        return f.date(from: stamp) ?? f.date(from: String(stamp.prefix(15)))
    }
}
