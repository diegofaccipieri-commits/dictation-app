import SwiftUI
import AVFoundation
import Combine

/// Reduces an audio file to `buckets` normalized peak amplitudes (0...1), chunked so memory stays bounded.
enum MeetingWaveformLoader {
    static func peaks(for url: URL, buckets: Int = 600) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let total = file.length
        guard total > 0 else { return [] }
        let channels = Int(format.channelCount)
        let framesPerBucket = max(1, Int(total) / buckets)
        var result = [Float](repeating: 0, count: buckets)
        let chunkFrames: AVAudioFrameCount = 1 << 16
        var globalIndex = 0

        while file.framePosition < total {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            do { try file.read(into: buffer, frameCount: chunkFrames) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let chData = buffer.floatChannelData else { break }
            for i in 0..<n {
                let bucket = min(buckets - 1, (globalIndex + i) / framesPerBucket)
                var peak: Float = 0
                for ch in 0..<channels {
                    let a = abs(chData[ch][i])
                    if a > peak { peak = a }
                }
                if peak > result[bucket] { result[bucket] = peak }
            }
            globalIndex += n
        }
        let maxPeak = result.max() ?? 1
        if maxPeak > 0 { for i in 0..<buckets { result[i] = result[i] / maxPeak } }
        return result
    }
}

/// Draws a centered peak waveform; `progress` tints the played portion.
struct MeetingWaveformView: View {
    let peaks: [Float]
    var color: Color = .accentColor
    var progress: Double = 0

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let midY = size.height / 2
            let barWidth = size.width / CGFloat(peaks.count)
            for (i, p) in peaks.enumerated() {
                let x = CGFloat(i) * barWidth
                let h = max(1, CGFloat(p) * size.height * 0.92)
                let rect = CGRect(x: x, y: midY - h / 2, width: max(0.8, barWidth - 0.8), height: h)
                let played = Double(i) / Double(peaks.count) <= progress
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.8),
                         with: .color(played ? color : color.opacity(0.32)))
            }
        }
    }
}

/// Single-file playback with published progress for the meeting waveform playhead.
@MainActor
final class MeetingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingURL: URL?
    @Published var progress: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ url: URL) {
        if playingURL == url { stop(); return }
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p
            playingURL = url
            startTimer()
        } catch { playingURL = nil }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        playingURL = nil; progress = 0
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
