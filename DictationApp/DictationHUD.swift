import AppKit
import SwiftUI

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
        let size = NSSize(width: hasBadge ? 74 : 68, height: hasBadge ? 104 : 82)
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
        p.hasShadow = true
        p.ignoresMouseEvents = true
        panel = p
    }
}

private struct HUDTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

private struct HUDView: View {
    let state: RecordingState
    let startDate: Date
    let translationBadge: String?
    let size: NSSize

    var body: some View {
        VStack(spacing: 5) {
            if let translationBadge {
                Text(translationBadge)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }

            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .shadow(radius: 4)

                switch state {
                case .recording:
                    RecordingDot()
                case .transcribing:
                    ProgressView()
                        .scaleEffect(0.8)
                case .correcting:
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                        .font(.system(size: 20))
                case .idle:
                    EmptyView()
                }
            }
            .frame(width: 48, height: 48)

            if state == .recording || state == .transcribing {
                TimelineView(.animation(minimumInterval: 1)) { context in
                    Text(elapsed(from: startDate, to: context.date))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(state == .recording ? .red : .orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial)
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

private struct RecordingDot: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.3))
                .frame(width: 36, height: 36)
                .scaleEffect(pulsing ? 1.2 : 0.9)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)

            Circle()
                .fill(Color.red)
                .frame(width: 18, height: 18)

            Image(systemName: "mic.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
        }
        .onAppear { pulsing = true }
    }
}
