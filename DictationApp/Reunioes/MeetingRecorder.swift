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

    private var engine: MeetingCaptureEngine?
    private var timer: Timer?
    private var startDate: Date?

    func onAppear() {
        refreshPermissions()
        loadMeetings()
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
        self.engine = engine
        do {
            try await engine.start()
            startDate = Date()
            elapsed = 0
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
        await engine.stop()
        self.engine = nil
        isRecording = false
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
}
