import CoreGraphics
import AppKit

// Detects double-tap of the fn key via CGEventTap
// fn key sends flagsChanged events with maskSecondaryFn flag, NOT keyDown
class FnKeyMonitor {
    var onDoubleTap: (() -> Void)?
    var onEscape: (() -> Void)?

    private var eventTap: CFMachPort?
    private var lastFnPressTime: TimeInterval = 0
    private var fnIsDown: Bool = false
    private let doubleTapInterval: TimeInterval = 0.5
    private let escKeyCode: CGKeyCode = 53

    func start() {
        // fn key sends flagsChanged; ESC sends keyDown
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                      | CGEventMask(1 << CGEventType.keyDown.rawValue)

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
            print("DictationApp: could not create event tap — grant Accessibility permission in System Settings → Privacy → Accessibility")
            return
        }

        print("DictationApp: fn key monitor started")
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
        // ESC key: cancel recording if active
        if event.type == .keyDown && CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == escKeyCode {
            DispatchQueue.main.async { [weak self] in self?.onEscape?() }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let fnDown = flags.contains(.maskSecondaryFn)

        // Detect fn key press (transition from up to down)
        if fnDown && !fnIsDown {
            fnIsDown = true
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastFnPressTime < doubleTapInterval {
                lastFnPressTime = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onDoubleTap?()
                }
                // Consume event so macOS Dictation doesn't fire
                return nil
            } else {
                lastFnPressTime = now
            }
        } else if !fnDown {
            fnIsDown = false
        }

        return Unmanaged.passUnretained(event)
    }
}
