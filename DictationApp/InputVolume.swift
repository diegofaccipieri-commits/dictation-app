import CoreAudio
import Foundation

// Other apps (Teams, Zoom, FaceTime with automatic level adjustment) keep pulling the
// macOS input volume of the microphone down, which halves what Whisper receives.
// Before every capture, push the default input device back to 100%.
enum InputVolume {
    static func ensureMax(context: String) {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return }

        var raised: [String] = []
        // Element 0 is the master control; 1 and 2 are per-channel (what USB mics expose).
        for element in [UInt32(0), 1, 2] {
            var volAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                        mScope: kAudioObjectPropertyScopeInput,
                                                        mElement: element)
            guard AudioObjectHasProperty(device, &volAddress) else { continue }
            var current = Float32(0)
            var volSize = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &volAddress, 0, nil, &volSize, &current) == noErr,
                  current < 0.99 else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &volAddress, &settable) == noErr, settable.boolValue else { continue }
            var target = Float32(1.0)
            if AudioObjectSetPropertyData(device, &volAddress, 0, nil, volSize, &target) == noErr {
                raised.append(String(format: "ch%d %.0f%%", element, current * 100))
            }
        }
        guard !raised.isEmpty else { return }
        let name = deviceName(device)
        NSLog("DictationApp: [INPUT] %@ volume raised to 100%% (%@) before %@", name, raised.joined(separator: ", "), context)
        DictationDiagnostics.record("input_volume_raised", fields: [
            "device": name, "previous": raised.joined(separator: ", "), "context": context
        ])
    }

    static func deviceName(_ device: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return "?" }
        return name as String
    }
}
