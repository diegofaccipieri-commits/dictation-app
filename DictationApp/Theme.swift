import SwiftUI
import AppKit

/// DictationApp 2.0 palette (mirror of the approved design prototype): orange is the user's
/// voice and the app accent, teal is the Mac's audio ("Outros"), red is reserved for active
/// recording. Surface tones are warm-biased neutrals. All colors adapt to light/dark.
enum AppColors {
    /// #E2620F light / #FF8A3D dark — sua voz e o accent do app.
    static let voice = dynamic(0.886, 0.384, 0.059, 1.000, 0.541, 0.239)
    /// #12909E light / #38B9C5 dark — o áudio que o Mac ouve (Outros).
    static let others = dynamic(0.071, 0.565, 0.620, 0.220, 0.725, 0.773)
    /// #E5484D light / #FF5F57 dark — exclusivo de gravação ativa.
    static let recording = dynamic(0.898, 0.282, 0.302, 1.000, 0.373, 0.341)

    // MARK: Surfaces (warm neutrals from the prototype)

    /// Window ground — #FAF9F7 / #201D19.
    static let windowBG = dynamic(0.980, 0.976, 0.969, 0.125, 0.114, 0.098)
    /// Sidebar ground — #F2EFEB / #1B1815.
    static let sidebarBG = dynamic(0.949, 0.937, 0.922, 0.106, 0.094, 0.082)
    /// Cards/panels — #FFFFFF / #262220.
    static let panel = dynamic(1.000, 1.000, 1.000, 0.149, 0.133, 0.125)
    /// Strong border — #E2DED7 / #3A352E.
    static let border = dynamic(0.886, 0.871, 0.843, 0.227, 0.208, 0.180)
    /// Soft border — #EAE6E0 / #2E2A24.
    static let borderSoft = dynamic(0.918, 0.902, 0.878, 0.180, 0.165, 0.141)

    static var voiceNS: NSColor {
        ns(0.886, 0.384, 0.059, 1.000, 0.541, 0.239)
    }
    static var windowBGNS: NSColor {
        ns(0.980, 0.976, 0.969, 0.125, 0.114, 0.098)
    }

    private static func dynamic(_ lr: CGFloat, _ lg: CGFloat, _ lb: CGFloat,
                                _ dr: CGFloat, _ dg: CGFloat, _ db: CGFloat) -> Color {
        Color(nsColor: ns(lr, lg, lb, dr, dg, db))
    }

    private static func ns(_ lr: CGFloat, _ lg: CGFloat, _ lb: CGFloat,
                           _ dr: CGFloat, _ dg: CGFloat, _ db: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: dr, green: dg, blue: db, alpha: 1)
                : NSColor(srgbRed: lr, green: lg, blue: lb, alpha: 1)
        }
    }
}

/// Prototype ".btn" pill: panel background, 1pt border, radius 7. Kinds mirror the CSS classes.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, rec, danger }
    var kind: Kind = .normal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: kind == .normal || kind == .danger ? .medium : .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 7).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(borderColor, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .normal: return .primary
        case .primary, .rec: return .white
        case .danger: return AppColors.recording
        }
    }
    private var background: Color {
        switch kind {
        case .normal, .danger: return AppColors.panel
        case .primary: return AppColors.voice
        case .rec: return AppColors.recording
        }
    }
    private var borderColor: Color {
        switch kind {
        case .normal, .danger: return AppColors.border
        case .primary: return AppColors.voice
        case .rec: return AppColors.recording
        }
    }
}

/// Prototype ".tbtn" circular transport button.
struct TransportButtonStyle: ButtonStyle {
    var prominent = false
    var diameter: CGFloat { prominent ? 42 : 34 }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 15 : 13, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(prominent ? AppColors.voice : AppColors.panel))
            .overlay(Circle().stroke(prominent ? AppColors.voice : AppColors.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
