import CoreGraphics
import AppKit

// Detects double-tap of the fn key via CGEventTap.
// fn key sends flagsChanged events with maskSecondaryFn flag, NOT keyDown.
class FnKeyMonitor {
    var onDoubleTap: (() -> Void)?
    var onEscape: (() -> Void)?

    private var eventTap: CFMachPort?
    private var lastFnPressTime: TimeInterval = 0
    private var fnIsDown: Bool = false
    private let doubleTapInterval: TimeInterval = 0.5
    private let escKeyCode: CGKeyCode = 53

    func start() {
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
            NSLog("DictationApp: could not create event tap — grant Accessibility in System Settings → Privacy → Accessibility")
            return
        }

        NSLog("DictationApp: fn double-tap monitor started")
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
        // ESC: cancel recording
        if event.type == .keyDown && CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == escKeyCode {
            NSLog("DictationApp: ESC keyDown received")
            DispatchQueue.main.async { [weak self] in self?.onEscape?() }
            return Unmanaged.passUnretained(event)
        }

        guard event.type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let fnDown = event.flags.contains(.maskSecondaryFn)
        NSLog("DictationApp: flagsChanged — fnDown=\(fnDown) fnIsDown=\(fnIsDown) flags=\(event.flags.rawValue)")

        // Detect fn key press (transition up → down only)
        if fnDown && !fnIsDown {
            fnIsDown = true
            let now = ProcessInfo.processInfo.systemUptime
            let delta = now - lastFnPressTime
            NSLog("DictationApp: fn DOWN — delta=\(String(format: "%.3f", delta))s interval=\(doubleTapInterval)s")
            if delta < doubleTapInterval {
                lastFnPressTime = 0
                fnIsDown = false  // reset so next double-tap tracks correctly
                NSLog("DictationApp: double-tap detected → firing onDoubleTap")
                DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
            } else {
                lastFnPressTime = now
            }
        } else if !fnDown {
            NSLog("DictationApp: fn UP")
            fnIsDown = false
        }

        return Unmanaged.passUnretained(event)
    }
}
