import CoreAudio
import AudioToolbox

/// The Mac's output volume (the one the volume keys change), via CoreAudio.
/// Fast, no AppleScript. Returns nil for outputs without a volume control (some HDMI/USB devices).
enum SystemVolume {
    private static func device() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// 0...1, or 0 when muted.
    static func get() -> Double? {
        guard let dev = device() else { return nil }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var vol = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr else { return nil }
        var muteAddr = address(kAudioDevicePropertyMute), muted = UInt32(0), mSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(dev, &muteAddr),
           AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &mSize, &muted) == noErr, muted != 0 { return 0 }
        return Double(vol)
    }

    /// Sets the volume and unmutes when it's above zero.
    static func set(_ v: Double) {
        guard let dev = device() else { return }
        var vol = Float32(max(0, min(1, v)))
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(dev, &addr) else { return }
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        var muteAddr = address(kAudioDevicePropertyMute), settable = DarwinBoolean(false)
        if vol > 0, AudioObjectHasProperty(dev, &muteAddr),
           AudioObjectIsPropertySettable(dev, &muteAddr, &settable) == noErr, settable.boolValue {
            var off = UInt32(0)
            AudioObjectSetPropertyData(dev, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off)
        }
    }
}
