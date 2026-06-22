import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import OSLog

enum MeetingCaptureError: LocalizedError {
    case noDisplay
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Nenhum display disponivel para captura de audio do sistema."
        }
    }
}

/// Captures system audio (.audio) and the microphone (.microphone) as SEPARATE tracks in one
/// SCStream, writing each to its own .m4a. Requires macOS 15 (captureMicrophone on SCStream).
@available(macOS 15, *)
final class MeetingCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private let micURL: URL
    private let systemURL: URL
    private let queue = DispatchQueue(label: "com.diego.dictationapp.meeting.capture")
    private let log = Logger(subsystem: "com.diego.dictationapp", category: "MeetingCapture")

    private var stream: SCStream?
    private var micWriter: MeetingTrackWriter?
    private var systemWriter: MeetingTrackWriter?

    var onStop: ((Error?) -> Void)?

    init(micURL: URL, systemURL: URL) {
        self.micURL = micURL
        self.systemURL = systemURL
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw MeetingCaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let mic = MeetingTrackWriter(url: micURL, label: "mic")
        let sys = MeetingTrackWriter(url: systemURL, label: "system")
        self.micWriter = mic
        self.systemWriter = sys

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log.info("Meeting capture started")
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        self.stream = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let group = DispatchGroup()
                self.micWriter?.finish(group: group)
                self.systemWriter?.finish(group: group)
                group.notify(queue: self.queue) { cont.resume() }
            }
        }
        self.micWriter = nil
        self.systemWriter = nil
        log.info("Meeting capture stopped")
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        switch type {
        case .audio: systemWriter?.append(sampleBuffer)
        case .microphone: micWriter?.append(sampleBuffer)
        default: break
        }
    }

    // MARK: SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Meeting stream stopped with error: \(error.localizedDescription)")
        onStop?(error)
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
        if input.isReadyForMoreMediaData { if input.append(sampleBuffer) { sampleCount += 1 } }
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
