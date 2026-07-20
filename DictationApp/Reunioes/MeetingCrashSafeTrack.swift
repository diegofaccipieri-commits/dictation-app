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
/// Not internally synchronized: call `write` from a single queue (the capture queue).
@available(macOS 15, *)
final class MeetingCrashSafeTrack: @unchecked Sendable {
    private let finalURL: URL
    private let cafURL: URL
    private let label: String
    private let log = Logger(subsystem: "com.diego.dictationapp", category: "MeetingTrack")

    private var file: AVAudioFile?
    private var failed = false
    private(set) var framesWritten: Int64 = 0

    init(finalURL: URL, label: String) {
        self.finalURL = finalURL
        self.cafURL = Self.spoolURL(for: finalURL)
        self.label = label
        try? FileManager.default.removeItem(at: finalURL)
        try? FileManager.default.removeItem(at: cafURL)
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
        }
        do {
            try file?.write(from: buffer)
            framesWritten += Int64(buffer.frameLength)
        } catch {
            failed = true
            log.error("MeetingTrack[\(self.label, privacy: .public)] write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Close the CAF and remux it to the final .m4a. Returns true on success.
    /// On remux failure the CAF is KEPT so `recoverOrphans` can retry on next launch.
    @discardableResult
    func finalize() async -> Bool {
        file = nil   // closes the AVAudioFile
        guard FileManager.default.fileExists(atPath: cafURL.path) else { return false }
        let ok = await Self.remux(caf: cafURL, to: finalURL)
        if ok {
            try? FileManager.default.removeItem(at: cafURL)
        } else {
            log.error("MeetingTrack[\(self.label, privacy: .public)] remux failed; keeping CAF for recovery")
        }
        return ok
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
            try proc.run()
            await Task.detached(priority: .utility) { proc.waitUntilExit() }.value
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
        for caf in files where caf.pathExtension == "caf" && caf.lastPathComponent.hasPrefix("meeting_") {
            let m4a = finalURL(forSpool: caf)
            if FileManager.default.fileExists(atPath: m4a.path) {
                // Finalize completed for this track but spool cleanup didn't; just clean up.
                try? FileManager.default.removeItem(at: caf)
                continue
            }
            if await remux(caf: caf, to: m4a) {
                try? FileManager.default.removeItem(at: caf)
                recovered += 1
                NSLog("DictationApp: [MEET] recovered orphaned track %@", m4a.lastPathComponent)
                log.info("recovered orphaned track \(m4a.lastPathComponent, privacy: .public)")
            } else {
                NSLog("DictationApp: [MEET] recovery FAILED for %@", caf.lastPathComponent)
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
