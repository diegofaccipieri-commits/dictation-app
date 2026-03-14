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

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "aiff", "caf",
        "mp4", "mov", "m4v"
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
                let segments = try await transcribeFile(file, duration: duration, fileIndex: done + 1, total: total, transcriber: transcriber, model: model)
                let txt = format(segments: segments, sourceFile: file)
                let output = file.deletingPathExtension().appendingPathExtension("txt")
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

    private func transcribeFile(_ url: URL, duration: Double, fileIndex: Int, total: Int, transcriber: FinalTranscriber, model: WhisperModel) async throws -> [TranscriptionSegment] {
        let name = url.lastPathComponent
        await notify("Transcrevendo \(fileIndex)/\(total): \(name) [\(model.displayName)] — 0%")
        return try await transcriber.transcribeWithSegments(url: url, model: model) { [weak self] seekTime in
            guard let self, duration > 0 else { return }
            let pct = min(Int((Double(seekTime) / duration) * 100), 99)
            Task { await self.notify("Transcrevendo \(fileIndex)/\(total): \(name) [\(model.displayName)] — \(pct)%") }
        }
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

    private struct Utterance {
        let speaker: String
        let start: Double
        let end: Double
        let text: String
    }

    private static let speakerChangeThreshold: Float = 2.0

    private func detectSpeakers(segments: [TranscriptionSegment]) -> [Utterance] {
        guard !segments.isEmpty else { return [] }

        var utterances: [Utterance] = []
        var speaker = "Falante A"
        var uStart = Double(segments[0].start)
        var uEnd = Double(segments[0].end)
        var uTexts: [String] = [segments[0].text.trimmingCharacters(in: .whitespaces)]

        for i in 1..<segments.count {
            let seg = segments[i]
            let gap = seg.start - Float(uEnd)

            if gap >= Self.speakerChangeThreshold {
                if !uTexts.isEmpty {
                    utterances.append(Utterance(speaker: speaker, start: uStart, end: uEnd,
                                                text: uTexts.joined(separator: " ")))
                }
                speaker = speaker == "Falante A" ? "Falante B" : "Falante A"
                uStart = Double(seg.start)
                uEnd = Double(seg.end)
                uTexts = [seg.text.trimmingCharacters(in: .whitespaces)]
            } else {
                uEnd = Double(seg.end)
                let t = seg.text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { uTexts.append(t) }
            }
        }

        if !uTexts.isEmpty {
            utterances.append(Utterance(speaker: speaker, start: uStart, end: uEnd,
                                        text: uTexts.joined(separator: " ")))
        }

        return utterances
    }

    // MARK: - Output formatting

    private func format(segments: [TranscriptionSegment], sourceFile: URL) -> String {
        let utterances = detectSpeakers(segments: segments)

        var lines: [String] = []
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)

        lines.append("Transcrição gerada em: \(date)")
        lines.append("Arquivo: \(sourceFile.lastPathComponent)")
        if let last = utterances.last {
            lines.append("Duração aproximada: \(formatTime(last.end))")
        }
        lines.append("Modelo: openai_whisper-large-v3")
        lines.append(String(repeating: "-", count: 60))
        lines.append("")

        for u in utterances {
            let timeRange = "[\(formatTime(u.start)) - \(formatTime(u.end))]"
            lines.append("\(timeRange) [\(u.speaker)]:")
            lines.append(u.text)
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
