import Foundation
import AVFoundation
import OSLog

/// Writes one meeting audio track to a crash-tolerant spool file during recording and encodes it
/// to the final `.m4a` on stop.
///
/// The spool is **CAF with LPCM int16** in a LOCAL directory: PCM-in-CAF is readable up to the
/// point of truncation by design (no packet table to finalize), which AAC-in-CAF and bare .m4a
/// are not — the kill -9 acceptance test proved AAC-in-CAF loses everything, and the 11/jul
/// recording lost 66MB to an unfinalized moov. The spool lives outside Dropbox so multi-GB
/// transient files never sync. `recoverOrphans` turns spools from dead sessions into .m4a.
///
/// The AAC .m4a is ALSO encoded live, in parallel with the PCM spool (about 0.6% of realtime
/// CPU). On a clean stop the live file is simply closed and moved into place, so stopping is
/// instant instead of re-encoding an hour of PCM with afconvert (~1 min per track). The PCM
/// spool remains the crash-safety net: the live .m4a has no moov until closed, so after a crash
/// `recoverOrphans` discards it and remuxes the CAF.
///
/// Not internally synchronized: call `write` from a single queue (the capture queue).
@available(macOS 15, *)
final class MeetingCrashSafeTrack: @unchecked Sendable {
    private let finalURL: URL
    private let cafURL: URL
    private let liveAACURL: URL
    private let label: String
    private let log = Logger(subsystem: "com.diego.dictationapp", category: "MeetingTrack")

    private var file: AVAudioFile?
    private var liveAAC: AVAudioFile?
    private var failed = false
    private var liveAACFailed = false
    private(set) var framesWritten: Int64 = 0

    init(finalURL: URL, label: String) {
        self.finalURL = finalURL
        self.cafURL = Self.spoolURL(for: finalURL)
        self.liveAACURL = Self.liveAACURL(for: finalURL)
        self.label = label
        try? FileManager.default.removeItem(at: finalURL)
        try? FileManager.default.removeItem(at: cafURL)
        try? FileManager.default.removeItem(at: liveAACURL)
    }

    /// Local spool sibling for the live AAC encode (same base name, .m4a, in the spool dir).
    static func liveAACURL(for m4a: URL) -> URL {
        MeetingPaths.spoolDir
            .appendingPathComponent(m4a.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("m4a")
    }

    /// Local spool sibling for a final .m4a (same base name, .caf, in the spool dir).
    static func spoolURL(for m4a: URL) -> URL {
        MeetingPaths.spoolDir
            .appendingPathComponent(m4a.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("caf")
    }

    /// Final .m4a a spool file recovers into (audio dir, same base name).
    static func finalURL(forSpool caf: URL) -> URL {
        MeetingPaths.audioDir
            .appendingPathComponent(caf.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("m4a")
    }

    /// Append one buffer, lazily opening the spool as LPCM int16 from the first buffer's format.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard !failed else { return }
        if file == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: Int(buffer.format.channelCount),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            do {
                file = try AVAudioFile(forWriting: cafURL, settings: settings)
            } catch {
                failed = true
                log.error("MeetingTrack[\(self.label, privacy: .public)] open failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: Int(buffer.format.channelCount),
                AVEncoderBitRateKey: 128_000,
            ]
            do {
                liveAAC = try AVAudioFile(forWriting: liveAACURL, settings: aacSettings,
                                          commonFormat: buffer.format.commonFormat,
                                          interleaved: buffer.format.isInterleaved)
            } catch {
                liveAACFailed = true
                log.error("MeetingTrack[\(self.label, privacy: .public)] live AAC open failed, will remux on stop: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try file?.write(from: buffer)
            framesWritten += Int64(buffer.frameLength)
        } catch {
            failed = true
            log.error("MeetingTrack[\(self.label, privacy: .public)] write failed: \(error.localizedDescription, privacy: .public)")
        }
        if !liveAACFailed, let liveAAC {
            do {
                try liveAAC.write(from: buffer)
            } catch {
                liveAACFailed = true
                self.liveAAC = nil
                log.error("MeetingTrack[\(self.label, privacy: .public)] live AAC write failed, will remux on stop: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Close the CAF and save the final .m4a (live AAC, else remux), in `audioDir` or, when that
    /// refuses it, in `MeetingPaths.localAudioDir`. Returns true when a final file was saved.
    /// The CAF is deleted only after the saved .m4a is verified complete; otherwise it is KEPT so
    /// `recoverOrphans` can retry on next launch. The raw recording must never be lost.
    @discardableResult
    func finalize() async -> Bool {
        file = nil      // closes the CAF
        liveAAC = nil   // closes the live .m4a (writes the moov)
        guard FileManager.default.fileExists(atPath: cafURL.path) else {
            try? FileManager.default.removeItem(at: liveAACURL)
            return false
        }
        let expected = Self.seconds(of: cafURL)

        var saved: URL? = liveAACFailed ? nil : promoteLiveAAC()
        if saved == nil {
            try? FileManager.default.removeItem(at: liveAACURL)
            let start = Date()
            for dest in Self.destinations(for: finalURL) where await Self.remux(caf: cafURL, to: dest) {
                saved = dest
                break
            }
            NSLog("DictationApp: [MEET] %@ track remuxed via afconvert in %.1fs (ok=%d)", label, Date().timeIntervalSince(start), saved == nil ? 0 : 1)
        }
        guard let saved else {
            log.error("MeetingTrack[\(self.label, privacy: .public)] could not save anywhere; keeping CAF for recovery")
            DictationDiagnostics.record("meeting_track_save_failed", fields: ["track": label])
            return false
        }
        if saved != finalURL {
            log.error("MeetingTrack[\(self.label, privacy: .public)] audio dir refused the file; saved locally at \(saved.path, privacy: .public)")
            DictationDiagnostics.record("meeting_saved_locally", fields: ["track": label, "path": saved.path])
        }
        if Self.isComplete(saved, expectedSeconds: expected) {
            try? FileManager.default.removeItem(at: cafURL)
        } else {
            log.error("MeetingTrack[\(self.label, privacy: .public)] saved file not verified complete; keeping CAF")
        }
        return true
    }

    /// Validate the live-encoded .m4a against the PCM frame count and move it into the first
    /// destination that accepts it. Returns where it landed.
    private func promoteLiveAAC() -> URL? {
        guard framesWritten > 0,
              let probe = try? AVAudioFile(forReading: liveAACURL) else { return nil }
        let encodedFrames = probe.length
        // AAC adds encoder priming/padding; anything beyond ~1s of drift means a broken file.
        let tolerance = Int64(probe.processingFormat.sampleRate)
        guard abs(encodedFrames - framesWritten) <= tolerance else {
            log.error("MeetingTrack[\(self.label, privacy: .public)] live AAC length mismatch (\(encodedFrames) vs \(self.framesWritten)); remuxing")
            return nil
        }
        for dest in Self.destinations(for: finalURL) {
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: liveAACURL, to: dest)
                NSLog("DictationApp: [MEET] %@ track finalized from live AAC (instant)", label)
                return dest
            } catch {
                log.error("MeetingTrack[\(self.label, privacy: .public)] live AAC move to \(dest.deletingLastPathComponent().path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    /// Where a final .m4a may be saved: the given URL, then the same name in the local fallback.
    static func destinations(for m4a: URL) -> [URL] {
        let local = MeetingPaths.localAudioDir.appendingPathComponent(m4a.lastPathComponent)
        return local.standardizedFileURL == m4a.standardizedFileURL ? [m4a] : [m4a, local]
    }

    /// Playable duration of an audio file, nil when it cannot be opened or is empty.
    static func seconds(of url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0 else { return nil }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// True when `m4a` opens and lasts as long as the raw spool (1 s or 0.2% tolerance). With no
    /// readable spool to compare against, it is never considered complete, so the CAF stays.
    static func isComplete(_ m4a: URL, expectedSeconds: Double?) -> Bool {
        guard let expectedSeconds, let actual = seconds(of: m4a) else { return false }
        return abs(actual - expectedSeconds) <= max(1.0, expectedSeconds * 0.002)
    }

    // MARK: - Encode / recovery

    /// Spool CAF(PCM) → AAC .m4a via afconvert (always present on macOS; handles truncated PCM CAFs).
    static func remux(caf: URL, to m4a: URL) async -> Bool {
        try? FileManager.default.removeItem(at: m4a)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        proc.arguments = ["-f", "m4af", "-d", "aac", "-b", "128000", caf.path, m4a.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try await proc.runUntilExit()
            return proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: m4a.path)
        } catch {
            return false
        }
    }

    /// Convert leftover spool files from crashed sessions into playable .m4a files in the audio
    /// dir. Safe to call when nothing is recording. Returns how many tracks were recovered.
    @discardableResult
    static func recoverOrphans(in spoolDir: URL = MeetingPaths.spoolDir) async -> Int {
        let log = Logger(subsystem: "com.diego.dictationapp", category: "MeetingTrack")
        guard let files = try? FileManager.default.contentsOfDirectory(at: spoolDir, includingPropertiesForKeys: nil) else { return 0 }
        var recovered = 0
        // Partial live-AAC files from a crashed session have no moov and are useless; drop them.
        for stale in files where stale.pathExtension == "m4a" && stale.lastPathComponent.hasPrefix("meeting_") {
            try? FileManager.default.removeItem(at: stale)
        }
        for caf in files where caf.pathExtension == "caf" && caf.lastPathComponent.hasPrefix("meeting_") {
            let expected = seconds(of: caf)
            let candidates = destinations(for: finalURL(forSpool: caf))
            if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                // A final file already exists: delete the raw only if that file is verified
                // complete. Online-only or unverifiable files are left alone, raw kept.
                if !MeetingPaths.isPlaceholder(existing), isComplete(existing, expectedSeconds: expected) {
                    try? FileManager.default.removeItem(at: caf)
                    continue
                }
                if MeetingPaths.isPlaceholder(existing) || seconds(of: existing) != nil { continue }
            }
            var saved: URL?
            for dest in candidates where await remux(caf: caf, to: dest) {
                saved = dest
                break
            }
            if let saved {
                recovered += 1
                if isComplete(saved, expectedSeconds: expected) {
                    try? FileManager.default.removeItem(at: caf)
                }
                NSLog("DictationApp: [MEET] recovered orphaned track %@", saved.lastPathComponent)
                log.info("recovered orphaned track \(saved.path, privacy: .public)")
            } else {
                NSLog("DictationApp: [MEET] recovery FAILED for %@", caf.lastPathComponent)
                log.error("recovery FAILED for \(caf.lastPathComponent, privacy: .public); CAF kept")
            }
        }
        return recovered
    }
}

// MARK: - Shared PCM helpers for the meeting capture paths

extension AVAudioPCMBuffer {
    /// RMS across all channels (0 when not float PCM).
    var meetingRMS: Float {
        guard let channels = floatChannelData else { return 0 }
        let frames = Int(frameLength)
        let chCount = Int(format.channelCount)
        guard frames > 0, chCount > 0 else { return 0 }
        var sum: Float = 0
        for ch in 0..<chCount {
            for i in 0..<frames {
                let s = channels[ch][i]
                sum += s * s
            }
        }
        return sqrt(sum / Float(frames * chCount))
    }

    /// Clear an owned PCM buffer while retaining its format and duration.
    func meetingSilence() {
        let buffers = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }

    /// Deep copy so the buffer survives after a realtime callback returns.
    func meetingCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.count == dst.count else { return nil }
        for i in 0..<src.count {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            memcpy(d, s, Int(src[i].mDataByteSize))
            dst[i].mDataByteSize = src[i].mDataByteSize
        }
        return copy
    }
}
