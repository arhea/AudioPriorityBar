import SwiftUI
import CoreAudio
import os

@MainActor
class AudioManager: ObservableObject {
    @Published var inputDevices: [AudioDevice] = []
    @Published var speakerDevices: [AudioDevice] = []
    @Published var headphoneDevices: [AudioDevice] = []
    @Published var hiddenInputDevices: [AudioDevice] = []
    @Published var hiddenSpeakerDevices: [AudioDevice] = []
    @Published var hiddenHeadphoneDevices: [AudioDevice] = []
    @Published var currentInputId: AudioObjectID?
    @Published var currentOutputId: AudioObjectID?
    @Published var currentMode: OutputCategory = .speaker
    @Published var volume: Float = 0
    @Published var isVolumeSettable: Bool = true
    @Published var isMuteSettable: Bool = true
    /// Shows disconnected and ignored devices inline so their priority can be edited.
    @Published var isShowingAllDevices: Bool = false
    @Published var isCustomMode: Bool = false
    @Published var mutedDeviceIds: Set<AudioObjectID> = []
    @Published var isActiveOutputMuted: Bool = false
    @Published var isActiveInputMuted: Bool = false
    /// Battery per device, keyed by `listID`, for Bluetooth devices that report one.
    @Published var batteries: [String: DeviceBattery] = [:]
    /// Bluetooth outputs currently in call mode (HFP) because their mic is in use.
    @Published var callModeOutputIds: Set<AudioObjectID> = []
    /// Don't auto-select Bluetooth microphones while another mic is available, so Bluetooth
    /// headphones stay in high-quality playback instead of dropping to call mode.
    @Published private(set) var keepsBluetoothHighQuality: Bool = true

    let priorityManager: PriorityManager
    private let deviceService: AudioDeviceControlling?
    private let batteryMonitor: BatteryMonitor?
    private let log = Logger(subsystem: "app.audioprioritybar", category: "switching")
    private var lowBatteryNotified: Set<String> = []
    private var pendingRetry: Task<Void, Never>?
    private var lastOutputChange: Date = .distantPast
    private let notifications: DeviceChangeNotifying?

    private var connectedDevices: [AudioDevice] = []
    private var connectedDeviceUIDs: Set<String> = []
    /// Devices from the previous device-list event, to work out what connected or left.
    private var previousConnectedDevices: [AudioDevice] = []
    /// The defaults we last saw and reported, so each change is announced once.
    private var reportedOutputId: AudioObjectID?
    private var reportedInputId: AudioObjectID?

    private var pendingDeviceListRefresh: Task<Void, Never>?
    private var lastDeviceListChange: Date = .distantPast
    private var lastDeviceListCause: ChangeCause = .startup

    /// Bluetooth devices publish their input and output halves separately; wait for both.
    private let deviceListDebounce: TimeInterval
    /// macOS often switches to a newly connected device a beat after publishing it. A default
    /// change inside this window is macOS, not the user, so priorities still apply.
    private let connectionGracePeriod: TimeInterval
    /// How long to wait before retrying a device that refused to become the default.
    private let retryDelay: TimeInterval

    enum ChangeCause {
        case startup
        case userAction
        case devicesChanged(connected: [AudioDevice], disconnected: [AudioDevice])
        case external
    }

    /// The app's manager, wired to CoreAudio, IOKit, and notifications.
    convenience init() {
        self.init(
            priorityManager: PriorityManager(),
            deviceService: AudioDeviceService(),
            batteryMonitor: BatteryMonitor(),
            notifications: NotificationManager.shared
        )
    }

    /// Pass `nil` for `deviceService` to get an inert manager (previews); tests pass fakes
    /// and shorter timings.
    init(
        priorityManager: PriorityManager,
        deviceService: AudioDeviceControlling?,
        batteryMonitor: BatteryMonitor?,
        notifications: DeviceChangeNotifying?,
        deviceListDebounce: TimeInterval = 0.25,
        connectionGracePeriod: TimeInterval = 2,
        retryDelay: TimeInterval = 0.8
    ) {
        self.priorityManager = priorityManager
        self.deviceService = deviceService
        self.batteryMonitor = batteryMonitor
        self.notifications = notifications
        self.deviceListDebounce = deviceListDebounce
        self.connectionGracePeriod = connectionGracePeriod
        self.retryDelay = retryDelay
        currentMode = priorityManager.currentMode
        isCustomMode = priorityManager.isCustomMode
        keepsBluetoothHighQuality = priorityManager.keepsBluetoothHighQuality

        guard deviceService != nil else { return }
        refreshDevices()
        previousConnectedDevices = connectedDevices
        setupListeners()
        if !isCustomMode {
            applyHighestPriorityInput()
            applyHighestPriorityOutput()
        }
        syncCurrentDevices(cause: .startup)
    }

    // MARK: - Derived state

    var currentOutputDevice: AudioDevice? {
        guard let currentOutputId else { return nil }
        return connectedDevices.first { $0.id == currentOutputId && $0.type == .output }
    }

    var currentInputDevice: AudioDevice? {
        guard let currentInputId else { return nil }
        return connectedDevices.first { $0.id == currentInputId && $0.type == .input }
    }

    /// Category of the device actually playing, which can differ from `currentMode` in manual mode.
    var currentOutputCategory: OutputCategory {
        guard let device = currentOutputDevice else { return currentMode }
        return priorityManager.getCategory(for: device)
    }

    var menuBarSymbol: String {
        if isActiveOutputMuted { return "speaker.slash.fill" }
        return currentOutputCategory == .headphone ? "headphones" : "speaker.wave.3.fill"
    }

    var menuBarVariableValue: Double? {
        menuBarSymbol == "speaker.wave.3.fill" ? Double(volume) : nil
    }

    var hiddenDeviceCount: Int {
        hiddenInputDevices.count + hiddenSpeakerDevices.count + hiddenHeadphoneDevices.count
    }

    func isDeviceConnected(_ device: AudioDevice) -> Bool {
        connectedDeviceUIDs.contains(device.uid)
    }

    func isDeviceMuted(_ device: AudioDevice) -> Bool {
        mutedDeviceIds.contains(device.id)
    }

    func battery(for device: AudioDevice) -> DeviceBattery? {
        batteries[device.listID]
    }

    func isInCallMode(_ device: AudioDevice) -> Bool {
        device.type == .output && callModeOutputIds.contains(device.id)
    }

    /// The playing output is in call mode.
    var isCurrentOutputInCallMode: Bool {
        currentOutputId.map { callModeOutputIds.contains($0) } ?? false
    }

    /// When the playing Bluetooth headphones are in call mode because they're also the
    /// default mic, the mic to switch to so they return to high quality.
    var callModeFix: AudioDevice? {
        guard isCurrentOutputInCallMode, let input = currentInputDevice, input.transport == .bluetooth,
              input.name == currentOutputDevice?.name else { return nil }
        return autoSelectionCandidates(input: true).first { $0.transport != .bluetooth }
    }

    /// A Bluetooth mic that auto-selection passes over because of the high-quality setting.
    func isSkippedForQuality(_ device: AudioDevice) -> Bool {
        keepsBluetoothHighQuality && device.type == .input && device.transport == .bluetooth
            && connectedDevices.contains { $0.type == .input && $0.transport != .bluetooth }
    }

    func setKeepsBluetoothHighQuality(_ enabled: Bool) {
        keepsBluetoothHighQuality = enabled
        priorityManager.keepsBluetoothHighQuality = enabled
        if !isCustomMode {
            applyHighestPriorityInput()
        }
        syncCurrentDevices(cause: .userAction)
    }

    func fixCallMode() {
        guard let fix = callModeFix else { return }
        setInputDevice(fix)
    }

    func refreshCallMode() {
        guard let deviceService else { return }
        callModeOutputIds = Set(connectedDevices.filter { deviceService.isInCallMode($0) }.map(\.id))
    }

    func refreshBatteries() {
        guard let batteryMonitor else { return }
        let all = batteryMonitor.accessoryBatteries()
        var result: [String: DeviceBattery] = [:]
        for device in connectedDevices {
            if let battery = batteryMonitor.battery(for: device, in: all) {
                result[device.listID] = battery
            }
        }
        batteries = result

        // Warn once per discharge when the headphones you're listening on run low.
        for (key, battery) in result where !battery.isLow {
            lowBatteryNotified.remove(key)
        }
        if let output = currentOutputDevice, let battery = result[output.listID], battery.isLow,
           !lowBatteryNotified.contains(output.listID) {
            lowBatteryNotified.insert(output.listID)
            notifications?.postLowBattery(device: output, battery: battery)
        }
    }

    // MARK: - Volume and mute

    func refreshVolume() {
        guard let deviceService else { return }
        volume = deviceService.getOutputVolume()
        isVolumeSettable = deviceService.isOutputVolumeSettable()
        isMuteSettable = deviceService.isOutputMuteSettable()
    }

    func setVolume(_ newVolume: Float) {
        let clamped = max(0, min(1, newVolume))
        volume = clamped
        deviceService?.setOutputVolume(clamped)
        // Dragging the slider up from zero should be enough to hear something again.
        if clamped > 0, isActiveOutputMuted, isMuteSettable {
            deviceService?.setOutputMuted(false)
        }
    }

    /// Some devices only report "muted" as a zero volume, so unmuting also restores a volume.
    func toggleOutputMute() {
        let unmuting = isActiveOutputMuted
        if isMuteSettable {
            deviceService?.setOutputMuted(!unmuting)
        }
        if unmuting && volume < 0.01 && isVolumeSettable {
            setVolume(0.25)
        }
        refreshMuteStatus()
        refreshVolume()
    }

    func refreshMuteStatus() {
        guard let deviceService else { return }
        var muted: Set<AudioObjectID> = []
        for device in connectedDevices where deviceService.isDeviceMuted(device.id, type: device.type) {
            muted.insert(device.id)
        }
        mutedDeviceIds = muted
        isActiveOutputMuted = currentOutputId.map { muted.contains($0) } ?? false
        isActiveInputMuted = currentInputId.map { muted.contains($0) } ?? false
    }

    // MARK: - Device lists

    func refreshDevices() {
        guard let deviceService else { return }
        let allConnectedDevices = deviceService.getDevices()
        priorityManager.migrateReconnectedDevices(allConnectedDevices)
        priorityManager.rememberDevices(allConnectedDevices)
        connectedDevices = allConnectedDevices
        connectedDeviceUIDs = Set(allConnectedDevices.map(\.uid))
        rebuildLists()
        currentInputId = deviceService.getCurrentDefaultDevice(type: .input)
        currentOutputId = deviceService.getCurrentDefaultDevice(type: .output)
    }

    /// Splits connected (and, when showing all devices, remembered) devices into the
    /// visible and hidden lists for each section.
    private func rebuildLists() {
        let connectedInputs = connectedDevices.filter { $0.type == .input }
        let connectedOutputs = connectedDevices.filter { $0.type == .output }

        if isShowingAllDevices {
            let connectedKeys = Set(connectedDevices.map(\.listID))
            var allInputs = connectedInputs
            var allOutputs = connectedOutputs
            for stored in priorityManager.getKnownDevices() {
                let type: AudioDeviceType = stored.isInput ? .input : .output
                let device = AudioDevice.disconnected(uid: stored.uid, name: stored.name, type: type, transport: stored.transport ?? .other,
                                                      modelUID: stored.modelUID, isHeadphoneTerminal: stored.isHeadphoneTerminal ?? false)
                guard !connectedKeys.contains(device.listID) else { continue }
                if stored.isInput {
                    allInputs.append(device)
                } else {
                    allOutputs.append(device)
                }
            }
            inputDevices = priorityManager.sortByPriority(allInputs, type: .input)
            let speakers = allOutputs.filter { priorityManager.getCategory(for: $0) == .speaker }
            let headphones = allOutputs.filter { priorityManager.getCategory(for: $0) == .headphone }
            speakerDevices = priorityManager.sortByPriority(speakers, category: .speaker)
            headphoneDevices = priorityManager.sortByPriority(headphones, category: .headphone)
            hiddenInputDevices = []
            hiddenSpeakerDevices = []
            hiddenHeadphoneDevices = []
            return
        }

        // Hidden lists show regular ignored devices first, then never-use ones.
        func split(_ devices: [AudioDevice], isHidden: (AudioDevice) -> Bool) -> (visible: [AudioDevice], hidden: [AudioDevice]) {
            let visible = devices.filter { !isHidden($0) && !priorityManager.isNeverUse($0) }
            let ignored = devices.filter { isHidden($0) && !priorityManager.isNeverUse($0) }
            let neverUse = devices.filter { priorityManager.isNeverUse($0) }
            return (visible, ignored + neverUse)
        }

        let inputs = split(connectedInputs) { priorityManager.isHidden($0) }
        inputDevices = priorityManager.sortByPriority(inputs.visible, type: .input)
        hiddenInputDevices = inputs.hidden

        let speakers = split(connectedOutputs.filter { priorityManager.getCategory(for: $0) == .speaker }) {
            priorityManager.isHidden($0, inCategory: .speaker)
        }
        let headphones = split(connectedOutputs.filter { priorityManager.getCategory(for: $0) == .headphone }) {
            priorityManager.isHidden($0, inCategory: .headphone)
        }
        speakerDevices = priorityManager.sortByPriority(speakers.visible, category: .speaker)
        headphoneDevices = priorityManager.sortByPriority(headphones.visible, category: .headphone)
        hiddenSpeakerDevices = speakers.hidden
        hiddenHeadphoneDevices = headphones.hidden
    }

    func setShowingAllDevices(_ showing: Bool) {
        isShowingAllDevices = showing
        rebuildLists()
    }

    func forgetDevice(_ device: AudioDevice) {
        priorityManager.forgetDevice(device)
        rebuildLists()
    }

    // MARK: - Modes

    func setMode(_ mode: OutputCategory) {
        currentMode = mode
        priorityManager.currentMode = mode
        if !isCustomMode {
            applyHighestPriorityOutput()
        }
        syncCurrentDevices(cause: .userAction)
    }

    func setCustomMode(_ enabled: Bool) {
        isCustomMode = enabled
        priorityManager.isCustomMode = enabled
        if !enabled {
            applyHighestPriorityInput()
            applyHighestPriorityOutput()
        }
        syncCurrentDevices(cause: .userAction)
    }

    /// Switches to an automatic mode in one step, so priorities are applied once.
    func setAutoMode(_ mode: OutputCategory) {
        currentMode = mode
        priorityManager.currentMode = mode
        isCustomMode = false
        priorityManager.isCustomMode = false
        applyHighestPriorityInput()
        applyHighestPriorityOutput()
        syncCurrentDevices(cause: .userAction)
    }

    // MARK: - Sections

    func devices(in section: DeviceSection) -> [AudioDevice] {
        switch section {
        case .speakers: return speakerDevices
        case .headphones: return headphoneDevices
        case .microphones: return inputDevices
        }
    }

    func currentDeviceId(for section: DeviceSection) -> AudioObjectID? {
        section == .microphones ? currentInputId : currentOutputId
    }

    /// Moves the device at `source` so it ends up at index `destination`.
    func moveDevice(in section: DeviceSection, from source: Int, to destination: Int) {
        guard source != destination else { return }
        let offset = destination > source ? destination + 1 : destination
        switch section {
        case .speakers: moveSpeakerDevice(from: IndexSet(integer: source), to: offset)
        case .headphones: moveHeadphoneDevice(from: IndexSet(integer: source), to: offset)
        case .microphones: moveInputDevice(from: IndexSet(integer: source), to: offset)
        }
    }

    /// Switches to `device` now without changing priorities.
    func useDevice(_ device: AudioDevice) {
        guard device.isConnected else { return }
        if device.type == .input {
            setInputDevice(device)
        } else {
            setOutputDevice(device)
        }
    }

    /// Clicking a row: in manual mode, use the device. In auto mode, make it the top
    /// priority, which also switches to it.
    func activate(_ device: AudioDevice, in section: DeviceSection) {
        guard device.isConnected else { return }
        guard !isCustomMode, let index = devices(in: section).firstIndex(of: device), index > 0 else {
            useDevice(device)
            return
        }
        moveDevice(in: section, from: index, to: 0)
    }

    // MARK: - Categories, ignoring, never-use

    func setCategory(_ category: OutputCategory, for device: AudioDevice) {
        priorityManager.setCategory(category, for: device)
        refreshDevices()
        reapplyAfterUserChange(type: .output)
    }

    func hideDevice(_ device: AudioDevice, category: OutputCategory? = nil) {
        if device.type == .output, let category {
            priorityManager.hideDevice(device, inCategory: category)
        } else {
            priorityManager.hideDevice(device)
        }
        refreshDevices()
        reapplyAfterUserChange(type: device.type)
    }

    func hideDeviceEntirely(_ device: AudioDevice) {
        priorityManager.hideDevice(device, inCategory: .speaker)
        priorityManager.hideDevice(device, inCategory: .headphone)
        refreshDevices()
        reapplyAfterUserChange(type: .output)
    }

    func unhideDevice(_ device: AudioDevice, category: OutputCategory? = nil) {
        if device.type == .output, let category {
            priorityManager.unhideDevice(device, fromCategory: category)
        } else {
            priorityManager.unhideDevice(device)
        }
        refreshDevices()
        reapplyAfterUserChange(type: device.type)
    }

    /// Brings back a device from the ignored list, whether it was ignored in any category
    /// or marked never-use. "Stop ignoring" used to leave never-use devices ignored.
    func restoreDevice(_ device: AudioDevice) {
        if device.type == .output {
            priorityManager.unhideDevice(device, fromCategory: .speaker)
            priorityManager.unhideDevice(device, fromCategory: .headphone)
        } else {
            priorityManager.unhideDevice(device)
        }
        priorityManager.setNeverUse(device, neverUse: false)
        refreshDevices()
        reapplyAfterUserChange(type: device.type)
    }

    func isDeviceIgnored(_ device: AudioDevice, inCategory category: OutputCategory? = nil) -> Bool {
        if device.type == .output, let category {
            return priorityManager.isHidden(device, inCategory: category)
        }
        return priorityManager.isHidden(device)
    }

    func isNeverUse(_ device: AudioDevice) -> Bool {
        priorityManager.isNeverUse(device)
    }

    func setNeverUse(_ device: AudioDevice, neverUse: Bool) {
        priorityManager.setNeverUse(device, neverUse: neverUse)
        refreshDevices()
        reapplyAfterUserChange(type: device.type)
    }

    private func reapplyAfterUserChange(type: AudioDeviceType) {
        if !isCustomMode {
            if type == .input {
                applyHighestPriorityInput()
            } else {
                applyHighestPriorityOutput()
            }
        }
        syncCurrentDevices(cause: .userAction)
    }

    // MARK: - Reordering

    func moveInputDevice(from source: IndexSet, to destination: Int) {
        inputDevices.move(fromOffsets: source, toOffset: destination)
        priorityManager.savePriorities(inputDevices, type: .input)
        if !isCustomMode {
            applyHighestPriorityInput()
        }
        syncCurrentDevices(cause: .userAction)
    }

    func moveSpeakerDevice(from source: IndexSet, to destination: Int) {
        speakerDevices.move(fromOffsets: source, toOffset: destination)
        priorityManager.savePriorities(speakerDevices, category: .speaker)
        if !isCustomMode && currentMode == .speaker {
            applyHighestPriorityOutput()
        }
        syncCurrentDevices(cause: .userAction)
    }

    func moveHeadphoneDevice(from source: IndexSet, to destination: Int) {
        headphoneDevices.move(fromOffsets: source, toOffset: destination)
        priorityManager.savePriorities(headphoneDevices, category: .headphone)
        if !isCustomMode && currentMode == .headphone {
            applyHighestPriorityOutput()
        }
        syncCurrentDevices(cause: .userAction)
    }

    // MARK: - Selecting devices

    func setInputDevice(_ device: AudioDevice) {
        applyInputDevice(device)
        syncCurrentDevices(cause: .userAction)
    }

    func setOutputDevice(_ device: AudioDevice) {
        applyOutputDevice(device)
        syncCurrentDevices(cause: .userAction)
    }

    private func applyInputDevice(_ device: AudioDevice) {
        // Skipping no-op writes avoids a listener feedback loop during the grace period.
        guard device.isConnected, deviceService?.getCurrentDefaultDevice(type: .input) != device.id else { return }
        if deviceService?.setDefaultDevice(device.id, type: .input) == true {
            log.notice("Input -> \(device.name, privacy: .public)")
            currentInputId = device.id
        } else {
            log.error("Couldn't set input to \(device.name, privacy: .public); retrying")
            scheduleRetry()
        }
    }

    private func applyOutputDevice(_ device: AudioDevice) {
        // Skipping no-op writes avoids a listener feedback loop during the grace period.
        guard device.isConnected, deviceService?.getCurrentDefaultDevice(type: .output) != device.id else { return }
        if deviceService?.setDefaultDevice(device.id, type: .output) == true {
            log.notice("Output -> \(device.name, privacy: .public)")
            currentOutputId = device.id
        } else {
            log.error("Couldn't set output to \(device.name, privacy: .public); retrying")
            scheduleRetry()
        }
    }

    /// Connected devices eligible for auto-selection, best first. Built from CoreAudio rather
    /// than the displayed lists, which include ignored devices while "All Devices" is on.
    private func autoSelectionCandidates(input: Bool, category: OutputCategory? = nil) -> [AudioDevice] {
        if input {
            let inputs = connectedDevices.filter { $0.type == .input && !priorityManager.isHidden($0) && !priorityManager.isNeverUse($0) }
            let sorted = priorityManager.sortByPriority(inputs, type: .input)
            guard keepsBluetoothHighQuality else { return sorted }
            // Stable partition: keep priority order, but Bluetooth mics only as a last resort.
            return sorted.filter { $0.transport != .bluetooth } + sorted.filter { $0.transport == .bluetooth }
        }
        let category = category ?? currentMode
        let outputs = connectedDevices.filter {
            $0.type == .output
                && priorityManager.getCategory(for: $0) == category
                && !priorityManager.isHidden($0, inCategory: category)
                && !priorityManager.isNeverUse($0)
        }
        return priorityManager.sortByPriority(outputs, category: category)
    }

    private func applyHighestPriorityInput() {
        if let first = autoSelectionCandidates(input: true).first {
            applyInputDevice(first)
        }
    }

    private func applyHighestPriorityOutput() {
        if let first = autoSelectionCandidates(input: false).first {
            applyOutputDevice(first)
        }
    }

    /// Bluetooth devices can show up in CoreAudio a moment before they accept being the
    /// default. Try the priorities once more shortly after a failed switch.
    private func scheduleRetry() {
        guard pendingRetry == nil else { return }
        pendingRetry = Task { @MainActor [weak self, retryDelay] in
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pendingRetry = nil
            guard !self.isCustomMode else { return }
            self.applyHighestPriorityInput()
            self.applyHighestPriorityOutput()
            self.syncCurrentDevices(cause: self.lastDeviceListCause)
        }
    }

    // MARK: - Change tracking

    /// Reads the real defaults from CoreAudio, refreshes dependent state, and announces a
    /// change once. Changes made from the popover aren't announced; you're looking at them.
    private func syncCurrentDevices(cause: ChangeCause) {
        guard let deviceService else { return }
        currentOutputId = deviceService.getCurrentDefaultDevice(type: .output)
        currentInputId = deviceService.getCurrentDefaultDevice(type: .input)
        refreshVolume()
        refreshMuteStatus()
        refreshCallMode()
        refreshBatteries()

        let previousOutputId = reportedOutputId
        let outputChanged = currentOutputId != reportedOutputId
        let inputChanged = currentInputId != reportedInputId
        reportedOutputId = currentOutputId
        reportedInputId = currentInputId
        if outputChanged {
            lastOutputChange = Date()
        }

        guard outputChanged || inputChanged else { return }
        if (outputChanged && currentOutputId != nil && currentOutputDevice == nil)
            || (inputChanged && currentInputId != nil && currentInputDevice == nil) {
            connectedDevices = deviceService.getDevices()
        }
        let changedOutput = outputChanged ? currentOutputDevice : nil
        let changedInput = inputChanged ? currentInputDevice : nil

        let reason: String
        switch cause {
        case .startup, .userAction:
            return
        case .external:
            reason = "Changed in macOS Sound settings"
        case .devicesChanged(let connected, let disconnected):
            let changed = [changedOutput, changedInput].compactMap { $0 }
            if let arrived = connected.first(where: { device in changed.contains { $0.uid == device.uid } }) {
                reason = "\(arrived.name) connected"
            } else if let departed = disconnected.first(where: { $0.type == .output && $0.id == previousOutputId })
                        ?? disconnected.first {
                reason = "\(departed.name) disconnected"
            } else {
                reason = "Switched to your highest-priority device"
            }
        }
        notifications?.postDeviceChange(output: changedOutput, input: changedInput, reason: reason)
    }

    private func setupListeners() {
        guard let deviceService else { return }
        deviceService.onDeviceListChanged = { [weak self] in
            Task { @MainActor in self?.scheduleDeviceListRefresh() }
        }
        deviceService.onDefaultDeviceChanged = { [weak self] in
            Task { @MainActor in self?.handleDefaultDeviceChange() }
        }
        deviceService.onDeviceStateChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshMuteStatus()
                self?.refreshVolume()
                self?.refreshCallMode()
            }
        }
        deviceService.startListening()

        batteryMonitor?.onChange = { [weak self] in
            Task { @MainActor in self?.refreshBatteries() }
        }
        batteryMonitor?.startMonitoring()
    }

    private func scheduleDeviceListRefresh() {
        lastDeviceListChange = Date()
        pendingDeviceListRefresh?.cancel()
        pendingDeviceListRefresh = Task { @MainActor [weak self, deviceListDebounce] in
            try? await Task.sleep(nanoseconds: UInt64(deviceListDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pendingDeviceListRefresh = nil
            self?.handleDeviceListChange()
        }
    }

    private func handleDeviceListChange() {
        let oldDevices = previousConnectedDevices
        refreshDevices()
        previousConnectedDevices = connectedDevices

        let oldKeys = Set(oldDevices.map(\.listID))
        let newKeys = Set(connectedDevices.map(\.listID))
        let connected = connectedDevices.filter { !oldKeys.contains($0.listID) }
        let disconnected = oldDevices.filter { !newKeys.contains($0.listID) }
        let cause = ChangeCause.devicesChanged(connected: connected, disconnected: disconnected)
        lastDeviceListChange = Date()
        lastDeviceListCause = cause
        log.notice("Devices changed. Connected: \(connected.map(\.name), privacy: .public) Disconnected: \(disconnected.map(\.name), privacy: .public)")

        if !isCustomMode {
            autoSwitchModeIfNeeded(newlyConnected: connected)
            applyHighestPriorityInput()
            applyHighestPriorityOutput()
        }
        syncCurrentDevices(cause: cause)
    }

    /// A default change that isn't ours and doesn't follow a connect/disconnect is the user
    /// picking a device in Control Center or System Settings. Respect it until the next
    /// device change instead of immediately switching back.
    private func handleDefaultDeviceChange() {
        // macOS usually switches the default while the device-list refresh is still debouncing.
        // Let that refresh apply priorities and announce the change with the right reason.
        guard pendingDeviceListRefresh == nil else { return }

        let withinGracePeriod = Date().timeIntervalSince(lastDeviceListChange) < connectionGracePeriod
        if withinGracePeriod {
            if !isCustomMode {
                applyHighestPriorityInput()
                applyHighestPriorityOutput()
            }
            syncCurrentDevices(cause: lastDeviceListCause)
            return
        }

        // Picking Bluetooth headphones as the output in Control Center also moves the mic
        // to them, which drops playback to call quality as soon as any app listens. Keep
        // the output choice but restore the preferred mic. Picking the mic on its own sticks.
        // macOS reports the output and input changes as separate events, so "together" means
        // the output changed in this event or just before it.
        if keepsBluetoothHighQuality && !isCustomMode, let deviceService,
           let newInputId = deviceService.getCurrentDefaultDevice(type: .input), newInputId != reportedInputId,
           let newOutputId = deviceService.getCurrentDefaultDevice(type: .output),
           newOutputId != reportedOutputId || Date().timeIntervalSince(lastOutputChange) < connectionGracePeriod,
           let input = connectedDevices.first(where: { $0.id == newInputId && $0.type == .input }),
           let output = connectedDevices.first(where: { $0.id == newOutputId && $0.type == .output }),
           input.transport == .bluetooth, input.name == output.name {
            log.notice("\(output.name, privacy: .public) took the mic along with the output; restoring the preferred mic")
            applyHighestPriorityInput()
        }
        log.notice("Default device changed outside the app")
        syncCurrentDevices(cause: .external)
    }

    /// Automatically switches between headphone and speaker mode based on device connections.
    /// Only triggers on:
    /// 1. A new headphone device connects → switch to headphone mode
    /// 2. All headphones disconnect → switch to speaker mode
    private func autoSwitchModeIfNeeded(newlyConnected: [AudioDevice]) {
        let connectedHeadphones = autoSelectionCandidates(input: false, category: .headphone)
        let hasConnectedSpeakers = !autoSelectionCandidates(input: false, category: .speaker).isEmpty
        let newlyConnectedUIDs = Set(newlyConnected.map(\.uid))
        let newHeadphoneConnected = connectedHeadphones.contains { newlyConnectedUIDs.contains($0.uid) }

        if newHeadphoneConnected && currentMode != .headphone {
            currentMode = .headphone
            priorityManager.currentMode = .headphone
        } else if connectedHeadphones.isEmpty && hasConnectedSpeakers && currentMode == .headphone {
            currentMode = .speaker
            priorityManager.currentMode = .speaker
        }
    }
}

#if DEBUG
extension AudioManager {
    /// Sample data for SwiftUI previews and snapshot tests. Never touches CoreAudio.
    static func preview(mode: OutputCategory = .speaker, custom: Bool = false, showingAll: Bool = false, callMode: Bool = false) -> AudioManager {
        let suite = "AudioPriorityBar.preview"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let manager = AudioManager(priorityManager: PriorityManager(defaults: defaults, legacyDefaults: nil),
                                   deviceService: nil, batteryMonitor: nil, notifications: nil)
        manager.currentMode = mode
        manager.isCustomMode = custom
        manager.isShowingAllDevices = showingAll

        let speakers = [
            AudioDevice(id: 11, uid: "studio", name: "Studio Display Speakers", type: .output, transport: .usb),
            AudioDevice(id: 12, uid: "builtin-out", name: "MacBook Pro Speakers", type: .output, transport: .builtIn),
            AudioDevice(id: 13, uid: "homepod", name: "Living Room HomePod", type: .output, transport: .airPlay),
        ]
        let headphones = [
            AudioDevice(id: 21, uid: "max:output", name: "AirPods Max", type: .output, transport: .bluetooth, modelUID: "201f 4c", isHeadphoneTerminal: true),
            AudioDevice(id: 23, uid: "pro:output", name: "Work Buds", type: .output, transport: .bluetooth, modelUID: "200e 4c", isHeadphoneTerminal: true),
            AudioDevice(id: 22, uid: "jabra", name: "Jabra Evolve2 65", type: .output, transport: .usb),
        ]
        let inputs = [
            AudioDevice(id: 31, uid: "shure", name: "Shure MV7+", type: .input, transport: .usb),
            AudioDevice(id: 24, uid: "max:input", name: "AirPods Max", type: .input, transport: .bluetooth, modelUID: "201f 4c"),
            AudioDevice(id: 32, uid: "builtin-in", name: "MacBook Pro Microphone", type: .input, transport: .builtIn),
        ]
        manager.speakerDevices = showingAll
            ? speakers + [.disconnected(uid: "old", name: "Conference Room Speaker", type: .output, transport: .usb)]
            : speakers
        manager.headphoneDevices = headphones
        manager.inputDevices = inputs
        manager.hiddenSpeakerDevices = showingAll ? [] : [AudioDevice(id: 41, uid: "zoom", name: "LG UltraFine Display", type: .output, transport: .display)]
        manager.connectedDevices = speakers + headphones + inputs
        manager.currentOutputId = mode == .headphone ? 21 : 11
        manager.currentInputId = callMode ? 24 : 31
        manager.volume = 0.62
        manager.mutedDeviceIds = [12]
        manager.callModeOutputIds = callMode ? [21] : []
        manager.batteries = [
            "output:max:output": DeviceBattery(parts: [AccessoryBattery(name: "AirPods Max", productID: 0x201F, vendorID: 0x4C, part: .single, level: 70, isCharging: false, lowWarningLevel: 20)]),
            "input:max:input": DeviceBattery(parts: [AccessoryBattery(name: "AirPods Max", productID: 0x201F, vendorID: 0x4C, part: .single, level: 70, isCharging: false, lowWarningLevel: 20)]),
            "output:pro:output": DeviceBattery(parts: [
                AccessoryBattery(name: "Work Buds", productID: 0x200E, vendorID: 0x4C, part: .left, level: 85, isCharging: false, lowWarningLevel: 20),
                AccessoryBattery(name: "Work Buds", productID: 0x200E, vendorID: 0x4C, part: .right, level: 15, isCharging: false, lowWarningLevel: 20),
                AccessoryBattery(name: "Work Buds", productID: 0x200E, vendorID: 0x4C, part: .case, level: 40, isCharging: false, lowWarningLevel: 20),
            ]),
        ]
        return manager
    }
}
#endif
