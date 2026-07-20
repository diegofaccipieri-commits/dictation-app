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

    /// Track duration in seconds (frame count from the header; no decode).
    static func duration(for url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        return Double(file.length) / rate
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
    @Published var playingPairId: String?
    @Published var progress: Double = 0
    @Published var currentSeconds: Double = 0
    @Published var totalSeconds: Double = 0
    private var player: AVAudioPlayer?
    private var combinedPlayer: AVPlayer?
    private var pairURLs: Set<URL> = []
    private var pairDuration: TimeInterval = 0
    /// When set (selection preview), playback stops once progress reaches this fraction.
    private var stopAtProgress: Double?
    private var timer: Timer?

    func toggle(_ url: URL) {
        if playingURL == url { stop(); return }
        play(url, from: 0)
    }

    func play(_ url: URL, from progress: Double) {
        let clampedProgress = min(1, max(0, progress))
        if playingURL == url, let player {
            player.currentTime = player.duration * clampedProgress
            player.play()
            startTimer()
            return
        }
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.currentTime = p.duration * clampedProgress
            p.play()
            player = p
            playingURL = url
            totalSeconds = p.duration
            currentSeconds = p.currentTime
            startTimer()
        } catch { playingURL = nil }
    }

    func togglePair(id: String, urls: [URL]) {
        if playingPairId == id { stop(); return }
        playPair(id: id, urls: urls, from: 0)
    }

    func playPair(id: String, urls: [URL], from progress: Double, until stopAt: Double? = nil) {
        let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !validURLs.isEmpty else { return }
        let clampedProgress = min(1, max(0, progress))

        if playingPairId == id, let player = combinedPlayer, pairDuration > 0 {
            stopAtProgress = stopAt
            seek(player, to: clampedProgress * pairDuration)
            return
        }
        stop()
        stopAtProgress = stopAt

        do {
            let composition = AVMutableComposition()
            var duration = CMTime.zero
            for url in validURLs {
                let asset = AVURLAsset(url: url)
                guard let source = asset.tracks(withMediaType: .audio).first,
                      let track = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    continue
                }
                let range = CMTimeRange(start: .zero, duration: asset.duration)
                try track.insertTimeRange(range, of: source, at: .zero)
                duration = max(duration, asset.duration)
            }
            guard composition.tracks(withMediaType: .audio).isEmpty == false else { return }

            let item = AVPlayerItem(asset: composition)
            let player = AVPlayer(playerItem: item)
            combinedPlayer = player
            pairURLs = Set(validURLs)
            pairDuration = duration.seconds.isFinite ? duration.seconds : 0
            playingPairId = id
            totalSeconds = pairDuration
            currentSeconds = clampedProgress * pairDuration
            seek(player, to: clampedProgress * pairDuration)
            startTimer()
        } catch {
            stop()
        }
    }

    func isPlaying(_ url: URL) -> Bool {
        playingURL == url || pairURLs.contains(url)
    }

    func isPlayingPair(id: String) -> Bool {
        playingPairId == id
    }

    func progress(for url: URL) -> Double {
        if playingURL == url { return progress }
        if pairURLs.contains(url) { return progress }
        return 0
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        combinedPlayer?.pause()
        combinedPlayer = nil
        pairURLs = []
        pairDuration = 0
        stopAtProgress = nil
        playingURL = nil
        playingPairId = nil
        progress = 0
        currentSeconds = 0
        totalSeconds = 0
    }

    private func seek(_ player: AVPlayer, to seconds: TimeInterval) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            player?.play()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let p = self.player, p.duration > 0 {
                    self.progress = p.currentTime / p.duration
                    self.currentSeconds = p.currentTime
                } else if let p = self.combinedPlayer, self.pairDuration > 0 {
                    let current = p.currentTime().seconds
                    self.progress = current / self.pairDuration
                    self.currentSeconds = current
                    if p.timeControlStatus != .playing && current >= self.pairDuration {
                        self.stop()
                    }
                }
                if let stopAt = self.stopAtProgress, self.progress >= stopAt {
                    self.stop()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
