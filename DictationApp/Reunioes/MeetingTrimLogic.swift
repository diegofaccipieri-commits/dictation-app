import Foundation

/// Pure logic for the meeting audio trim feature: selection normalization, time mapping,
/// output naming and titling. UI/AVFoundation-free so it runs headless in ReunioesLogicTests.
enum MeetingTrimLogic {

    /// A drag selection over a waveform, as fractions of the full duration.
    /// Always normalized: 0 <= startFraction <= endFraction <= 1, whatever the drag direction.
    struct Selection: Equatable {
        let startFraction: Double
        let endFraction: Double

        init(_ a: Double, _ b: Double) {
            let lo = min(max(0, min(a, b)), 1)
            let hi = min(max(0, max(a, b)), 1)
            startFraction = lo
            endFraction = hi
        }
    }

    /// Selections shorter than this cannot be exported.
    static let minimumSeconds: Double = 0.5

    /// Absolute time range of `selection` in a track of `duration` seconds,
    /// or nil when the resulting cut would be shorter than `minimumSeconds`.
    static func timeRange(_ selection: Selection, duration: Double) -> (start: Double, end: Double)? {
        guard duration > 0 else { return nil }
        let start = selection.startFraction * duration
        let end = selection.endFraction * duration
        guard end - start >= minimumSeconds else { return nil }
        return (start, end)
    }

    /// Id for a trimmed copy of meeting `original`: the first free "<original>_r<n>".
    /// Keeping the date prefix makes the copy sort next to its original in the list.
    static func trimmedId(original: String, existing: Set<String>) -> String {
        var n = 1
        while existing.contains("\(original)_r\(n)") { n += 1 }
        return "\(original)_r\(n)"
    }

    /// Auto title for a trimmed copy: "<base> (recorte 12:34-15:00)".
    static func trimmedTitle(base: String, start: Double, end: Double) -> String {
        "\(base) (recorte \(label(start))-\(label(end)))"
    }

    /// Ranges (in seconds) to KEEP when `selection` is removed from a track of `duration`:
    /// the piece before the cut and the piece after it, dropping slivers shorter than
    /// `minimumSeconds`. nil when the removal would leave no audio behind.
    static func keepRanges(removing selection: Selection, duration: Double) -> [(start: Double, end: Double)]? {
        guard let cut = timeRange(selection, duration: duration) else { return nil }
        var keep: [(start: Double, end: Double)] = []
        if cut.start >= minimumSeconds { keep.append((0, cut.start)) }
        if duration - cut.end >= minimumSeconds { keep.append((cut.end, duration)) }
        return keep.isEmpty ? nil : keep
    }

    /// "12:34" below one hour, "1:02:34" from one hour up.
    static func label(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
