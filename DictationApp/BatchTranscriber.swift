import Foundation
import WhisperKit
import AppKit
import AVFoundation

// Batch transcribes audio files in a folder using large-v3.
// Each file gets a .txt with timestamps and basic speaker diarization.
class BatchTranscriber {

    static let shared = BatchTranscriber()

    private(set) var isRunning = false
    private var task: Task<Void, Never>?

    var onProgress: ((String) -> Void)?   // status message
    var onComplete: ((Int, Int) -> Void)?  // done, total

    // When set, .txt files are written here instead of next to the source file.
    var outputDirectory: URL?
    // When set, maps a source file URL to the .txt base name (without extension).
    var nameProvider: ((URL) -> String)?
    // When true, run voice-based speaker diarization and label paragraphs by speaker.
    var diarize = false

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "aiff", "caf",
        "mp4", "mov", "m4v", "qta"
    ]

    // Formats WhisperKit reads directly; anything else is transcoded to WAV first.
    private static let nativeExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "aiff", "caf", "mp4", "mov", "m4v"
    ]

    // MARK: - Public

    func start(folder: URL, transcriber: FinalTranscriber, model: WhisperModel) {
        guard !isRunning else { return }
        isRunning = true
        task = Task.detached(priority: .background) { [weak self] in
            await self?.process(files: self?.audioFiles(in: folder) ?? [], transcriber: transcriber, model: model)
        }
    }

    func startSingleFile(file: URL, transcriber: FinalTranscriber, model: WhisperModel) {
        guard !isRunning else { return }
        isRunning = true
        task = Task.detached(priority: .background) { [weak self] in
            await self?.process(files: [file], transcriber: transcriber, model: model)
        }
    }

    /// Transcribe an explicit list of files (used by the Voice Memos picker).
    func startFiles(_ files: [URL], transcriber: FinalTranscriber, model: WhisperModel) {
        guard !isRunning else { return }
        isRunning = true
        task = Task.detached(priority: .background) { [weak self] in
            await self?.process(files: files, transcriber: transcriber, model: model)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    // MARK: - Processing

    private func process(files: [URL], transcriber: FinalTranscriber, model: WhisperModel) async {
        let total = files.count
        var done = 0

        await notify("Iniciando: \(total) arquivo(s) encontrado(s)")

        for file in files {
            guard !Task.isCancelled else { break }

            let name = file.lastPathComponent
            let duration = audioDuration(file)

            do {
                let (segments, turns) = try await transcribeFile(file, duration: duration, fileIndex: done + 1, total: total, transcriber: transcriber, model: model)
                let txt = format(segments: segments, turns: turns, sourceFile: file)
                let output = outputURL(for: file)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try txt.write(to: output, atomically: true, encoding: .utf8)
                done += 1
                await notify("✓ \(done)/\(total): \(name)")
            } catch {
                await notify("✗ Erro em \(name): \(error.localizedDescription)")
            }
        }

        await MainActor.run { [weak self] in
            self?.isRunning = false
            self?.onComplete?(done, total)
        }
    }

    private func transcribeFile(_ url: URL, duration: Double, fileIndex: Int, total: Int, transcriber: FinalTranscriber, model: WhisperModel) async throws -> ([WhisperCppCLI.Segment], [SpeakerTurn]?) {
        let name = url.lastPathComponent
        var turns: [SpeakerTurn]?
        let wavURL: URL
        let tempToCleanup: URL?

        // whisper-cli needs a 16 kHz mono WAV, so always transcode first (AVFoundation handles
        // .m4a / .qta / etc). This also fixes the previous hang: WhisperKit's CoreML load
        // deadlocks on macOS 26.x, so batch now uses the same whisper.cpp engine as live dictation.
        await notify("Convertendo \(fileIndex)/\(total): \(name)…")
        if diarize {
            // Diarization needs the raw samples; decode once and reuse for transcription.
            let samples = try await AudioDecoder.decodeToSamples(url)
            let wav = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictation-decode-\(UUID().uuidString).wav")
            WhisperCppServer.saveWav(samples: samples, to: wav)
            wavURL = wav
            tempToCleanup = wav

            await notify("Identificando falantes \(fileIndex)/\(total): \(name)… (pode baixar o modelo na 1ª vez)")
            do {
                turns = try await DiarizationService.shared.diarize(samples: samples)
            } catch {
                NSLog("DictationApp [batch]: diarization failed — %@", error.localizedDescription)
                await notify("Diarização indisponível em \(name); seguindo sem falantes.")
                turns = nil
            }
        } else {
            wavURL = try await AudioDecoder.decodeToWav(url)
            tempToCleanup = wavURL
        }
        defer { if let t = tempToCleanup { try? FileManager.default.removeItem(at: t) } }

        await notify("Transcrevendo \(fileIndex)/\(total): \(name) — 0%")
        let segments = try await WhisperCppCLI.transcribeSegments(wav: wavURL) { [weak self] pct in
            Task { await self?.notify("Transcrevendo \(fileIndex)/\(total): \(name) — \(pct)%") }
        }
        return (segments, turns)
    }

    /// Where to write the .txt for a source file, honoring outputDirectory/nameProvider.
    private func outputURL(for file: URL) -> URL {
        let dir = outputDirectory ?? file.deletingLastPathComponent()
        let base = nameProvider?(file) ?? file.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent(base).appendingPathExtension("txt")
    }

    private func audioDuration(_ url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration
        return CMTimeGetSeconds(duration)
    }

    // MARK: - Speaker diarization (pause-based)
    //
    // Groups consecutive segments into "utterances".
    // When the gap between segments exceeds the threshold, speaker flips.
    // Labels: Falante A / Falante B.

    private struct Paragraph {
        let start: Double
        let end: Double
        let text: String
        var speaker: String?   // raw diarization speaker id, nil when diarization is off
    }

    // Start a new paragraph after a pause this long, or once a paragraph gets long,
    // so the transcript reads as timestamped blocks instead of one wall of text.
    private static let paragraphGap: Double = 2.0
    private static let maxParagraphChars = 600

    // Strip whisper control/timestamp tokens like <|startoftranscript|>, <|pt|>, <|0.00|>.
    private static let tokenRegex = try? NSRegularExpression(pattern: "<\\|[^|]*\\|>")

    private static func cleanText(_ text: String) -> String {
        var t = text
        if let regex = tokenRegex {
            let range = NSRange(t.startIndex..., in: t)
            t = regex.stringByReplacingMatches(in: t, range: range, withTemplate: "")
        }
        // Collapse the whitespace left behind by removed tokens.
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func paragraphs(segments: [WhisperCppCLI.Segment]) -> [Paragraph] {
        guard !segments.isEmpty else { return [] }

        var result: [Paragraph] = []
        var pStart = segments[0].start
        var pEnd = segments[0].end
        var pTexts: [String] = [Self.cleanText(segments[0].text)]

        func flush() {
            let text = pTexts.joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result.append(Paragraph(start: pStart, end: pEnd, text: text, speaker: nil)) }
        }

        for i in 1..<segments.count {
            let seg = segments[i]
            let gap = seg.start - pEnd
            let running = pTexts.joined(separator: " ").count

            if gap >= Self.paragraphGap || running >= Self.maxParagraphChars {
                flush()
                pStart = Double(seg.start)
                pEnd = Double(seg.end)
                pTexts = [Self.cleanText(seg.text)]
            } else {
                pEnd = Double(seg.end)
                let t = Self.cleanText(seg.text)
                if !t.isEmpty { pTexts.append(t) }
            }
        }
        flush()
        return result
    }

    /// The diarization speaker whose turn overlaps [start, end] the most, or nil.
    private func speaker(start: Double, end: Double, turns: [SpeakerTurn]) -> String? {
        var best: String?
        var bestOverlap = 0.0
        for t in turns {
            let overlap = min(end, t.end) - max(start, t.start)
            if overlap > bestOverlap { bestOverlap = overlap; best = t.speakerId }
        }
        return best
    }

    /// Group segments into paragraphs, starting a new one on speaker change, long pause, or length.
    private func paragraphs(segments: [WhisperCppCLI.Segment], turns: [SpeakerTurn]) -> [Paragraph] {
        guard !segments.isEmpty else { return [] }

        var result: [Paragraph] = []
        var pStart = segments[0].start
        var pEnd = segments[0].end
        var pTexts: [String] = [Self.cleanText(segments[0].text)]
        var pSpeaker = speaker(start: pStart, end: pEnd, turns: turns)

        func flush() {
            let text = pTexts.joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result.append(Paragraph(start: pStart, end: pEnd, text: text, speaker: pSpeaker)) }
        }

        for i in 1..<segments.count {
            let seg = segments[i]
            let segSpeaker = speaker(start: seg.start, end: seg.end, turns: turns)
            let gap = seg.start - pEnd
            let running = pTexts.joined(separator: " ").count

            if segSpeaker != pSpeaker || gap >= Self.paragraphGap || running >= Self.maxParagraphChars {
                flush()
                pStart = Double(seg.start)
                pEnd = Double(seg.end)
                pTexts = [Self.cleanText(seg.text)]
                pSpeaker = segSpeaker
            } else {
                pEnd = Double(seg.end)
                let t = Self.cleanText(seg.text)
                if !t.isEmpty { pTexts.append(t) }
            }
        }
        flush()
        return result
    }

    // MARK: - Output formatting

    private func format(segments: [WhisperCppCLI.Segment], turns: [SpeakerTurn]?, sourceFile: URL) -> String {
        let paras: [Paragraph]
        if let turns, !turns.isEmpty {
            paras = paragraphs(segments: segments, turns: turns)
        } else {
            paras = paragraphs(segments: segments)
        }

        // Map raw diarization ids to friendly "Falante N" by order of first appearance.
        var labelFor: [String: String] = [:]
        for p in paras {
            if let s = p.speaker, labelFor[s] == nil {
                labelFor[s] = "Falante \(labelFor.count + 1)"
            }
        }

        var lines: [String] = []
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)

        lines.append("Transcrição gerada em: \(date)")
        lines.append("Arquivo: \(sourceFile.lastPathComponent)")
        if let last = paras.last {
            lines.append("Duração aproximada: \(formatTime(last.end))")
        }
        if !labelFor.isEmpty {
            lines.append("Falantes identificados: \(labelFor.count)")
        }
        lines.append(String(repeating: "-", count: 60))
        lines.append("")

        for p in paras {
            if let s = p.speaker, let label = labelFor[s] {
                lines.append("[\(formatTime(p.start))] \(label): \(p.text)")
            } else {
                lines.append("[\(formatTime(p.start))] \(p.text)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        } else {
            return String(format: "%02d:%02d", m, sec)
        }
    }

    // MARK: - Helpers

    private func audioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .filter { !fm.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("txt").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func notify(_ message: String) async {
        NSLog("DictationApp [batch]: \(message)")
        await MainActor.run { [weak self] in
            self?.onProgress?(message)
        }
    }
}
