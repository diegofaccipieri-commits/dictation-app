import Foundation
import SwiftUI
import Combine

/// Coordinator the Reunioes UI binds to: owns the capture engine, recording lifecycle,
/// permission state, and the list of recorded meetings. Requires macOS 15 (mic+system capture).
@available(macOS 15, *)
@MainActor
final class MeetingRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastError: String?
    @Published private(set) var permissions = MeetingPermissions()
    @Published private(set) var meetings: [MeetingItem] = []

    // High-frequency state lives in its own observable objects so that only the meter
    // and clock subviews re-render (~16 Hz per channel, 4 Hz clock). When these were
    // @Published here, every tick re-rendered the whole Reunioes page, transcript included.
    let meters = MeetingLiveMeters()
    let clock = MeetingClock()

    private var engine: MeetingCaptureEngine?

    func onAppear() {
        refreshPermissions()
        loadMeetings()
        // Recover crash-orphaned CAF tracks (app died mid-recording) into playable .m4a files.
        guard !isRecording else { return }
        Task {
            let recovered = await MeetingCrashSafeTrack.recoverOrphans()
            if recovered > 0 { await MainActor.run { self.loadMeetings() } }
        }
    }

    // MARK: Permissions
    func refreshPermissions() { permissions = MeetingPermissionsManager.snapshot() }

    func requestMicrophone() {
        Task { _ = await MeetingPermissionsManager.requestMicrophone(); refreshPermissions() }
    }

    func requestScreenRecording() {
        MeetingPermissionsManager.requestScreenRecording()
        Task { try? await Task.sleep(nanoseconds: 700_000_000); refreshPermissions() }
    }

    // MARK: Lifecycle
    func toggle() { Task { isRecording ? await stop() : await start() } }

    func start() async {
        guard !isRecording else { return }
        refreshPermissions()
        lastError = nil

        let stamp = MeetingPaths.stamp(from: Date())
        let micURL = MeetingPaths.audioDir.appendingPathComponent("meeting_\(stamp)_mic.m4a")
        let sysURL = MeetingPaths.audioDir.appendingPathComponent("meeting_\(stamp)_system.m4a")

        let engine = MeetingCaptureEngine(micURL: micURL, systemURL: sysURL)
        engine.onStop = { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastError = error.localizedDescription
                await self?.stop()
            }
        }
        // Throttle on the capture queue, before hopping to the main actor: the system tap
        // delivers ~100 buffers/s and each hop used to be a main-thread task.
        let micThrottle = LevelThrottle(interval: 1.0 / 16.0)
        let systemThrottle = LevelThrottle(interval: 1.0 / 16.0)
        engine.onMicrophoneLevel = { [weak self] level in
            guard micThrottle.shouldEmit() else { return }
            Task { @MainActor in self?.meters.appendMicrophone(level) }
        }
        engine.onSystemLevel = { [weak self] level in
            guard systemThrottle.shouldEmit() else { return }
            Task { @MainActor in self?.meters.appendSystem(level) }
        }
        // Digital-silence alert: jumps in front of every app; the user is in a meeting, not here.
        engine.onSystemSilenceAlert = { [weak engine] silentFor in
            Task { @MainActor in
                let panel = MeetingAlertPanel.shared
                panel.onRestart = { engine?.restartSystemCaptureManually() }
                panel.onIgnore = nil
                panel.show(message: "O áudio do sistema está mudo há \(Int(silentFor))s mesmo após reinício automático da captura. Se há som na reunião, clique em Reiniciar captura. Se ninguém está falando, pode ignorar.")
            }
        }
        engine.onSystemSilenceCleared = {
            Task { @MainActor in MeetingAlertPanel.shared.hide() }
        }
        self.engine = engine
        do {
            try await engine.start()
            meters.reset()
            meters.isLive = true
            clock.start()
            isRecording = true
        } catch {
            lastError = error.localizedDescription
            self.engine = nil
            refreshPermissions()
        }
    }

    func stop() async {
        guard let engine else { return }
        clock.stop()
        meters.isLive = false
        MeetingAlertPanel.shared.hide()
        await engine.stop()
        self.engine = nil
        isRecording = false
        meters.reset()
        loadMeetings()
    }

    func loadMeetings() { meetings = MeetingsStore.load() }

    func rename(_ item: MeetingItem, title: String) {
        do {
            try MeetingsStore.rename(item, title: title)
            loadMeetings()
        } catch {
            lastError = "Nao foi possivel renomear a reuniao: \(error.localizedDescription)"
        }
    }

    func delete(_ item: MeetingItem) {
        do {
            try MeetingsStore.delete(item)
            loadMeetings()
        } catch {
            lastError = "Nao foi possivel apagar a reuniao: \(error.localizedDescription)"
        }
    }
}

/// Elapsed-time clock for the active recording. Observed only by the elapsed label.
@available(macOS 15, *)
@MainActor
final class MeetingClock: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0
    private var timer: Timer?
    private var startDate: Date?

    func start() {
        timer?.invalidate()
        startDate = Date()
        elapsed = 0
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        startDate = nil
    }
}

/// Live input meters (32 buckets per channel). Observed only by the channel meter views.
@available(macOS 15, *)
@MainActor
final class MeetingLiveMeters: ObservableObject {
    @Published private(set) var microphoneLevels = Array(repeating: Float(0), count: 32)
    @Published private(set) var systemLevels = Array(repeating: Float(0), count: 32)
    var isLive = false

    func appendMicrophone(_ rawLevel: Float) {
        guard isLive else { return }
        append(rawLevel, to: &microphoneLevels)
    }

    func appendSystem(_ rawLevel: Float) {
        guard isLive else { return }
        append(rawLevel, to: &systemLevels)
    }

    func reset() {
        microphoneLevels = Array(repeating: 0, count: 32)
        systemLevels = Array(repeating: 0, count: 32)
    }

    private func append(_ rawLevel: Float, to levels: inout [Float]) {
        guard rawLevel.isFinite else { return }
        let visibleLevel = min(1, sqrt(max(0, rawLevel)) * 3.5)
        levels.append(visibleLevel)
        if levels.count > 32 { levels.removeFirst(levels.count - 32) }
    }
}

/// Rate limiter safe to call from any queue.
final class LevelThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval

    init(interval: TimeInterval) { self.interval = interval }

    func shouldEmit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}
