import AppKit
import SwiftUI

/// Floating alert shown when the system-audio capture goes digitally silent during a meeting (or
/// the recording fails). The user is normally NOT looking at the app during a meeting, so this
/// panel jumps in front of everything — full-screen apps and all Spaces included — until the
/// audio comes back or the user acts.
@available(macOS 15, *)
@MainActor
final class MeetingAlertPanel {
    static let shared = MeetingAlertPanel()

    var onRestart: (() -> Void)?
    var onIgnore: (() -> Void)?

    private var panel: NSPanel?
    private let model = Model()

    final class Model: ObservableObject {
        @Published var message = ""
    }

    func show(message: String) {
        model.message = message
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
    }

    func update(message: String) {
        model.message = message
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let content = MeetingAlertView(
            model: model,
            restart: { [weak self] in self?.onRestart?(); self?.hide() },
            ignore: { [weak self] in self?.onIgnore?(); self?.hide() }
        )
        let hosting = NSHostingController(rootView: content)
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar                              // above normal and full-screen windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setContentSize(hosting.view.fittingSize)
        positionTopRight(panel)
        return panel
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 24, y: f.maxY - size.height - 24))
    }
}

@available(macOS 15, *)
private struct MeetingAlertView: View {
    @ObservedObject var model: MeetingAlertPanel.Model
    let restart: () -> Void
    let ignore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.slash.fill")
                    .font(.title3)
                    .foregroundStyle(Color(red: 1, green: 45 / 255, blue: 58 / 255))
                Text("Sem áudio do Mac na gravação")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            Text(model.message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: restart) {
                    Text("Reiniciar captura").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 1, green: 45 / 255, blue: 58 / 255))
                Button(action: ignore) {
                    Text("Ignorar").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 18 / 255, green: 20 / 255, blue: 24 / 255))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(red: 1, green: 45 / 255, blue: 58 / 255).opacity(0.6), lineWidth: 1))
        )
    }
}
