import AppKit
import SwiftUI

#if canImport(Translation)
import Translation
#endif

// Offline translation via Apple's Translation framework (macOS 15+). Used for the
// direct language-pair modes; profile modes (LAWYER etc.) need custom instructions
// and stay on Claude. Returns nil whenever the pair is not installed or anything
// fails, so the caller can fall back to ClaudeTranslator.
//
// TranslationSession has no headless API: it only exists inside a SwiftUI
// .translationTask, so we host an invisible 1x1 panel offscreen to run it.
@available(macOS 15.0, *)
@MainActor
final class AppleTranslator {
    static let shared = AppleTranslator()

    private let broker = TranslationBroker()
    private var panel: NSPanel?

    private static func languageCodes(for mode: TranslationMode) -> (source: String, target: String)? {
        switch mode {
        case .ptToEn: return ("pt", "en")
        case .ptToEs: return ("pt", "es")
        case .enToPt: return ("en", "pt")
        case .enToEs: return ("en", "es")
        case .esToPt: return ("es", "pt")
        case .esToEn: return ("es", "en")
        default: return nil
        }
    }

    func translate(_ text: String, mode: TranslationMode) async -> String? {
        guard let codes = Self.languageCodes(for: mode) else { return nil }

        let availability = LanguageAvailability()
        let supported = await availability.supportedLanguages
        guard let source = supported.first(where: { $0.languageCode?.identifier == codes.source }),
              let target = supported.first(where: { $0.languageCode?.identifier == codes.target }) else {
            NSLog("DictationApp: [APPLE-TRANSLATE] pair %@->%@ not supported", codes.source, codes.target)
            return nil
        }
        let status = await availability.status(from: source, to: target)
        guard status == .installed else {
            NSLog("DictationApp: [APPLE-TRANSLATE] pair %@->%@ not installed (%@) — falling back to Claude",
                  codes.source, codes.target, String(describing: status))
            return nil
        }

        ensureHost()
        let start = ProcessInfo.processInfo.systemUptime
        let result = await broker.request(text: text, source: source, target: target)
        if let result {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            NSLog("DictationApp: [APPLE-TRANSLATE] done in %.2fs (%@): '%@'",
                  elapsed, mode.displayName, String(result.prefix(80)))
        }
        return result
    }

    private func ensureHost() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: NSRect(x: -2000, y: -2000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.contentViewController = NSHostingController(rootView: AppleTranslationHost(broker: broker))
        p.orderFrontRegardless()
        panel = p
    }
}

@available(macOS 15.0, *)
@MainActor
final class TranslationBroker: ObservableObject {
    @Published var config: TranslationSession.Configuration?
    private var pendingText: String?
    private var continuation: CheckedContinuation<String?, Never>?

    func request(text: String, source: Locale.Language, target: Locale.Language) async -> String? {
        // Dictation is sequential; a stale pending request means something went wrong.
        continuation?.resume(returning: nil)
        continuation = nil
        pendingText = text

        return await withCheckedContinuation { cont in
            continuation = cont
            if var existing = config, existing.source == source, existing.target == target {
                // Same pair: invalidate() re-fires the translationTask closure.
                existing.invalidate()
                config = existing
            } else {
                config = TranslationSession.Configuration(source: source, target: target)
            }
        }
    }

    func serve(_ session: TranslationSession) async {
        guard let text = pendingText else { return }
        pendingText = nil
        do {
            let response = try await session.translate(text)
            finish(response.targetText)
        } catch {
            NSLog("DictationApp: [APPLE-TRANSLATE] error: %@", error.localizedDescription)
            finish(nil)
        }
    }

    private func finish(_ value: String?) {
        let cont = continuation
        continuation = nil
        cont?.resume(returning: value)
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationHost: View {
    @ObservedObject var broker: TranslationBroker

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(broker.config) { session in
                await broker.serve(session)
            }
    }
}
