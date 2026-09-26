import XCTest
import CoreAudio

// MARK: - Fake CoreAudio

/// In-memory stand-in for CoreAudio. Behaves like the real system where it matters:
/// setting a default echoes back through the default-device listener, and removing the
/// default device makes "macOS" fall back to another one.
final class FakeAudioDeviceService: AudioDeviceControlling {
    var onDeviceListChanged: (() -> Void)?
    var onDefaultDeviceChanged: (() -> Void)?
    var onDeviceStateChanged: (() -> Void)?

    var devices: [AudioDevice] = []
    var defaultOutput: AudioObjectID?
    var defaultInput: AudioObjectID?
    var volume: Float = 0.5
    var volumeSettable = true
    var muteSettable = true
    var mutedIds: Set<AudioObjectID> = []
    var callModeIds: Set<AudioObjectID> = []
    /// The next N calls to `setDefaultDevice` fail, like a Bluetooth device that isn't ready.
    var failingSets = 0
    /// Devices that always refuse to become the default.
    var refusedIds: Set<AudioObjectID> = []
    private(set) var failedSetCount = 0
    private(set) var setCalls: [(id: AudioObjectID, type: AudioDeviceType)] = []

    init(devices: [AudioDevice], output: AudioObjectID?, input: AudioObjectID?) {
        self.devices = devices
        self.defaultOutput = output
        self.defaultInput = input
    }

    func startListening() {}
    func getDevices() -> [AudioDevice] { devices }

    func getCurrentDefaultDevice(type: AudioDeviceType) -> AudioObjectID? {
        type == .input ? defaultInput : defaultOutput
    }

    @discardableResult
    func setDefaultDevice(_ deviceId: AudioObjectID, type: AudioDeviceType) -> Bool {
        if failingSets > 0 || refusedIds.contains(deviceId) {
            failingSets = max(0, failingSets - 1)
            failedSetCount += 1
            return false
        }
        setCalls.append((deviceId, type))
        setDefault(deviceId, type: type)
        return true
    }

    func getOutputVolume() -> Float { volume }
    func isOutputVolumeSettable() -> Bool { volumeSettable }
    func setOutputVolume(_ volume: Float) { self.volume = volume }
    func isOutputMuteSettable() -> Bool { muteSettable }

    func setOutputMuted(_ muted: Bool) {
        guard let defaultOutput else { return }
        if muted { mutedIds.insert(defaultOutput) } else { mutedIds.remove(defaultOutput) }
    }

    func isDeviceMuted(_ deviceId: AudioObjectID, type: AudioDeviceType) -> Bool {
        mutedIds.contains(deviceId) || (type == .output && deviceId == defaultOutput && volume < 0.01)
    }

    func isInCallMode(_ device: AudioDevice) -> Bool { callModeIds.contains(device.id) }

    // MARK: Simulation

    /// Plugs devices in. Like macOS, this can also make one of them the default.
    func connect(_ newDevices: AudioDevice..., macOSSwitchesTo systemPick: AudioDevice? = nil) {
        devices.append(contentsOf: newDevices)
        onDeviceListChanged?()
        if let systemPick {
            setDefault(systemPick.id, type: systemPick.type)
        }
    }

    /// Unplugs a device. If it was a default, macOS falls back to the first remaining device.
    func disconnect(uid: String) {
        devices.removeAll { $0.uid == uid }
        onDeviceListChanged?()
        for type in [AudioDeviceType.output, .input] {
            let current = getCurrentDefaultDevice(type: type)
            if let current, !devices.contains(where: { $0.id == current && $0.type == type }),
               let fallback = devices.first(where: { $0.type == type }) {
                setDefault(fallback.id, type: type)
            }
        }
    }

    /// macOS switches to a device before the device-list event for it arrives.
    func connectDefaultFirst(_ device: AudioDevice) {
        devices.append(device)
        setDefault(device.id, type: device.type)
        DispatchQueue.main.async { [weak self] in self?.onDeviceListChanged?() }
    }

    /// A device-list event with no visible change, e.g. a call app creating a hidden aggregate.
    func publishHiddenDeviceChange() {
        onDeviceListChanged?()
    }

    /// The user picks a device in Control Center or System Settings.
    func userPicks(_ device: AudioDevice) {
        setDefault(device.id, type: device.type)
    }

    private func setDefault(_ id: AudioObjectID, type: AudioDeviceType) {
        // Like CoreAudio, only an actual change notifies.
        guard getCurrentDefaultDevice(type: type) != id else { return }
        if type == .input { defaultInput = id } else { defaultOutput = id }
        // CoreAudio delivers listener callbacks on the main queue after the change.
        DispatchQueue.main.async { [weak self] in self?.onDefaultDeviceChanged?() }
    }
}

// MARK: - Recording notifier

@MainActor
final class RecordingNotifier: DeviceChangeNotifying {
    struct Change: Equatable {
        let output: String?
        let input: String?
        let reason: String
    }

    private(set) var changes: [Change] = []
    private(set) var lowBattery: [String] = []

    func postDeviceChange(output: AudioDevice?, input: AudioDevice?, reason: String) {
        changes.append(Change(output: output?.name, input: input?.name, reason: reason))
    }

    func postLowBattery(device: AudioDevice, battery: DeviceBattery) {
        lowBattery.append(device.name)
    }
}

// MARK: - Fixtures

enum Fixture {
    static let speakers = AudioDevice(id: 10, uid: "builtin-out", name: "MacBook Pro Speakers", type: .output, transport: .builtIn)
    static let studioDisplay = AudioDevice(id: 11, uid: "studio-out", name: "Studio Display Speakers", type: .output, transport: .usb)
    static let builtInMic = AudioDevice(id: 20, uid: "builtin-in", name: "MacBook Pro Microphone", type: .input, transport: .builtIn)
    static let usbMic = AudioDevice(id: 21, uid: "shure", name: "Shure MV7+", type: .input, transport: .usb)
    static let airPodsMax = AudioDevice(id: 30, uid: "max:output", name: "AirPods Max", type: .output, transport: .bluetooth,
                                        modelUID: "201f 4c", isHeadphoneTerminal: true)
    static let airPodsMaxMic = AudioDevice(id: 31, uid: "max:input", name: "AirPods Max", type: .input, transport: .bluetooth,
                                           modelUID: "201f 4c")
    static let airPodsPro = AudioDevice(id: 32, uid: "pro:output", name: "AirPods Pro", type: .output, transport: .bluetooth,
                                        modelUID: "200e 4c", isHeadphoneTerminal: true)

    /// A USB headset: one CoreAudio device, so both halves share an ID and a UID.
    static let usbHeadsetOut = AudioDevice(id: 40, uid: "usb-headset", name: "Logitech USB Headset", type: .output,
                                           transport: .usb, isHeadphoneTerminal: true)
    static let usbHeadsetIn = AudioDevice(id: 40, uid: "usb-headset", name: "Logitech USB Headset", type: .input, transport: .usb)

    static func battery(_ name: String, _ part: AccessoryBattery.Part, _ level: Int, charging: Bool = false,
                        product: Int = 0x201F) -> AccessoryBattery {
        AccessoryBattery(name: name, productID: product, vendorID: 0x4C, part: part, level: level,
                         isCharging: charging, lowWarningLevel: 20)
    }
}

/// Defaults suites for tests, never the real app settings. Names come from a small fixed set
/// and are wiped when handed out: cfprefsd writes a plist back after any deletion, so unique
/// per-test names would leave a new file in ~/Library/Preferences on every run.
func makeTestDefaults(_ name: String = "default") -> UserDefaults {
    let suite = "AudioPriorityBarTests.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

extension XCTestCase {
    /// A PriorityManager on a freshly wiped test suite.
    func makePriorityManager(_ name: String = "default", legacy: UserDefaults? = nil) -> (PriorityManager, UserDefaults) {
        let defaults = makeTestDefaults(name)
        return (PriorityManager(defaults: defaults, legacyDefaults: legacy), defaults)
    }
}

// MARK: - Async helpers

extension XCTestCase {
    /// Polls until `condition` holds, failing after `timeout`. Event handling is debounced and
    /// hops through the main actor, so assertions have to wait for it to settle.
    @MainActor
    func waitUntil(timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Condition not met within \(timeout)s", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Lets pending debounced work run, for asserting that something did *not* happen.
    func settle(_ seconds: TimeInterval = 0.2) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
