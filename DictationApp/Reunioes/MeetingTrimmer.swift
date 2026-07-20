import Foundation
import AVFoundation

/// Exports a trimmed copy of a meeting: cuts the same waveform selection from the mic and system
/// tracks into a new meeting pair (id "<original>_r<n>") that shows up in the list like any other,
/// can be renamed, transcribed and deleted independently of the original.
@available(macOS 15, *)
enum MeetingTrimmer {
    enum TrimError: LocalizedError {
        case selectionTooShort
        case noTracks
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .selectionTooShort: return "Seleção muito curta para recortar."
            case .noTracks: return "Nenhuma faixa de áudio para recortar."
            case .exportFailed(let reason): return "Falha ao exportar o recorte: \(reason)"
            }
        }
    }

    /// Cuts `selection` from every existing track of `item` and titles the copy automatically.
    /// Returns the new meeting id. On any failure, partial output files are removed.
    static func export(item: MeetingItem, selection: MeetingTrimLogic.Selection) async throws -> String {
        let tracks: [(URL, String)] = [(item.micURL, "mic"), (item.systemURL, "system")]
            .compactMap { url, kind in url.map { ($0, kind) } }
        guard !tracks.isEmpty else { throw TrimError.noTracks }

        let existing = Set(MeetingsStore.load().map(\.id))
        let newId = MeetingTrimLogic.trimmedId(original: item.id, existing: existing)

        var written: [URL] = []
        var cutStart: Double = 0
        var cutEnd: Double = 0
        do {
            for (source, kind) in tracks {
                let asset = AVURLAsset(url: source)
                let duration = try await asset.load(.duration).seconds
                guard let range = MeetingTrimLogic.timeRange(selection, duration: duration) else {
                    throw TrimError.selectionTooShort
                }
                cutStart = range.start
                cutEnd = range.end
                let output = MeetingPaths.audioDir.appendingPathComponent("meeting_\(newId)_\(kind).m4a")
                try? FileManager.default.removeItem(at: output)
                try await exportCut(asset: asset, start: range.start, end: range.end, to: output)
                written.append(output)
                NSLog("DictationApp: [TRIM] wrote %@ (%.1fs-%.1fs)", output.lastPathComponent, range.start, range.end)
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }

        MeetingsStore.setTitle(id: newId,
                               title: MeetingTrimLogic.trimmedTitle(base: item.displayTitle,
                                                                    start: cutStart, end: cutEnd))
        return newId
    }

    /// Passthrough keeps the original AAC packets (fast, no quality loss); if the source rejects
    /// passthrough for the cut, fall back to an AppleM4A re-encode.
    private static func exportCut(asset: AVURLAsset, start: Double, end: Double, to output: URL) async throws {
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        var lastError: Error?
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.timeRange = range
            do {
                try await session.export(to: output, as: .m4a)
                return
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: output)
            }
        }
        throw TrimError.exportFailed(lastError?.localizedDescription ?? "nenhum exportador disponível")
    }
}
