import Foundation
import CoreAudio
import AVFoundation
import OSLog

enum SystemAudioTapError: LocalizedError {
    case tapCreation(OSStatus)
    case aggregateCreation(OSStatus)
    case formatUnavailable(OSStatus)
    case ioProcCreation(OSStatus)
    case startFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreation(let s):       return "Falha ao criar o tap de áudio do sistema (\(s))."
        case .aggregateCreation(let s): return "Falha ao criar o dispositivo agregado (\(s))."
        case .formatUnavailable(let s): return "Formato do tap indisponível (\(s))."
        case .ioProcCreation(let s):    return "Falha ao criar o IOProc (\(s))."
        case .startFailed(let s):       return "Falha ao iniciar a captura (\(s))."
        }
    }
}

/// Captures the Mac's system audio via a Core Audio process tap (macOS 14.4+), the audio-only API
/// that taps the system mix at the HAL. Unlike ScreenCaptureKit's display-audio capture, it is not
/// tied to a display stream and does not exhibit the "digital silence after output-route change"
/// failure that produced silent meeting recordings.
///
/// Delivers deinterleaved float32 `AVAudioPCMBuffer`s (deep copies, safe to hold) on `queue`.
@available(macOS 15, *)
final class SystemAudioTapCapture: @unchecked Sendable {
    private let log = Logger(subsystem: "com.diego.dictationapp", category: "SystemAudioTap")
    private let queue = DispatchQueue(label: "com.diego.dictationapp.meeting.systemtap")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var buffersDelivered = 0

    /// Called on the capture queue with a safely-owned PCM buffer.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() throws {
        // 1) Global tap: all processes' output, excluding our own (dictation sounds etc).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "DictationApp Meeting Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else { throw SystemAudioTapError.tapCreation(err) }
        tapID = tap

        // 2) Tap stream format.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            teardown()
            throw SystemAudioTapError.formatUnavailable(err)
        }
        tapFormat = format

        // Normalize to the standard format (float32 deinterleaved) AVAudioFile expects.
        let out = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                                channels: format.channelCount) ?? format
        outputFormat = out
        converter = (format == out) ? nil : AVAudioConverter(from: format, to: out)

        // 3) Private aggregate device wrapping only the tap.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "DictationApp Meeting Aggregate",
            kAudioAggregateDeviceUIDKey as String: "com.diego.dictationapp.meeting.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [[String: Any]](),
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard err == noErr, aggregate != kAudioObjectUnknown else {
            teardown()
            throw SystemAudioTapError.aggregateCreation(err)
        }
        aggregateID = aggregate

        // 4) IOProc: input buffers carry the tap audio.
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            self?.handleIO(inInputData)
        }
        guard err == noErr, ioProcID != nil else {
            teardown()
            throw SystemAudioTapError.ioProcCreation(err)
        }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else {
            teardown()
            throw SystemAudioTapError.startFailed(err)
        }
        log.info("System audio tap started: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, interleaved=\(format.isInterleaved, privacy: .public)")
        NSLog("DictationApp: [TAP] started %.0fHz %dch interleaved=%d", format.sampleRate, format.channelCount, format.isInterleaved ? 1 : 0)
    }

    func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        teardown()
        log.info("System audio tap stopped")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        converter = nil
        tapFormat = nil
        outputFormat = nil
    }

    private func handleIO(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat, let outputFormat,
              let raw = AVAudioPCMBuffer(pcmFormat: tapFormat,
                                         bufferListNoCopy: inputData,
                                         deallocator: nil),
              raw.frameLength > 0 else { return }

        let delivered: AVAudioPCMBuffer?
        if let converter {
            let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: raw.frameLength)
            if let out {
                var fed = false
                var convErr: NSError?
                converter.convert(to: out, error: &convErr) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return raw
                }
                delivered = (convErr == nil && out.frameLength > 0) ? out : nil
            } else {
                delivered = nil
            }
        } else {
            delivered = raw.meetingCopy()   // bufferListNoCopy memory is only valid inside the IO cycle
        }

        if let delivered {
            buffersDelivered += 1
            if buffersDelivered == 1 || buffersDelivered % 200 == 0 {
                NSLog("DictationApp: [TAP] buffer %d rms=%.6f", buffersDelivered, delivered.meetingRMS)
            }
            onBuffer?(delivered)
        }
    }
}
