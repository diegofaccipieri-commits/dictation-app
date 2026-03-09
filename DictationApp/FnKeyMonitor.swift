import CoreGraphics
import AppKit

// Detects double-tap of the fn key (keycode 63) via CGEventTap
class FnKeyMonitor {
    var onDoubleTap: (() -> Void)?

    private var eventTap: CFMachPort?
    private var lastFnKeyTime: TimeInterval = 0
    private let doubleTapInterval: TimeInterval = 0.5

    func start() {
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            print("DictationApp: could not create event tap — grant Accessibility permission")
            return
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    private func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 63 else { return Unmanaged.passUnretained(event) }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFnKeyTime < doubleTapInterval {
            lastFnKeyTime = 0
            DispatchQueue.main.async { [weak self] in
                self?.onDoubleTap?()
            }
            // Consume event so macOS Dictation doesn't fire
            return nil
        } else {
            lastFnKeyTime = now
        }

        return Unmanaged.passUnretained(event)
    }
}
