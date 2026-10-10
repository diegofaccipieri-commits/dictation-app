import CoreGraphics
import Foundation

/// Types text into the focused app with synthetic Unicode key events (no clipboard involved).
enum KeyboardTyper {
    // CGEvent carries at most ~20 UTF-16 units per event; stay below that.
    private static let unitsPerEvent = 16

    static func type(_ text: String) {
        guard !text.isEmpty, !UserDefaults.standard.bool(forKey: "debugNoPaste") else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + unitsPerEvent, units.count)
            // Never split a surrogate pair across two events.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[start..<end])
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
            start = end
        }
    }

    static func backspace(_ count: Int) {
        guard count > 0, !UserDefaults.standard.bool(forKey: "debugNoPaste") else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: keyDown) else { continue }
                event.flags = []
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }
}
