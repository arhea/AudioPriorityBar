import Foundation
import CoreAudio
import AudioToolbox

/// The CoreAudio operations `AudioManager` relies on. Tests substitute a fake so the
/// switching logic can be exercised without touching real devices.
protocol AudioDeviceControlling: AnyObject {
    var onDeviceListChanged: (() -> Void)? { get set }
    var onDefaultDeviceChanged: (() -> Void)? { get set }
    var onDeviceStateChanged: (() -> Void)? { get set }
    func startListening()
    func getDevices() -> [AudioDevice]
    func getCurrentDefaultDevice(type: AudioDeviceType) -> AudioObjectID?
    @discardableResult func setDefaultDevice(_ deviceId: AudioObjectID, type: AudioDeviceType) -> Bool
    func getOutputVolume() -> Float
    func isOutputVolumeSettable() -> Bool
    func setOutputVolume(_ volume: Float)
    func isOutputMuteSettable() -> Bool
    func setOutputMuted(_ muted: Bool)
    func isDeviceMuted(_ deviceId: AudioObjectID, type: AudioDeviceType) -> Bool
    func isInCallMode(_ device: AudioDevice) -> Bool
}

class AudioDeviceService: AudioDeviceControlling {
    /// Devices were added or removed.
    var onDeviceListChanged: (() -> Void)?
    /// The default input or output device changed (by this app, macOS, or another app).
    var onDefaultDeviceChanged: (() -> Void)?
    /// Mute, volume, or sample rate changed on some device.
    var onDeviceStateChanged: (() -> Void)?

    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteVolumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var monitoredDeviceIds: Set<AudioObjectID> = []
    private var isListening = false

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func getDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []
        for deviceId in allDeviceIds() {
            if let inputDevice = createDevice(id: deviceId, type: .input) {
                devices.append(inputDevice)
            }
            if let outputDevice = createDevice(id: deviceId, type: .output) {
                devices.append(outputDevice)
            }
        }
        return devices
    }

    func getCurrentDefaultDevice(type: AudioDeviceType) -> AudioObjectID? {
        let selector = type == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice
        let deviceId: AudioObjectID? = getValue(Self.systemObject, selector)
        guard let deviceId, deviceId != kAudioObjectUnknown else { return nil }
        return deviceId
    }

    /// Sets the default device. For output, the alert/system-sound device is moved too when it
    /// was following the previous default; macOS does that when you switch in Control Center,
    /// but not when an app switches through CoreAudio.
    @discardableResult
    func setDefaultDevice(_ deviceId: AudioObjectID, type: AudioDeviceType) -> Bool {
        guard deviceId != kAudioObjectUnknown else { return false }

        if type == .input {
            return setValue(Self.systemObject, kAudioHardwarePropertyDefaultInputDevice, deviceId)
        }

        let previousOutput = getCurrentDefaultDevice(type: .output)
        let systemOutput: AudioObjectID? = getValue(Self.systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice)
        let didSet = setValue(Self.systemObject, kAudioHardwarePropertyDefaultOutputDevice, deviceId)

        if didSet, systemOutput == nil || systemOutput == previousOutput {
            setValue(Self.systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice, deviceId)
        }
        return didSet
    }

    // MARK: - Volume and mute

    func getOutputVolume() -> Float {
        guard let deviceId = getCurrentDefaultDevice(type: .output) else { return 0 }
        return getDeviceVolume(deviceId) ?? 0
    }

    /// Whether the current output exposes a volume the app can change. HDMI/DisplayPort
    /// outputs and some USB DACs don't, and writes to them silently fail.
    func isOutputVolumeSettable() -> Bool {
        guard let deviceId = getCurrentDefaultDevice(type: .output) else { return false }
        return isSettable(deviceId, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }

    func setOutputVolume(_ volume: Float) {
        guard let deviceId = getCurrentDefaultDevice(type: .output) else { return }
        let clamped = Float32(max(0, min(1, volume)))
        setValue(deviceId, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, clamped, scope: kAudioDevicePropertyScopeOutput)
    }

    func isOutputMuteSettable() -> Bool {
        guard let deviceId = getCurrentDefaultDevice(type: .output) else { return false }
        return isSettable(deviceId, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    }

    func setOutputMuted(_ muted: Bool) {
        guard let deviceId = getCurrentDefaultDevice(type: .output) else { return }
        setValue(deviceId, kAudioDevicePropertyMute, UInt32(muted ? 1 : 0), scope: kAudioDevicePropertyScopeOutput)
    }

    func isDeviceMuted(_ deviceId: AudioObjectID, type: AudioDeviceType) -> Bool {
        let scope: AudioObjectPropertyScope = type == .input
            ? kAudioDevicePropertyScopeInput
            : kAudioDevicePropertyScopeOutput

        // Element 0 is the main channel; some devices only publish mute on channel 1.
        for element in [kAudioObjectPropertyElementMain, 1] {
            let muted: UInt32? = getValue(deviceId, kAudioDevicePropertyMute, scope: scope, element: element)
            if let muted, muted != 0 {
                return true
            }
        }

        // Some devices report a zero volume instead of a mute flag.
        if type == .output, let volume = getDeviceVolume(deviceId), volume < 0.01 {
            return true
        }
        return false
    }

    func getDeviceVolume(_ deviceId: AudioObjectID) -> Float? {
        let volume: Float32? = getValue(deviceId, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        return volume.map { Float($0) }
    }

    // MARK: - Listeners

    func startListening() {
        guard !isListening else { return }
        isListening = true

        let deviceListBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Re-register mute/volume listeners for the new device set.
            self?.updateMuteVolumeListeners()
            self?.onDeviceListChanged?()
        }
        deviceListListenerBlock = deviceListBlock
        addListener(Self.systemObject, kAudioHardwarePropertyDevices, deviceListBlock)

        let defaultDeviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDefaultDeviceChanged?()
        }
        defaultDeviceListenerBlock = defaultDeviceBlock
        addListener(Self.systemObject, kAudioHardwarePropertyDefaultInputDevice, defaultDeviceBlock)
        addListener(Self.systemObject, kAudioHardwarePropertyDefaultOutputDevice, defaultDeviceBlock)

        updateMuteVolumeListeners()
    }

    func updateMuteVolumeListeners() {
        removeMuteVolumeListeners()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDeviceStateChanged?()
        }
        muteVolumeListenerBlock = block

        for deviceId in allDeviceIds() {
            addListener(deviceId, kAudioDevicePropertyMute, block, scope: kAudioDevicePropertyScopeOutput)
            addListener(deviceId, kAudioDevicePropertyMute, block, scope: kAudioDevicePropertyScopeInput)
            addListener(deviceId, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, block, scope: kAudioDevicePropertyScopeOutput)
            // Bluetooth headphones drop their sample rate when they switch to call mode.
            addListener(deviceId, kAudioDevicePropertyNominalSampleRate, block)
            monitoredDeviceIds.insert(deviceId)
        }
    }

    private func removeMuteVolumeListeners() {
        guard let block = muteVolumeListenerBlock else { return }

        for deviceId in monitoredDeviceIds {
            removeListener(deviceId, kAudioDevicePropertyMute, block, scope: kAudioDevicePropertyScopeOutput)
            removeListener(deviceId, kAudioDevicePropertyMute, block, scope: kAudioDevicePropertyScopeInput)
            removeListener(deviceId, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, block, scope: kAudioDevicePropertyScopeOutput)
            removeListener(deviceId, kAudioDevicePropertyNominalSampleRate, block)
        }

        monitoredDeviceIds.removeAll()
        muteVolumeListenerBlock = nil
    }

    func stopListening() {
        removeMuteVolumeListeners()

        if let block = deviceListListenerBlock {
            removeListener(Self.systemObject, kAudioHardwarePropertyDevices, block)
        }
        if let block = defaultDeviceListenerBlock {
            removeListener(Self.systemObject, kAudioHardwarePropertyDefaultInputDevice, block)
            removeListener(Self.systemObject, kAudioHardwarePropertyDefaultOutputDevice, block)
        }
        deviceListListenerBlock = nil
        defaultDeviceListenerBlock = nil
        isListening = false
    }

    deinit {
        stopListening()
    }

    // MARK: - Device discovery

    private func allDeviceIds() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.systemObject, &address, 0, nil, &dataSize) == noErr else { return [] }

        var deviceIds = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.systemObject, &address, 0, nil, &dataSize, &deviceIds) == noErr else { return [] }
        return deviceIds
    }

    private func createDevice(id: AudioObjectID, type: AudioDeviceType) -> AudioDevice? {
        let scope: AudioObjectPropertyScope = type == .input
            ? kAudioDevicePropertyScopeInput
            : kAudioDevicePropertyScopeOutput

        guard hasStreams(deviceId: id, scope: scope) else { return nil }

        // Private aggregates (Zoom, Teams, screen recorders) are hidden from macOS's own
        // pickers, and some devices refuse to be the default. Listing either lets the app
        // "select" a device that can't actually carry audio.
        let isHidden: UInt32? = getValue(id, kAudioDevicePropertyIsHidden)
        if isHidden == 1 { return nil }
        let canBeDefault: UInt32? = getValue(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: scope)
        if canBeDefault == 0 { return nil }

        guard let name = getString(id, kAudioDevicePropertyDeviceNameCFString) else { return nil }
        guard let uid = getString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let transportValue: UInt32? = getValue(id, kAudioDevicePropertyTransportType)
        let transport = transportValue.map(AudioTransport.init(coreAudioValue:)) ?? .other
        let isHeadphoneTerminal = type == .output
            && firstStreamTerminalType(deviceId: id, scope: scope) == kAudioStreamTerminalTypeHeadphones

        return AudioDevice(id: id, uid: uid, name: name, type: type, transport: transport,
                           modelUID: getString(id, kAudioDevicePropertyModelUID), isHeadphoneTerminal: isHeadphoneTerminal)
    }

    private func firstStreamTerminalType(deviceId: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32? {
        var address = Self.address(kAudioDevicePropertyStreams, scope: scope)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceId, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return nil }
        var streamIds = [AudioStreamID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(deviceId, &address, 0, nil, &dataSize, &streamIds) == noErr,
              let first = streamIds.first else { return nil }
        return getValue(first, kAudioStreamPropertyTerminalType)
    }

    /// A Bluetooth output that has dropped to a narrowband rate (≤ 24 kHz) while it supports
    /// 44.1 kHz or more is in call mode (HFP): an app is using its microphone, and playback
    /// quality falls until the mic is released.
    func isInCallMode(_ device: AudioDevice) -> Bool {
        guard device.type == .output, device.transport == .bluetooth, device.isConnected else { return false }
        let nominal: Float64? = getValue(device.id, kAudioDevicePropertyNominalSampleRate)
        guard let nominal, nominal > 0, nominal <= 24_000 else { return false }
        return maxAvailableSampleRate(device.id) >= 44_100
    }

    private func maxAvailableSampleRate(_ deviceId: AudioObjectID) -> Float64 {
        var address = Self.address(kAudioDevicePropertyAvailableNominalSampleRates)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceId, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return 0 }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(dataSize) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(deviceId, &address, 0, nil, &dataSize, &ranges) == noErr else { return 0 }
        return ranges.map(\.mMaximum).max() ?? 0
    }

    private func hasStreams(deviceId: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = Self.address(kAudioDevicePropertyStreams, scope: scope)
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceId, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    // MARK: - CoreAudio helpers

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func getValue<T>(
        _ objectId: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> T? where T: Numeric {
        var address = Self.address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(objectId, &address) else { return nil }
        var value: T = 0
        var dataSize = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectGetPropertyData(objectId, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    @discardableResult
    private func setValue<T>(
        _ objectId: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ value: T,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool where T: Numeric {
        var address = Self.address(selector, scope: scope)
        let status = withUnsafeBytes(of: value) { buffer in
            AudioObjectSetPropertyData(objectId, &address, 0, nil, UInt32(buffer.count), buffer.baseAddress!)
        }
        return status == noErr
    }

    private func isSettable(_ objectId: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> Bool {
        var address = Self.address(selector, scope: scope)
        guard AudioObjectHasProperty(objectId, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(objectId, &address, &settable) == noErr && settable.boolValue
    }

    private func getString(_ objectId: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        guard AudioObjectHasProperty(objectId, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectId, &address, 0, nil, &dataSize, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func addListener(
        _ objectId: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ block: @escaping AudioObjectPropertyListenerBlock,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        var address = Self.address(selector, scope: scope)
        AudioObjectAddPropertyListenerBlock(objectId, &address, DispatchQueue.main, block)
    }

    private func removeListener(
        _ objectId: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ block: @escaping AudioObjectPropertyListenerBlock,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        var address = Self.address(selector, scope: scope)
        AudioObjectRemovePropertyListenerBlock(objectId, &address, DispatchQueue.main, block)
    }
}
