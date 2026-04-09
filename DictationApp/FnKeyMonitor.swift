import CoreGraphics
import AppKit

// Detects double-tap of a configurable modifier key via CGEventTap.
// Default: fn key. User can change to Right Control, Right Option, etc.
class FnKeyMonitor {
    var onDoubleTap: (() -> Void)?
    var onEscape: (() -> Void)?

    // When true, a single press fires onDoubleTap immediately (used while recording).
    var isRecording: Bool = false

    // The key to double-tap (persisted in UserDefaults)
    var doubleTapKey: DoubleTapKey = DoubleTapKey(rawValue: UserDefaults.standard.string(forKey: "doubleTapKey") ?? "") ?? .fn {
        didSet {
            UserDefaults.standard.set(doubleTapKey.rawValue, forKey: "doubleTapKey")
            NSLog("DictationApp: doubleTapKey changed to %@", doubleTapKey.displayName)
        }
    }

    private var eventTap: CFMachPort?
    private var watchdog: DispatchSourceTimer?
    private var lastKeyPressTime: TimeInterval = 0
    private var keyIsDown: Bool = false
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

        NSLog("DictationApp: fn monitor started (key: %@)", doubleTapKey.displayName)
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

        let keyDown = doubleTapKey.isDown(in: event)

        if keyDown && !keyIsDown {
            keyIsDown = true

            // While recording: single press stops — no double-tap needed.
            if isRecording {
                keyIsDown = false
                lastKeyPressTime = 0
                DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
                return Unmanaged.passUnretained(event)
            }

            // While idle: require double-tap to start.
            let now = ProcessInfo.processInfo.systemUptime
            let delta = now - lastKeyPressTime
            if delta < doubleTapInterval {
                lastKeyPressTime = 0
                keyIsDown = false
                NSLog("DictationApp: double-tap → start")
                DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
            } else {
                lastKeyPressTime = now
            }
        } else if !keyDown {
            keyIsDown = false
        }

        return Unmanaged.passUnretained(event)
    }
}
