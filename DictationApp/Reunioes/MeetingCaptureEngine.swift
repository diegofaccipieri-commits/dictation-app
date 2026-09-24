import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import OSLog

enum MeetingCaptureError: LocalizedError {
    case noDisplay
    case noMicrophoneInput
    case microphoneConfigurationChanged

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Nenhum display disponivel para captura de audio do sistema."
        case .noMicrophoneInput: return "Nao foi possivel acessar a entrada de microfone."
        case .microphoneConfigurationChanged: return "O dispositivo de microfone mudou durante a gravacao."
        }
    }
}

/// Captures system audio (Core Audio process tap; ScreenCaptureKit as fallback) and the microphone
/// (AVAudioEngine), writing each source to a crash-tolerant CAF that is remuxed to .m4a on stop.
///
/// A `MeetingSilenceWatchdog` monitors the system track: sustained digital silence triggers a
/// transparent capture restart and, if silence persists, `onSystemSilenceAlert` so the UI can jump
/// in front of the user (who is in a meeting, not looking at this app).
@available(macOS 15, *)
final class MeetingCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let micURL: URL
    private let systemURL: URL
    private let queue = DispatchQueue(label: "com.diego.dictationapp.meeting.capture")
    private let log = Logger(subsystem: "com.diego.dictationapp", category: "MeetingCapture")

    private enum SystemSource { case none, tap(SystemAudioTapCapture), sck(SCStream) }
    private var systemSource: SystemSource = .none
    private var micCapture: MeetingMicrophoneCapture?
    private var systemTrack: MeetingCrashSafeTrack?
    private var watchdog = MeetingSilenceWatchdog()
    private var systemFrames: Int64 = 0
    private var systemSampleRate: Double = 48_000
    private var isStopping = false
    private var isRestartingSystem = false
    private var isSystemMuted: Bool
    private let microphoneMuted: Bool

    var onStop: ((Error?) -> Void)?
    var onMicrophoneLevel: ((Float) -> Void)?
    var onSystemLevel: ((Float) -> Void)?
    /// Sustained digital silence on the system track even after an automatic restart.
    var onSystemSilenceAlert: ((Double) -> Void)?
    /// Audible system audio returned after an alert.
    var onSystemSilenceCleared: (() -> Void)?

    init(micURL: URL, systemURL: URL, microphoneMuted: Bool = false, systemMuted: Bool = false) {
        self.micURL = micURL
        self.systemURL = systemURL
        self.isSystemMuted = systemMuted
        self.microphoneMuted = microphoneMuted
        super.init()
    }

    func setMicrophoneMuted(_ muted: Bool) {
        queue.async { [weak self] in self?.micCapture?.setMuted(muted) }
    }

    func setSystemMuted(_ muted: Bool) {
        queue.async { [weak self] in self?.isSystemMuted = muted }
    }

    func start() async throws {
        let mic = MeetingMicrophoneCapture(url: micURL, isMuted: microphoneMuted)
        mic.onStop = { [weak self] error in self?.onStop?(error) }
        mic.onLevel = { [weak self] level in self?.onMicrophoneLevel?(level) }
        micCapture = mic
        systemTrack = MeetingCrashSafeTrack(finalURL: systemURL, label: "system")
        watchdog.reset()
        systemFrames = 0
        isStopping = false
        isRestartingSystem = false

        do {
            try await startSystemSource()
            try mic.start()
            log.info("Meeting capture started")
            NSLog("DictationApp: [MEET] capture started")
        } catch {
            logNSError(error, stage: "Meeting capture start")
            await teardownSystemSource()
            await mic.stop()
            micCapture = nil
            systemTrack = nil
            try? FileManager.default.removeItem(at: MeetingCrashSafeTrack.spoolURL(for: micURL))
            try? FileManager.default.removeItem(at: MeetingCrashSafeTrack.spoolURL(for: systemURL))
            throw error
        }
    }

    func stop() async {
        isStopping = true
        await teardownSystemSource()
        let mic = micCapture
        micCapture = nil
        await mic?.stop()

        // Finalize both tracks concurrently (instant when the live AAC is valid).
        let track = systemTrack
        systemTrack = nil
        async let systemDone: Bool? = track?.finalize()
        async let micDone: Void? = mic?.finalizeTrack()
        _ = await (systemDone, micDone)
        log.info("Meeting capture stopped")
    }

    /// Manual restart from the alert panel button.
    func restartSystemCaptureManually() {
        queue.async { [weak self] in self?.restartSystemSource(reason: "manual") }
    }

    // MARK: - System source (tap primary, SCK fallback)

    private func startSystemSource() async throws {
        let tap = SystemAudioTapCapture()
        tap.onBuffer = { [weak self] buffer in
            self?.queue.async { self?.handleSystemBuffer(buffer) }
        }
        do {
            try tap.start()
            systemSource = .tap(tap)
            log.info("System audio via Core Audio process tap")
            NSLog("DictationApp: [MEET] system source = CoreAudio tap")
            return
        } catch {
            logNSError(error, stage: "Process tap unavailable; falling back to ScreenCaptureKit")
        }

        let stream = try await makeSCKStream()
        try await stream.startCapture()
        systemSource = .sck(stream)
        log.info("System audio via ScreenCaptureKit (fallback)")
        NSLog("DictationApp: [MEET] system source = SCK fallback")
    }

    private func teardownSystemSource() async {
        switch systemSource {
        case .tap(let tap): tap.stop()
        case .sck(let stream): try? await stream.stopCapture()
        case .none: break
        }
        systemSource = .none
    }

    private func restartSystemSource(reason: String) {
        guard !isStopping, !isRestartingSystem else { return }
        isRestartingSystem = true
        log.error("Restarting system capture (\(reason, privacy: .public))")
        NSLog("DictationApp: [MEET] restarting system capture (%@)", reason)
        Task { [weak self] in
            guard let self else { return }
            await self.teardownSystemSource()
            do {
                try await self.startSystemSource()
            } catch {
                self.logNSError(error, stage: "System capture restart failed")
                self.onStop?(error)
            }
            self.isRestartingSystem = false
        }
    }

    /// Single funnel for system audio from either source: level meter, watchdog, crash-safe write.
    private func handleSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isStopping else { return }
        systemSampleRate = buffer.format.sampleRate
        let rms = buffer.meetingRMS
        onSystemLevel?(rms)

        systemFrames += Int64(buffer.frameLength)
        let pts = Double(systemFrames) / systemSampleRate
        switch watchdog.observe(pts: pts, rms: rms) {
        case .none:
            break
        case .restartCapture:
            restartSystemSource(reason: "digital silence")
        case .showAlert(let silentFor):
            log.error("System audio digitally silent for \(Int(silentFor), privacy: .public)s; alerting user")
            NSLog("DictationApp: [MEET] ALERT system silent for %.0fs", silentFor)
            onSystemSilenceAlert?(silentFor)
        case .clearAlert:
            onSystemSilenceCleared?()
        }

        if isSystemMuted { buffer.meetingSilence() }
        systemTrack?.write(buffer)
    }

    // MARK: - ScreenCaptureKit fallback

    private func makeSCKStream() async throws -> SCStream {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw MeetingCaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        return stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard case .sck(let current) = systemSource, current === stream else { return }
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        handleSystemBuffer(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logNSError(error, stage: "SCStream stopped")
        guard case .sck(let current) = systemSource, current === stream else { return }
        if isStopping || isRestartingSystem { return }
        onStop?(error)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var format = asbd.pointee
        guard let avFormat = AVAudioFormat(streamDescription: &format) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    private func logNSError(_ error: Error, stage: String) {
        let ns = error as NSError
        log.error("\(stage, privacy: .public): domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) userInfo=\(ns.userInfo.description, privacy: .public)")
    }
}

/// Records the microphone independently (AVAudioEngine tap) into a crash-tolerant CAF track.
@available(macOS 15, *)
final class MeetingMicrophoneCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.diego.dictationapp.meeting.microphone")
    private let log = Logger(subsystem: "com.diego.dictationapp", category: "MeetingMicrophone")

    private var engine: AVAudioEngine?
    private var track: MeetingCrashSafeTrack?
    private var configChangeObserver: NSObjectProtocol?
    private var isStopping = false

    var onStop: ((Error?) -> Void)?
    var onLevel: ((Float) -> Void)?

    private var isMuted: Bool

    init(url: URL, isMuted: Bool = false) {
        self.isMuted = isMuted
        self.track = MeetingCrashSafeTrack(finalURL: url, label: "mic")
    }

    func setMuted(_ muted: Bool) {
        queue.sync { [weak self] in self?.isMuted = muted }
    }

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingCaptureError.noMicrophoneInput
        }
        self.engine = engine
        self.isStopping = false

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let copy = buffer.meetingCopy() else { return }
            self.queue.async {
                self.onLevel?(copy.meetingRMS)
                if self.isMuted { copy.meetingSilence() }
                self.track?.write(copy)
            }
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isStopping else { return }
            self.log.error("Meeting microphone configuration changed")
            self.onStop?(MeetingCaptureError.microphoneConfigurationChanged)
        }

        do {
            try engine.start()
            log.info("Meeting microphone capture started: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) channels")
        } catch {
            cleanupAfterStartFailure()
            throw error
        }
    }

    func stop() async {
        isStopping = true
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        // Drain pending writes queued from the tap before finalization.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { cont.resume() }
        }
        log.info("Meeting microphone capture stopped")
    }

    /// Remux the CAF into the final .m4a. Call after `stop()`.
    func finalizeTrack() async {
        let track = self.track
        self.track = nil
        await track?.finalize()
    }

    private func cleanupAfterStartFailure() {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        track = nil
    }
}
