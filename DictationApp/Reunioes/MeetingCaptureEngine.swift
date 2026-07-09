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

/// Captures system audio through ScreenCaptureKit and the microphone through AVAudioEngine,
/// writing each source to a separate .m4a track.
@available(macOS 15, *)
final class MeetingCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let micURL: URL
    private let systemURL: URL
    private let queue = DispatchQueue(label: "com.diego.dictationapp.meeting.capture")
    private let log = Logger(subsystem: "com.diego.dictationapp", category: "MeetingCapture")

    private var stream: SCStream?
    private var micCapture: MeetingMicrophoneCapture?
    private var systemWriter: MeetingTrackWriter?
    private var systemHealth = MeetingSystemAudioHealth()
    private var isStopping = false
    private var isRestartingSystemStream = false
    private var systemRestartCount = 0

    var onStop: ((Error?) -> Void)?

    init(micURL: URL, systemURL: URL) {
        self.micURL = micURL
        self.systemURL = systemURL
        super.init()
    }

    func start() async throws {
        let mic = MeetingMicrophoneCapture(url: micURL)
        let sys = MeetingTrackWriter(url: systemURL, label: "system")
        mic.onStop = { [weak self] error in self?.onStop?(error) }
        self.micCapture = mic
        self.systemWriter = sys
        self.isStopping = false
        self.isRestartingSystemStream = false
        self.systemRestartCount = 0

        let stream = try await makeSystemStream()
        do {
            try await stream.startCapture()
            self.stream = stream
            try mic.start()
            log.info("Meeting capture started")
        } catch {
            logNSError(error, stage: "Meeting capture start")
            try? await stream.stopCapture()
            await mic.stop()
            cleanupAfterFailedStart()
            throw error
        }
    }

    func stop() async {
        isStopping = true
        if let stream { try? await stream.stopCapture() }
        self.stream = nil
        let micCapture = self.micCapture
        self.micCapture = nil
        await micCapture?.stop()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let group = DispatchGroup()
                self.systemWriter?.finish(group: group)
                group.notify(queue: self.queue) { cont.resume() }
            }
        }
        self.systemWriter = nil
        log.info("Meeting capture stopped")
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === self.stream else { return }
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        switch type {
        case .audio:
            if let silence = systemHealth.observe(sampleBuffer) {
                recoverSystemCapture(after: silence)
            }
            systemWriter?.append(sampleBuffer)
        default: break
        }
    }

    // MARK: SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logNSError(error, stage: "SCStream stopped")
        if isStopping || isRestartingSystemStream || !(stream === self.stream) { return }
        onStop?(error)
    }

    private func makeSystemStream() async throws -> SCStream {
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

    private func recoverSystemCapture(after silence: MeetingSystemAudioSilence) {
        guard !isStopping, !isRestartingSystemStream else { return }
        isRestartingSystemStream = true
        systemRestartCount += 1
        let attempt = systemRestartCount
        let oldStream = stream
        log.error("System audio silence detected for \(silence.silentForText, privacy: .public)s; restarting system capture attempt \(attempt, privacy: .public)")

        Task { [weak self, oldStream] in
            guard let self else { return }
            do {
                let newStream = try await self.makeSystemStream()
                try await newStream.startCapture()
                self.stream = newStream
                self.systemHealth.reset()
                try? await oldStream?.stopCapture()
                self.isRestartingSystemStream = false
                self.log.info("System audio capture restarted after digital silence; attempt \(attempt, privacy: .public)")
            } catch {
                self.logNSError(error, stage: "System audio capture restart")
                self.isRestartingSystemStream = false
                self.onStop?(error)
            }
        }
    }

    private func cleanupAfterFailedStart() {
        stream = nil
        micCapture = nil
        systemWriter = nil
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)
    }

    private func logNSError(_ error: Error, stage: String) {
        let ns = error as NSError
        log.error("\(stage, privacy: .public): domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) userInfo=\(ns.userInfo.description, privacy: .public)")
    }
}

struct MeetingSystemAudioSilence {
    let silentFor: Double
    let elapsed: Double
    let observedBuffers: Int
    let audibleBuffers: Int

    var silentForText: String { String(format: "%.1f", silentFor) }
}

/// Tracks whether ScreenCaptureKit is still delivering useful system audio. A stream can keep
/// emitting valid audio buffers after the captured app audio has gone to digital silence.
final class MeetingSystemAudioHealth {
    private let log = Logger(subsystem: "com.diego.dictationapp", category: "MeetingSystemAudioHealth")
    private let silenceThreshold: Double = 30

    private var firstPTS: Double?
    private var lastAudiblePTS: Double?
    private var lastWarnPTS: Double?
    private var observedBuffers = 0
    private var audibleBuffers = 0

    func observe(_ sampleBuffer: CMSampleBuffer) -> MeetingSystemAudioSilence? {
        guard let pts = sampleBuffer.presentationSeconds,
              let rms = sampleBuffer.audioRMS else { return nil }

        if firstPTS == nil { firstPTS = pts }
        observedBuffers += 1

        // Treat true/near digital silence separately from quiet speech. The failure seen in the
        // field produced exact zero buffers for the rest of the meeting.
        if rms > 0.00001 {
            lastAudiblePTS = pts
            audibleBuffers += 1
            return nil
        }

        guard let first = firstPTS, let lastAudiblePTS, audibleBuffers > 0 else { return nil }
        let elapsed = pts - first
        let silentFor = pts - lastAudiblePTS
        guard elapsed > 60, silentFor > silenceThreshold else { return nil }
        if let lastWarnPTS, pts - lastWarnPTS < 60 { return nil }
        lastWarnPTS = pts
        let silentForText = String(format: "%.1f", silentFor)
        log.error("System audio has been digitally silent for \(silentForText, privacy: .public)s; observedBuffers=\(self.observedBuffers, privacy: .public) audibleBuffers=\(self.audibleBuffers, privacy: .public)")
        return MeetingSystemAudioSilence(silentFor: silentFor,
                                         elapsed: elapsed,
                                         observedBuffers: observedBuffers,
                                         audibleBuffers: audibleBuffers)
    }

    func reset() {
        firstPTS = nil
        lastAudiblePTS = nil
        lastWarnPTS = nil
        observedBuffers = 0
        audibleBuffers = 0
    }
}

private extension CMSampleBuffer {
    var presentationSeconds: Double? {
        let pts = CMSampleBufferGetPresentationTimeStamp(self)
        guard pts.isValid, pts.isNumeric else { return nil }
        return CMTimeGetSeconds(pts)
    }

    var audioRMS: Float? {
        guard let block = CMSampleBufferGetDataBuffer(self),
              let format = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0,
                                                 lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return nil }

        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = totalLength / bytesPerFrame
        guard frameCount > 0 else { return nil }

        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let sampleCount = frameCount * channels
        guard sampleCount > 0 else { return nil }

        if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0, asbd.mBitsPerChannel == 32 {
            let ptr = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            var sum: Float = 0
            for i in 0..<sampleCount { sum += ptr[i] * ptr[i] }
            return sqrt(sum / Float(sampleCount))
        }

        if (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0, asbd.mBitsPerChannel == 16 {
            let ptr = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int16.self)
            var sum: Float = 0
            for i in 0..<sampleCount {
                let x = Float(ptr[i]) / Float(Int16.max)
                sum += x * x
            }
            return sqrt(sum / Float(sampleCount))
        }

        return nil
    }
}

/// Writes one audio track (CMSampleBuffers) to an .m4a, configured lazily from the first buffer.
final class MeetingTrackWriter {
    private let url: URL
    private let label: String
    private let log = Logger(subsystem: "com.diego.dictationapp", category: "MeetingTrackWriter")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var failed = false
    private(set) var sampleCount = 0

    init(url: URL, label: String) {
        self.url = url
        self.label = label
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard !failed else { return }
        if writer == nil { configure(with: sampleBuffer) }
        guard let writer, let input, writer.status == .writing else { return }
        if input.isReadyForMoreMediaData {
            if input.append(sampleBuffer) {
                sampleCount += 1
            } else {
                failed = true
                let message = writer.error?.localizedDescription ?? "unknown append failure"
                log.error("MeetingTrackWriter[\(self.label, privacy: .public)] append failed: \(message, privacy: .public)")
            }
        }
    }

    private func configure(with sampleBuffer: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else {
            failed = true; return
        }
        let asbd = asbdPtr.pointee
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                AVEncoderBitRateKey: 128_000
            ]
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            i.expectsMediaDataInRealTime = true
            guard w.canAdd(i) else { failed = true; return }
            w.add(i)
            guard w.startWriting() else { failed = true; return }
            w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            self.writer = w
            self.input = i
        } catch {
            failed = true
            log.error("MeetingTrackWriter[\(self.label, privacy: .public)] error: \(error.localizedDescription)")
        }
    }

    func finish(group: DispatchGroup) {
        guard let writer, let input, writer.status == .writing else { return }
        group.enter()
        input.markAsFinished()
        writer.finishWriting { group.leave() }
    }
}

/// Records the microphone independently from ScreenCaptureKit. Keeping the mic out of SCStream
/// avoids startCapture failures seen when `.audio` and `.microphone` share one stream.
final class MeetingMicrophoneCapture: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.diego.dictationapp.meeting.microphone")
    private let log = Logger(subsystem: "com.diego.dictationapp", category: "MeetingMicrophone")

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var configChangeObserver: NSObjectProtocol?
    private var isStopping = false

    var onStop: ((Error?) -> Void)?

    init(url: URL) {
        self.url = url
        try? FileManager.default.removeItem(at: url)
    }

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingCaptureError.noMicrophoneInput
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 128_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        self.engine = engine
        self.audioFile = file
        self.isStopping = false

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.enqueue(buffer)
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

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.audioFile = nil
                cont.resume()
            }
        }
        log.info("Meeting microphone capture stopped")
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copyForAsyncWrite() else { return }
        queue.async { [weak self] in
            guard let self, let audioFile = self.audioFile else { return }
            do {
                try audioFile.write(from: copy)
            } catch {
                let ns = error as NSError
                self.log.error("Meeting microphone write failed: domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) userInfo=\(ns.userInfo.description, privacy: .public)")
                self.onStop?(error)
            }
        }
    }

    private func cleanupAfterStartFailure() {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        audioFile = nil
        try? FileManager.default.removeItem(at: url)
    }
}

private extension AVAudioPCMBuffer {
    func copyForAsyncWrite() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength

        let src = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.count == dst.count else { return nil }

        for index in 0..<src.count {
            guard let srcData = src[index].mData, let dstData = dst[index].mData else { continue }
            memcpy(dstData, srcData, Int(src[index].mDataByteSize))
            dst[index].mDataByteSize = src[index].mDataByteSize
        }
        return copy
    }
}
