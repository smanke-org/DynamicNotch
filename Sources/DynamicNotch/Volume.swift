import AudioToolbox
import CoreAudio
import Foundation

/// System output volume for the current default device, kept live via CoreAudio listeners
/// (so the slider follows the keyboard volume keys and device switches).
final class VolumeController: ObservableObject {
    @Published private(set) var volume: Float = 0
    @Published private(set) var muted = false
    @Published private(set) var adjustable = false
    @Published private(set) var deviceName = ""

    private var device = AudioDeviceID(0)
    private var listener: AudioObjectPropertyListenerBlock?

    private var defaultAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var volumeAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    init() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, .main) { [weak self] _, _ in
            self?.attach()
        }
        attach()
    }

    func set(_ value: Float) {
        var v = Float32(min(max(value, 0), 1))
        AudioObjectSetPropertyData(device, &volumeAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        volume = v
        if muted && v > 0 { setMuted(false) }
    }

    func setMuted(_ on: Bool) {
        var m: UInt32 = on ? 1 : 0
        guard AudioObjectHasProperty(device, &muteAddr) else { return }
        AudioObjectSetPropertyData(device, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        muted = on
    }

    private func attach() {
        if device != 0, let l = listener {
            AudioObjectRemovePropertyListenerBlock(device, &volumeAddr, .main, l)
            AudioObjectRemovePropertyListenerBlock(device, &muteAddr, .main, l)
        }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &size, &id)
        device = id

        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.read() }
        listener = l
        AudioObjectAddPropertyListenerBlock(device, &volumeAddr, .main, l)
        AudioObjectAddPropertyListenerBlock(device, &muteAddr, .main, l)
        deviceName = Self.name(of: device)
        read()
    }

    private func read() {
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var settable = DarwinBoolean(false)
        adjustable = AudioObjectHasProperty(device, &volumeAddr)
            && AudioObjectGetPropertyData(device, &volumeAddr, 0, nil, &size, &v) == noErr
            && AudioObjectIsPropertySettable(device, &volumeAddr, &settable) == noErr
            && settable.boolValue
        volume = v

        var m = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddr),
           AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &size, &m) == noErr {
            muted = m != 0
        } else {
            muted = false
        }
    }

    private static func name(of device: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
    }
}
