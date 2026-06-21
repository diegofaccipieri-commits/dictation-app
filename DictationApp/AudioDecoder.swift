import Foundation
import AVFoundation

// Decodes any AVFoundation-readable container (including Voice Memos' .qta, which is a
// QuickTime audio wrapper) into a temporary 16 kHz mono 16-bit WAV that WhisperKit/whisper.cpp
// can read directly. All audio tracks are mixed down so multi-track recordings (e.g. calls)
// keep every speaker. Written by streaming so multi-hour recordings don't blow up memory.
enum AudioDecoder {

    enum DecodeError: Error {
        case noAudioTrack
        case readerFailed(String)
    }

    /// Decode `src` to a temporary .wav and return its URL. Caller is responsible for deleting it.
    static func decodeToWav(_ src: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw DecodeError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Mix every audio track down to one mono stream.
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecodeError.readerFailed("cannot add output") }
        reader.add(output)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-decode-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        // Write a placeholder header; sizes are patched in once we know the data length.
        handle.write(wavHeader(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataSize: 0))

        guard reader.startReading() else {
            throw DecodeError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        var dataSize: Int = 0
        while let sample = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                let length = CMBlockBufferGetDataLength(block)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                   destination: raw.baseAddress!)
                }
                handle.write(data)
                dataSize += length
            }
            CMSampleBufferInvalidate(sample)
        }

        guard reader.status == .completed else {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw DecodeError.readerFailed(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")
        }

        // Patch RIFF chunk size (offset 4) and data subchunk size (offset 40).
        try handle.seek(toOffset: 4)
        handle.write(uint32LE(UInt32(36 + dataSize)))
        try handle.seek(toOffset: 40)
        handle.write(uint32LE(UInt32(dataSize)))

        return tmp
    }

    /// Decode `src` to mono 16 kHz Float samples (all audio tracks mixed). Held fully in
    /// memory, which speaker diarization requires anyway.
    static func decodeToSamples(_ src: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: src)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw DecodeError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecodeError.readerFailed("cannot add output") }
        reader.add(output)
        guard reader.startReading() else {
            throw DecodeError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                let length = CMBlockBufferGetDataLength(block)
                let count = length / MemoryLayout<Float>.size
                var chunk = [Float](repeating: 0, count: count)
                chunk.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                   destination: raw.baseAddress!)
                }
                samples.append(contentsOf: chunk)
            }
            CMSampleBufferInvalidate(sample)
        }
        guard reader.status == .completed else {
            throw DecodeError.readerFailed(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")
        }
        return samples
    }

    // MARK: - WAV header

    private static func wavHeader(sampleRate: Int32, channels: Int16, bitsPerSample: Int16, dataSize: Int32) -> Data {
        var data = Data()
        let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        data.append(contentsOf: "RIFF".utf8)
        data.append(uint32LE(UInt32(36 + dataSize)))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(uint32LE(16))
        data.append(uint16LE(1))                       // PCM
        data.append(uint16LE(UInt16(channels)))
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(byteRate)))
        data.append(uint16LE(UInt16(blockAlign)))
        data.append(uint16LE(UInt16(bitsPerSample)))
        data.append(contentsOf: "data".utf8)
        data.append(uint32LE(UInt32(dataSize)))
        return data
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
}
