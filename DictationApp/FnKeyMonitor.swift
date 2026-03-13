import CoreGraphics
import AppKit

// Detects double-tap of the fn key via CGEventTap.
// fn key sends flagsChanged events with maskSecondaryFn flag, NOT keyDown.
class FnKeyMonitor {
    var onDoubleTap: (() -> Void)?
    var onEscape: (() -> Void)?

    // When true, a single fn press fires onDoubleTap immediately (used while recording).
    var isRecording: Bool = false

    private var eventTap: CFMachPort?
    private var watchdog: DispatchSourceTimer?
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

        NSLog("DictationApp: fn monitor started")
        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        startWatchdog()
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    // MARK: - Watchdog

    // Runs on a background thread every 300ms.
    // macOS disables the event tap if the main thread is busy during audio setup.
    // This re-enables it automatically so fn fn keeps working after recording starts.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.dictation.tap-watchdog"))
        timer.schedule(deadline: .now() + .milliseconds(300), repeating: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let tap = self?.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                NSLog("DictationApp: watchdog — tap was disabled, re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: - Event handling

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

        if fnDown && !fnIsDown {
            fnIsDown = true

            // While recording: single fn press stops — no double-tap needed.
            if isRecording {
                NSLog("DictationApp: fn DOWN while recording → stopping")
                fnIsDown = false
                lastFnPressTime = 0
                DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
                return Unmanaged.passUnretained(event)
            }

            // While idle: require double-tap to start.
            let now = ProcessInfo.processInfo.systemUptime
            let delta = now - lastFnPressTime
            NSLog("DictationApp: fn DOWN — delta=\(String(format: "%.3f", delta))s")
            if delta < doubleTapInterval {
                lastFnPressTime = 0
                fnIsDown = false
                NSLog("DictationApp: double-tap → firing onDoubleTap")
                DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
            } else {
                lastFnPressTime = now
            }
        } else if !fnDown {
            fnIsDown = false
        }

        return Unmanaged.passUnretained(event)
    }
}
