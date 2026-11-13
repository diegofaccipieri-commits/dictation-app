import Foundation

/// On-disk locations for the Reunioes (meeting recorder) module. Prefer Dropbox so recordings can
/// be made online-only by Dropbox after capture; fall back to Application Support if Dropbox is absent.
enum MeetingPaths {
    private static let fm = FileManager.default

    static let legacyRoot: URL = {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DictationApp/Meetings", isDirectory: true)
    }()

    /// Why Dropbox was not used although it exists (nil when it is in use or absent).
    private(set) static var dropboxProblem: String?

    static let root: URL = {
        let dropbox = fm.homeDirectoryForCurrentUser.appendingPathComponent("Dropbox", isDirectory: true)
        if fm.fileExists(atPath: dropbox.path) {
            let dir = dropbox.appendingPathComponent("DictationApp/Meetings", isDirectory: true)
            // Dropbox in ~/Library/CloudStorage can refuse writes (macOS file access not granted).
            // A silent createDirectory failure here lost every recording on that Mac: probe it.
            do {
                try fm.createDirectory(at: dir.appendingPathComponent("Audio", isDirectory: true),
                                       withIntermediateDirectories: true)
                let probe = dir.appendingPathComponent(".write-test-\(UUID().uuidString)")
                try Data().write(to: probe)
                try? fm.removeItem(at: probe)
                return dir
            } catch {
                dropboxProblem = error.localizedDescription
                NSLog("DictationApp: [MEETINGS] Dropbox folder not writable (%@); saving locally", error.localizedDescription)
                DictationDiagnostics.record("meeting_dropbox_unwritable", fields: ["error": error.localizedDescription])
            }
        }
        try? fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        return legacyRoot
    }()

    static var audioDir: URL {
        let d = root.appendingPathComponent("Audio", isDirectory: true)
        do {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        } catch {
            NSLog("DictationApp: [MEETINGS] could not create %@: %@", d.path, error.localizedDescription)
        }
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

    /// True for a Dropbox online-only placeholder: an empty file whose content lives in the cloud.
    /// Plain reads (Data(contentsOf:), AVAudioFile) see 0 bytes and do not trigger the download.
    static func isPlaceholder(_ url: URL) -> Bool {
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size == 0 else { return false }
        return getxattr(url.path, "com.dropbox.placeholder", nil, 0, 0, 0) >= 0
    }

    /// Downloads an online-only Dropbox file before use. A coordinated read makes Dropbox fetch it
    /// (measured 1.4 s for 17 MB). Blocking: call off the main thread.
    static func ensureLocal(_ url: URL) {
        guard isPlaceholder(url) else { return }
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { _ in }
        if let error { NSLog("DictationApp: [MEETINGS] download of %@ failed: %@", url.lastPathComponent, error.localizedDescription) }
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
