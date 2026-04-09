import CoreGraphics

enum DoubleTapKey: String, CaseIterable, Identifiable {
    case fn = "fn"
    case rightControl = "rightControl"
    case leftControl = "leftControl"
    case rightOption = "rightOption"
    case rightShift = "rightShift"
    case rightCommand = "rightCommand"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: return "fn"
        case .rightControl: return "Right Control"
        case .leftControl: return "Left Control"
        case .rightOption: return "Right Option"
        case .rightShift: return "Right Shift"
        case .rightCommand: return "Right Command"
        }
    }

    /// Check if this key's flags are present in the event
    func isDown(in event: CGEvent) -> Bool {
        let flags = event.flags
        switch self {
        case .fn:
            return flags.contains(.maskSecondaryFn)
        case .rightControl:
            // Right Control sets both maskControl and bit 13 (0x2000)
            return flags.contains(.maskControl) && (flags.rawValue & 0x2000) != 0
        case .leftControl:
            return flags.contains(.maskControl) && (flags.rawValue & 0x2000) == 0
        case .rightOption:
            // Right Option sets both maskAlternate and bit 6 (0x40)
            return flags.contains(.maskAlternate) && (flags.rawValue & 0x40) != 0
        case .rightShift:
            // Right Shift sets both maskShift and bit 2 (0x4)
            return flags.contains(.maskShift) && (flags.rawValue & 0x4) != 0
        case .rightCommand:
            // Right Command sets both maskCommand and bit 4 (0x10)
            return flags.contains(.maskCommand) && (flags.rawValue & 0x10) != 0
        }
    }
}
