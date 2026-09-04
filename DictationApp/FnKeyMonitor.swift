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
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var watchdog: DispatchSourceTimer?
    private var fnGlobalMonitor: Any?
    // The tap callback runs on its own thread; the NSEvent fallback runs on main.
    private let stateLock = NSLock()
    private var lastKeyPressTime: TimeInterval = 0
    private var lastToggleFireTime: TimeInterval = 0
    private var recordingStartedAt: TimeInterval = 0
    private var keyIsDown: Bool = false
    private let doubleTapInterval: TimeInterval = 0.5
    private let toggleDebounceInterval: TimeInterval = 0.35
    private let recordingStopGuardInterval: TimeInterval = 0.45
    private let escKeyCode: CGKeyCode = 53

    func start() {
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                      | CGEventMask(1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            // HID-level tap is more reliable for FN/modifier flags.
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            // Passive monitor: never intercepts/blocks system keyboard events.
            options: .listenOnly,
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

        // Service the tap on a dedicated high-priority thread. On the main run loop, any
        // busy stretch (SwiftUI layout, HUD creation, paste) delayed the callback and macOS
        // disabled the tap by timeout, dropping fn/ESC presses until the watchdog re-enabled it.
        let thread = Thread { [weak self] in
            self?.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.dictation.fn-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread

        // Fallback for FN specifically: some setups do not deliver FN reliably via CGEvent tap.
        fnGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleGlobalFlagsChanged(event: event)
        }

        startWatchdog()
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        if let monitor = fnGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            fnGlobalMonitor = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let loop = tapRunLoop {
            CFRunLoopStop(loop)
            tapRunLoop = nil
        }
        tapThread = nil
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.dictation.tap-watchdog"))
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
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
        // macOS delivers these when it disabled the tap; re-enable right away.
        if event.type == .tapDisabledByTimeout || event.type == .tapDisabledByUserInput {
            NSLog("DictationApp: event tap disabled (%d) — re-enabling", event.type.rawValue)
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        defer { stateLock.unlock() }

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
                let now = ProcessInfo.processInfo.systemUptime
                // Guard against immediate re-fire right after recording starts.
                if now - recordingStartedAt < recordingStopGuardInterval {
                    return Unmanaged.passUnretained(event)
                }
                keyIsDown = false
                lastKeyPressTime = 0
                emitToggleIfAllowed(now: now)
                return Unmanaged.passUnretained(event)
            }

            // While idle: require double-tap to start.
            let now = ProcessInfo.processInfo.systemUptime
            let delta = now - lastKeyPressTime
            if delta < doubleTapInterval {
                lastKeyPressTime = 0
                keyIsDown = false
                NSLog("DictationApp: double-tap → start")
                recordRecordingStart(now: now)
                emitToggleIfAllowed(now: now)
            } else {
                lastKeyPressTime = now
            }
        } else if !keyDown {
            keyIsDown = false
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleGlobalFlagsChanged(event: NSEvent) {
        guard doubleTapKey == .fn else { return }
        // 63 = fn/globe key
        guard event.keyCode == 63 else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        let keyDown = event.modifierFlags.contains(.function)
        if keyDown && !keyIsDown {
            keyIsDown = true
            if isRecording {
                let now = ProcessInfo.processInfo.systemUptime
                if now - recordingStartedAt < recordingStopGuardInterval {
                    return
                }
                keyIsDown = false
                lastKeyPressTime = 0
                emitToggleIfAllowed(now: now)
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let delta = now - lastKeyPressTime
            if delta < doubleTapInterval {
                lastKeyPressTime = 0
                keyIsDown = false
                NSLog("DictationApp: double-tap (fallback) → start")
                recordRecordingStart(now: now)
                emitToggleIfAllowed(now: now)
            } else {
                lastKeyPressTime = now
            }
        } else if !keyDown {
            keyIsDown = false
        }
    }

    private func emitToggleIfAllowed(now: TimeInterval) {
        if now - lastToggleFireTime < toggleDebounceInterval {
            return
        }
        lastToggleFireTime = now
        DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
    }

    private func recordRecordingStart(now: TimeInterval) {
        recordingStartedAt = now
    }
}
