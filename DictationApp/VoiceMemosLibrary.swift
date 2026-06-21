import Foundation
import SQLite3
import Combine

struct VoiceMemo: Identifiable, Hashable {
    let id: String          // ZPATH (unique per recording)
    let title: String
    let date: Date
    let duration: Double     // seconds
    let fileURL: URL
    var isTranscribed: Bool

    var durationText: String {
        let s = Int(duration.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f.string(from: date)
    }
}

enum VoiceMemosLibrary {
    // Core Data reference date (2001-01-01) offset from Unix epoch.
    private static let appleEpoch: TimeInterval = 978_307_200

    static var recordingsFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
    }

    static var databaseURL: URL {
        recordingsFolder.appendingPathComponent("CloudRecordings.db")
    }

    /// Default destination for transcription .txt files.
    static var outputFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Dropbox/Transcrições Voice Memos")
    }

    /// Output .txt URL for a given memo (sanitized title + date).
    static func outputURL(for memo: VoiceMemo) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let safeTitle = memo.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "\(f.string(from: memo.date)) - \(safeTitle.isEmpty ? "Memo" : safeTitle)"
        return outputFolder.appendingPathComponent(base).appendingPathExtension("txt")
    }

    enum FetchOutcome {
        case ok([VoiceMemo])
        case noAccess   // Full Disk Access not granted — Voice Memos data is unreadable.
    }

    /// Read the Voice Memos database (read-only, immutable so it never locks the app)
    /// and return memos whose audio file exists locally, newest first.
    static func fetch() -> FetchOutcome {
        let folder = recordingsFolder
        let fm = FileManager.default
        // Reading another app's Group Container requires Full Disk Access; without it the
        // file is not even readable. Distinguish that from "no memos recorded".
        guard fm.isReadableFile(atPath: databaseURL.path) else { return .noAccess }

        var db: OpaquePointer?
        // immutable=1 avoids lock contention with a running Voice Memos app.
        let uri = "file:\(databaseURL.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return .noAccess
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT ZENCRYPTEDTITLE, ZCUSTOMLABEL, ZPATH, ZDATE, ZDURATION
        FROM ZCLOUDRECORDING
        WHERE ZPATH IS NOT NULL
        ORDER BY ZDATE DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .ok([]) }
        defer { sqlite3_finalize(stmt) }

        var memos: [VoiceMemo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let title = column(stmt, 0) ?? column(stmt, 1) ?? "Sem título"
            guard let path = column(stmt, 2) else { continue }
            let zdate = sqlite3_column_double(stmt, 3)
            let duration = sqlite3_column_double(stmt, 4)

            // ZPATH may be a bare filename or a relative subpath.
            let fileURL = folder.appendingPathComponent(path)
            guard fm.fileExists(atPath: fileURL.path) else { continue }  // skip cloud-only/evicted

            let memo = VoiceMemo(
                id: path,
                title: title.isEmpty ? "Sem título" : title,
                date: Date(timeIntervalSince1970: zdate + appleEpoch),
                duration: duration,
                fileURL: fileURL,
                isTranscribed: fm.fileExists(atPath: outputURL(forTitle: title, date: Date(timeIntervalSince1970: zdate + appleEpoch)).path)
            )
            memos.append(memo)
        }
        return .ok(memos)
    }

    private static func outputURL(forTitle title: String, date: Date) -> URL {
        let memo = VoiceMemo(id: "", title: title, date: date, duration: 0,
                             fileURL: URL(fileURLWithPath: "/"), isTranscribed: false)
        return outputURL(for: memo)
    }

    private static func column(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}

final class VoiceMemosStore: ObservableObject {
    @Published var memos: [VoiceMemo] = []
    @Published var isLoading = false
    @Published var isTranscribing = false
    @Published var accessDenied = false
    @Published var status: String?

    func reload() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let outcome = VoiceMemosLibrary.fetch()
            await MainActor.run {
                switch outcome {
                case .ok(let list):
                    self.memos = list
                    self.accessDenied = false
                case .noAccess:
                    self.memos = []
                    self.accessDenied = true
                }
                self.isLoading = false
            }
        }
    }

    func markTranscribed(ids: Set<String>) {
        for i in memos.indices where ids.contains(memos[i].id) {
            memos[i].isTranscribed = true
        }
    }
}
