import AppKit
import SwiftUI

// Floating HUD near the cursor — shows recording state and live transcription preview.
class DictationHUD {
    private var panel: NSPanel?
    private var anchorPoint: NSPoint = .zero

    func show(state: RecordingState, near point: NSPoint) {
        anchorPoint = point
        if panel == nil { createPanel() }
        showStatus(state)
        panel?.orderFrontRegardless()
    }

    func update(state: RecordingState) {
        guard let panel, panel.isVisible else { return }
        showStatus(state)
    }

    // Called by the streaming loop as partial text arrives.
    // Shows a text bubble near the cursor so the user can see what's being transcribed
    // without opening the app popover.
    func updateText(_ text: String) {
        guard let panel, panel.isVisible, !text.isEmpty else { return }

        // Show only the tail so the bubble stays compact.
        let tail = text.count > 100 ? "…" + String(text.suffix(97)) : text
        let view = HUDTextView(text: tail)
        panel.contentViewController = NSHostingController(rootView: view)

        // Resize to fit text, capped at 420px wide.
        let estimated = CGFloat(tail.count) * 7.5 + 32
        let width = min(420, max(180, estimated))
        let size = NSSize(width: width, height: 48)
        let origin = clampToScreen(NSPoint(x: anchorPoint.x + 16, y: anchorPoint.y - 76), size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func showStatus(_ state: RecordingState) {
        let view = HUDView(state: state)
        panel?.contentViewController = NSHostingController(rootView: view)
        let size = NSSize(width: 56, height: 56)
        let origin = clampToScreen(NSPoint(x: anchorPoint.x + 16, y: anchorPoint.y - 70), size: size)
        panel?.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Clamp the HUD origin so it stays fully visible on screen.
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
            contentRect: NSRect(x: 0, y: 0, width: 56, height: 56),
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

    var body: some View {
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
            case .idle:
                EmptyView()
            }
        }
        .frame(width: 48, height: 48)
        .padding(4)
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
