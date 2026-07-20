import SwiftUI
import AppKit

/// DictationApp 2.0 palette: orange is the user's voice and the app accent, teal is the Mac's
/// audio ("Outros"), red is reserved for active recording. All colors adapt to light/dark.
enum AppColors {
    /// #E2620F light / #FF8A3D dark — sua voz e o accent do app.
    static let voice = dynamic(light: NSColor(srgbRed: 0.886, green: 0.384, blue: 0.059, alpha: 1),
                               dark: NSColor(srgbRed: 1.000, green: 0.541, blue: 0.239, alpha: 1))
    /// #12909E light / #38B9C5 dark — o áudio que o Mac ouve (Outros).
    static let others = dynamic(light: NSColor(srgbRed: 0.071, green: 0.565, blue: 0.620, alpha: 1),
                                dark: NSColor(srgbRed: 0.220, green: 0.725, blue: 0.773, alpha: 1))
    /// #E5484D light / #FF5F57 dark — exclusivo de gravação ativa.
    static let recording = dynamic(light: NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1),
                                   dark: NSColor(srgbRed: 1.000, green: 0.373, blue: 0.341, alpha: 1))

    static var voiceNS: NSColor { nsDynamic(light: NSColor(srgbRed: 0.886, green: 0.384, blue: 0.059, alpha: 1),
                                            dark: NSColor(srgbRed: 1.000, green: 0.541, blue: 0.239, alpha: 1)) }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: nsDynamic(light: light, dark: dark))
    }

    private static func nsDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
