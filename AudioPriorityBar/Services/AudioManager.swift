import SwiftUI
import CoreAudio

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

    let priorityManager: PriorityManager
    private let deviceService: AudioDeviceService?

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
    private let deviceListDebounce: UInt64 = 250_000_000
    /// macOS often switches to a newly connected device a beat after publishing it. A default
    /// change inside this window is macOS, not the user, so priorities still apply.
    private let connectionGracePeriod: TimeInterval = 2

    enum ChangeCause {
        case startup
        case userAction
        case devicesChanged(connected: [AudioDevice], disconnected: [AudioDevice])
        case external
    }

    init(priorityManager: PriorityManager = PriorityManager(), live: Bool = true) {
        self.priorityManager = priorityManager
        self.deviceService = live ? AudioDeviceService() : nil
        currentMode = priorityManager.currentMode
        isCustomMode = priorityManager.isCustomMode

        guard live else { return }
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
                let device = AudioDevice.disconnected(uid: stored.uid, name: stored.name, type: type, transport: stored.transport ?? .other)
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
            currentInputId = device.id
        }
    }

    private func applyOutputDevice(_ device: AudioDevice) {
        // Skipping no-op writes avoids a listener feedback loop during the grace period.
        guard device.isConnected, deviceService?.getCurrentDefaultDevice(type: .output) != device.id else { return }
        if deviceService?.setDefaultDevice(device.id, type: .output) == true {
            currentOutputId = device.id
        }
    }

    /// Connected devices eligible for auto-selection, best first. Built from CoreAudio rather
    /// than the displayed lists, which include ignored devices while "All Devices" is on.
    private func autoSelectionCandidates(input: Bool, category: OutputCategory? = nil) -> [AudioDevice] {
        if input {
            let inputs = connectedDevices.filter { $0.type == .input && !priorityManager.isHidden($0) && !priorityManager.isNeverUse($0) }
            return priorityManager.sortByPriority(inputs, type: .input)
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

    // MARK: - Change tracking

    /// Reads the real defaults from CoreAudio, refreshes dependent state, and announces a
    /// change once. Changes made from the popover aren't announced; you're looking at them.
    private func syncCurrentDevices(cause: ChangeCause) {
        guard let deviceService else { return }
        currentOutputId = deviceService.getCurrentDefaultDevice(type: .output)
        currentInputId = deviceService.getCurrentDefaultDevice(type: .input)
        refreshVolume()
        refreshMuteStatus()

        let previousOutputId = reportedOutputId
        let outputChanged = currentOutputId != reportedOutputId
        let inputChanged = currentInputId != reportedInputId
        reportedOutputId = currentOutputId
        reportedInputId = currentInputId

        // Change announcements hook in here; `cause` says why the defaults moved.
        _ = (cause, previousOutputId, outputChanged, inputChanged)
    }

    private func setupListeners() {
        guard let deviceService else { return }
        deviceService.onDeviceListChanged = { [weak self] in
            Task { @MainActor in self?.scheduleDeviceListRefresh() }
        }
        deviceService.onDefaultDeviceChanged = { [weak self] in
            Task { @MainActor in self?.handleDefaultDeviceChange() }
        }
        deviceService.onMuteOrVolumeChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshMuteStatus()
                self?.refreshVolume()
            }
        }
        deviceService.startListening()
    }

    private func scheduleDeviceListRefresh() {
        lastDeviceListChange = Date()
        pendingDeviceListRefresh?.cancel()
        pendingDeviceListRefresh = Task { @MainActor [weak self, deviceListDebounce] in
            try? await Task.sleep(nanoseconds: deviceListDebounce)
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
        } else {
            syncCurrentDevices(cause: .external)
        }
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
    static func preview(mode: OutputCategory = .speaker, custom: Bool = false, showingAll: Bool = false) -> AudioManager {
        let suite = "AudioPriorityBar.preview"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let manager = AudioManager(priorityManager: PriorityManager(defaults: defaults, legacyDefaults: nil), live: false)
        manager.currentMode = mode
        manager.isCustomMode = custom
        manager.isShowingAllDevices = showingAll

        let speakers = [
            AudioDevice(id: 11, uid: "studio", name: "Studio Display Speakers", type: .output, transport: .usb),
            AudioDevice(id: 12, uid: "builtin-out", name: "MacBook Pro Speakers", type: .output, transport: .builtIn),
            AudioDevice(id: 13, uid: "homepod", name: "Living Room HomePod", type: .output, transport: .airPlay),
        ]
        let headphones = [
            AudioDevice(id: 21, uid: "airpods", name: "AirPods Pro", type: .output, transport: .bluetooth),
            AudioDevice(id: 22, uid: "jabra", name: "Jabra Evolve2 65", type: .output, transport: .usb),
        ]
        let inputs = [
            AudioDevice(id: 31, uid: "shure", name: "Shure MV7+", type: .input, transport: .usb),
            AudioDevice(id: 21, uid: "airpods", name: "AirPods Pro", type: .input, transport: .bluetooth),
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
        manager.currentInputId = 31
        manager.volume = 0.62
        manager.mutedDeviceIds = [12]
        return manager
    }
}
#endif
