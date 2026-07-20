import AppKit
import SwiftUI

private enum HUDStyle {
    static let darkBackground = Color(red: 18 / 255, green: 20 / 255, blue: 24 / 255)
    static let darkStroke = Color.white.opacity(0.14)
    // Brand orange over the graphite HUD (translation badge).
    static let badgeOrange = Color(red: 1, green: 162 / 255, blue: 87 / 255)
    static let recordRed = Color(red: 1, green: 45 / 255, blue: 58 / 255)
}

// Floating HUD near the cursor — shows recording state and phase timer.
class DictationHUD {
    private var panel: NSPanel?
    private var anchorPoint: NSPoint = .zero
    private var phaseStart: Date = Date()
    private var translationBadge: String?

    func show(state: RecordingState, near point: NSPoint, translationBadge: String? = nil) {
        anchorPoint = point
        phaseStart = Date()
        self.translationBadge = translationBadge
        if panel == nil { createPanel() }
        showStatus(state)
        panel?.orderFrontRegardless()
    }

    func update(state: RecordingState, translationBadge: String? = nil) {
        guard let panel, panel.isVisible else { return }
        phaseStart = Date()  // reset timer for each new phase
        self.translationBadge = translationBadge
        showStatus(state)
    }

    func updateText(_ text: String) {
        guard let panel, panel.isVisible, !text.isEmpty else { return }
        let tail = text.count > 100 ? "…" + String(text.suffix(97)) : text
        let view = HUDTextView(text: tail)
        panel.contentViewController = NSHostingController(rootView: view)
        let estimated = CGFloat(tail.count) * 7.5 + 32
        let width = min(420, max(180, estimated))
        let size = NSSize(width: width, height: 48)
        let origin = clampToScreen(NSPoint(x: anchorPoint.x + 16, y: anchorPoint.y - 76), size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func hide() {
        panel?.orderOut(nil)
        translationBadge = nil
    }

    private func showStatus(_ state: RecordingState) {
        let badge = state == .recording ? translationBadge : nil
        let hasBadge = badge != nil
        let size = NSSize(width: hasBadge ? 80 : 72, height: hasBadge ? 112 : 90)
        let view = HUDView(state: state, startDate: phaseStart, translationBadge: badge, size: size)
        panel?.contentViewController = NSHostingController(rootView: view)
        let origin = clampToScreen(NSPoint(x: anchorPoint.x + 16, y: anchorPoint.y - size.height - 8), size: size)
        panel?.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func clampToScreen(_ point: NSPoint, size: NSSize) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) }) ?? NSScreen.main else {
            return point
        }
        let visible = screen.visibleFrame
        let x = min(max(point.x, visible.minX + 4), visible.maxX - size.width - 4)
        let y = min(max(point.y, visible.minY + 4), visible.maxY - size.height - 4)
        return NSPoint(x: x, y: y)
    }

    private func createPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 68, height: 82),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        panel = p
    }
}

private struct HUDTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HUDStyle.darkBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(HUDStyle.darkStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
    }
}

// Prototype layout: separate floating pieces with a 5pt gap — badge pill above,
// 52pt graphite circle with the state, timer pill below. No connectors.
private struct HUDView: View {
    let state: RecordingState
    let startDate: Date
    let translationBadge: String?
    let size: NSSize

    var body: some View {
        VStack(spacing: 5) {
            if let translationBadge {
                TranslationBadgeView(text: translationBadge)
            }

            ZStack {
                Circle()
                    .fill(HUDStyle.darkBackground)
                    .shadow(color: .black.opacity(0.28), radius: 6, y: 2)

                switch state {
                case .recording:
                    RecordingDot()
                case .transcribing:
                    HUDSpinner()
                case .correcting:
                    Image(systemName: "checkmark")
                        .foregroundColor(Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255))
                        .font(.system(size: 20, weight: .bold))
                case .idle:
                    EmptyView()
                }
            }
            .frame(width: 52, height: 52)

            if state == .recording || state == .transcribing {
                TimelineView(.animation(minimumInterval: 1)) { context in
                    Text(elapsed(from: startDate, to: context.date))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(state == .recording
                                         ? Color(red: 1, green: 107 / 255, blue: 107 / 255)
                                         : Color(red: 1, green: 179 / 255, blue: 64 / 255))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(HUDStyle.darkBackground)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: size.width, height: size.height)
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// Amber ring spinner (18pt, 2.5pt stroke) matching the prototype.
private struct HUDSpinner: View {
    @State private var spinning = false
    private let amber = Color(red: 1, green: 179 / 255, blue: 64 / 255)

    var body: some View {
        Circle()
            .trim(from: 0.22, to: 1)
            .stroke(amber, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .background(Circle().stroke(amber.opacity(0.25), lineWidth: 2.5))
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

private struct TranslationBadgeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(HUDStyle.badgeOrange)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(HUDStyle.darkBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(HUDStyle.badgeOrange, lineWidth: 1)
            )
    }
}

// Prototype recording state: static 20pt red dot with a soft pulsing ring around it.
private struct RecordingDot: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(HUDStyle.recordRed.opacity(0.3))
                .frame(width: 36, height: 36)
                .scaleEffect(pulsing ? 1.25 : 0.95)
                .opacity(pulsing ? 0.5 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)

            Circle()
                .fill(HUDStyle.recordRed)
                .frame(width: 20, height: 20)
        }
        .onAppear { pulsing = true }
    }
}
