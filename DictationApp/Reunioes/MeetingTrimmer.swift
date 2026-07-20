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
        case nothingLeft
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .selectionTooShort: return "Seleção muito curta para recortar."
            case .noTracks: return "Nenhuma faixa de áudio para recortar."
            case .nothingLeft: return "A seleção cobre a reunião inteira; nada sobraria."
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

    /// Removes `selection` from every track of `item` IN PLACE: the pieces around the cut are
    /// stitched into a composition, exported to a local temp file and swapped over the original
    /// only after every track succeeded. The transcript sidecar is deleted because its timestamps
    /// no longer match the shortened audio.
    static func removeSection(item: MeetingItem, selection: MeetingTrimLogic.Selection) async throws {
        let tracks = [item.micURL, item.systemURL].compactMap { $0 }
        guard !tracks.isEmpty else { throw TrimError.noTracks }

        var replacements: [(temp: URL, final: URL)] = []
        do {
            for source in tracks {
                let asset = AVURLAsset(url: source)
                let duration = try await asset.load(.duration).seconds
                guard let keep = MeetingTrimLogic.keepRanges(removing: selection, duration: duration) else {
                    throw TrimError.nothingLeft
                }
                let composition = AVMutableComposition()
                guard let srcTrack = try await asset.loadTracks(withMediaType: .audio).first,
                      let dstTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw TrimError.exportFailed("faixa de áudio inválida")
                }
                var cursor = CMTime.zero
                for range in keep {
                    let r = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600),
                                        end: CMTime(seconds: range.end, preferredTimescale: 600))
                    try dstTrack.insertTimeRange(r, of: srcTrack, at: cursor)
                    cursor = cursor + r.duration
                }
                // Spool dir is local (outside Dropbox), so multi-GB temps never sync.
                let temp = MeetingPaths.spoolDir.appendingPathComponent("remove-\(UUID().uuidString).m4a")
                try await exportAsset(composition, timeRange: nil, to: temp)
                replacements.append((temp, source))
            }
        } catch {
            for r in replacements { try? FileManager.default.removeItem(at: r.temp) }
            throw error
        }

        for r in replacements {
            _ = try FileManager.default.replaceItemAt(r.final, withItemAt: r.temp)
            NSLog("DictationApp: [TRIM] removed section in place: %@", r.final.lastPathComponent)
        }
        try? FileManager.default.removeItem(
            at: MeetingPaths.audioDir.appendingPathComponent("meeting_\(item.id)_transcript.json"))
    }

    /// Passthrough keeps the original AAC packets (fast, no quality loss); if the source rejects
    /// passthrough (compositions often do), fall back to an AppleM4A re-encode.
    private static func exportCut(asset: AVURLAsset, start: Double, end: Double, to output: URL) async throws {
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        try await exportAsset(asset, timeRange: range, to: output)
    }

    private static func exportAsset(_ asset: AVAsset, timeRange: CMTimeRange?, to output: URL) async throws {
        var lastError: Error?
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            if let timeRange { session.timeRange = timeRange }
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
