import AppKit
import SwiftUI

// Small floating HUD that appears near the cursor during recording/transcribing
class DictationHUD {
    private var panel: NSPanel?

    func show(state: RecordingState, near point: NSPoint) {
        if panel == nil { createPanel() }
        guard let panel else { return }

        let hudView = HUDView(state: state)
        panel.contentViewController = NSHostingController(rootView: hudView)

        // Position near cursor, offset down-right so it doesn't cover the insertion point
        let size = NSSize(width: 56, height: 56)
        let origin = NSPoint(x: point.x + 16, y: point.y - 70)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func update(state: RecordingState) {
        guard let panel, panel.isVisible else { return }
        let hudView = HUDView(state: state)
        panel.contentViewController = NSHostingController(rootView: hudView)
    }

    func hide() {
        panel?.orderOut(nil)
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
