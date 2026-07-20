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
    @Published private(set) var microphoneLevels = Array(repeating: Float(0), count: 32)
    @Published private(set) var systemLevels = Array(repeating: Float(0), count: 32)

    private var engine: MeetingCaptureEngine?
    private var timer: Timer?
    private var startDate: Date?
    private var lastMicrophoneLevelUpdate = Date.distantPast
    private var lastSystemLevelUpdate = Date.distantPast

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
        engine.onMicrophoneLevel = { [weak self] level in
            Task { @MainActor in self?.appendMicrophoneLevel(level) }
        }
        engine.onSystemLevel = { [weak self] level in
            Task { @MainActor in self?.appendSystemLevel(level) }
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
            startDate = Date()
            elapsed = 0
            resetLiveLevels()
            startTimer()
            isRecording = true
        } catch {
            lastError = error.localizedDescription
            self.engine = nil
            refreshPermissions()
        }
    }

    func stop() async {
        guard let engine else { return }
        stopTimer()
        MeetingAlertPanel.shared.hide()
        await engine.stop()
        self.engine = nil
        isRecording = false
        resetLiveLevels()
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

    // MARK: Timer
    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil; startDate = nil }

    // MARK: Live input meters
    private func appendMicrophoneLevel(_ rawLevel: Float) {
        guard isRecording else { return }
        let now = Date()
        guard now.timeIntervalSince(lastMicrophoneLevelUpdate) >= 1.0 / 16.0 else { return }
        lastMicrophoneLevelUpdate = now
        append(rawLevel, to: &microphoneLevels)
    }

    private func appendSystemLevel(_ rawLevel: Float) {
        guard isRecording else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSystemLevelUpdate) >= 1.0 / 16.0 else { return }
        lastSystemLevelUpdate = now
        append(rawLevel, to: &systemLevels)
    }

    private func append(_ rawLevel: Float, to levels: inout [Float]) {
        guard rawLevel.isFinite else { return }
        let visibleLevel = min(1, sqrt(max(0, rawLevel)) * 3.5)
        levels.append(visibleLevel)
        if levels.count > 32 { levels.removeFirst(levels.count - 32) }
    }

    private func resetLiveLevels() {
        microphoneLevels = Array(repeating: 0, count: 32)
        systemLevels = Array(repeating: 0, count: 32)
        lastMicrophoneLevelUpdate = .distantPast
        lastSystemLevelUpdate = .distantPast
    }
}
