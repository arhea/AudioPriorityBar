import Foundation

struct StoredDevice: Codable, Equatable {
    let uid: String
    let name: String
    let isInput: Bool
    var lastSeen: Date
    /// Optional so settings written by older builds still decode.
    var transport: AudioTransport?
    var modelUID: String?
    var isHeadphoneTerminal: Bool?

    var lastSeenRelative: String {
        let now = Date()
        let interval = now.timeIntervalSince(lastSeen)

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        } else if interval < 2592000 {
            let weeks = Int(interval / 604800)
            return "\(weeks)w ago"
        } else {
            let months = Int(interval / 2592000)
            return "\(months)mo ago"
        }
    }
}

class PriorityManager {
    private let defaults: UserDefaults

    private let inputPrioritiesKey = "inputPriorities"
    private let speakerPrioritiesKey = "speakerPriorities"
    private let headphonePrioritiesKey = "headphonePriorities"
    private let deviceCategoriesKey = "deviceCategories"
    private let currentModeKey = "currentMode"
    private let customModeKey = "customMode"
    private let knownDevicesKey = "knownDevices"
    private let neverUseKey = "neverUseDevices"
    private let hiddenMicsKey = "hiddenMics"
    private let hiddenSpeakersKey = "hiddenSpeakers"
    private let hiddenHeadphonesKey = "hiddenHeadphones"
    private let legacyImportKey = "didImportLegacySettings"

    /// Bundle ID used by releases before the switch to `app.audioprioritybar`.
    static let legacyDomain = "com.example.AudioPriorityBar"

    /// Only rewrite a device's lastSeen this often, so routine refreshes don't hit disk.
    private let lastSeenResolution: TimeInterval = 60

    init(defaults: UserDefaults = .standard, legacyDefaults: UserDefaults? = UserDefaults(suiteName: PriorityManager.legacyDomain)) {
        self.defaults = defaults
        importLegacySettingsIfNeeded(from: legacyDefaults)
    }

    // MARK: - Legacy settings

    /// Releases before the bundle ID change stored everything under `com.example.AudioPriorityBar`,
    /// so upgrading silently reset every priority list. Copy those settings over once.
    private func importLegacySettingsIfNeeded(from legacy: UserDefaults?) {
        guard !defaults.bool(forKey: legacyImportKey) else { return }
        defaults.set(true, forKey: legacyImportKey)

        guard let legacy, defaults.object(forKey: knownDevicesKey) == nil else { return }
        let keys = [
            inputPrioritiesKey, speakerPrioritiesKey, headphonePrioritiesKey, deviceCategoriesKey,
            currentModeKey, customModeKey, knownDevicesKey, neverUseKey,
            hiddenMicsKey, hiddenSpeakersKey, hiddenHeadphonesKey,
        ]
        for key in keys {
            if let value = legacy.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }

    // MARK: - Known Devices (Persistent Memory)

    func getKnownDevices() -> [StoredDevice] {
        guard let data = defaults.data(forKey: knownDevicesKey),
              let devices = try? JSONDecoder().decode([StoredDevice].self, from: data) else {
            return []
        }
        return devices
    }

    /// Records every connected device in one read/write. Devices are keyed by UID *and*
    /// direction, because a USB headset publishes its input and output under one UID.
    func rememberDevices(_ devices: [AudioDevice]) {
        var known = getKnownDevices()
        let now = Date()
        var changed = false

        for device in devices {
            let isInput = device.type == .input
            let record = StoredDevice(uid: device.uid, name: device.name, isInput: isInput, lastSeen: now, transport: device.transport,
                                      modelUID: device.modelUID, isHeadphoneTerminal: device.isHeadphoneTerminal)
            if let index = known.firstIndex(where: { $0.uid == device.uid && $0.isInput == isInput }) {
                let existing = known[index]
                let isStale = now.timeIntervalSince(existing.lastSeen) > lastSeenResolution
                if isStale || existing.name != device.name || existing.transport != device.transport
                    || existing.modelUID != device.modelUID || existing.isHeadphoneTerminal != device.isHeadphoneTerminal {
                    known[index] = record
                    changed = true
                }
            } else {
                known.append(record)
                changed = true
            }
        }

        if changed {
            saveKnownDevices(known)
        }
    }

    func getStoredDevice(uid: String, isInput: Bool) -> StoredDevice? {
        getKnownDevices().first { $0.uid == uid && $0.isInput == isInput }
    }

    func forgetDevice(_ device: AudioDevice) {
        let isInput = device.type == .input
        var known = getKnownDevices()
        known.removeAll { $0.uid == device.uid && $0.isInput == isInput }
        saveKnownDevices(known)
    }

    private func saveKnownDevices(_ devices: [StoredDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: knownDevicesKey)
        }
    }

    // MARK: - Reconnects with a new UID

    /// Some devices (Studio Display, many docks) embed the USB port path in their UID, so
    /// they come back under a new UID after a replug. When a device with an unknown UID
    /// matches exactly one disconnected known device by name and direction, move that
    /// device's settings to the new UID instead of treating it as brand new.
    ///
    /// Must run before `rememberDevices`, which would otherwise make the new UID "known".
    func migrateReconnectedDevices(_ connected: [AudioDevice]) {
        let known = getKnownDevices()
        let knownKeys = Set(known.map { "\($0.isInput):\($0.uid)" })
        let connectedUIDs = Set(connected.map(\.uid))
        let unknownDevices = connected.filter { !knownKeys.contains("\($0.type == .input):\($0.uid)") }

        var migrated: [String: String] = [:]
        // Bluetooth UIDs are the device's MAC address and never change.
        for device in unknownDevices where device.transport != .bluetooth {
            let isInput = device.type == .input
            // Two new devices sharing a name (e.g. identical mics) is ambiguous; leave them alone.
            let sameNameNewDevices = unknownDevices.filter { $0.name == device.name && $0.type == device.type }
            // Transport must match too, so a different generic "USB Audio Device" plugged into a
            // dock can't inherit another one's settings. Records from older builds have no transport.
            let candidates = known.filter {
                $0.name == device.name && $0.isInput == isInput && !connectedUIDs.contains($0.uid)
                    && ($0.transport == nil || $0.transport == device.transport)
            }
            guard sameNameNewDevices.count == 1, candidates.count == 1 else { continue }

            let oldUID = candidates[0].uid
            if let existing = migrated[oldUID] {
                // The other half of the same physical device already moved; it must agree.
                if existing != device.uid { continue }
            } else {
                migrated[oldUID] = device.uid
            }
        }

        for (oldUID, newUID) in migrated {
            replaceUID(oldUID, with: newUID)
        }
    }

    private func replaceUID(_ oldUID: String, with newUID: String) {
        let listKeys = [
            inputPrioritiesKey, speakerPrioritiesKey, headphonePrioritiesKey,
            neverUseKey, hiddenMicsKey, hiddenSpeakersKey, hiddenHeadphonesKey,
        ]
        for key in listKeys {
            guard var list = defaults.stringArray(forKey: key), list.contains(oldUID) else { continue }
            if list.contains(newUID) {
                list.removeAll { $0 == oldUID }
            } else {
                list = list.map { $0 == oldUID ? newUID : $0 }
            }
            defaults.set(list, forKey: key)
        }

        var categories = defaults.dictionary(forKey: deviceCategoriesKey) as? [String: String] ?? [:]
        if let category = categories.removeValue(forKey: oldUID) {
            if categories[newUID] == nil {
                categories[newUID] = category
            }
            defaults.set(categories, forKey: deviceCategoriesKey)
        }

        var known = getKnownDevices()
        known = known.map { stored in
            guard stored.uid == oldUID else { return stored }
            return StoredDevice(uid: newUID, name: stored.name, isInput: stored.isInput, lastSeen: stored.lastSeen, transport: stored.transport,
                                modelUID: stored.modelUID, isHeadphoneTerminal: stored.isHeadphoneTerminal)
        }
        saveKnownDevices(known)
    }

    // MARK: - Mode Management

    var currentMode: OutputCategory {
        get {
            guard let raw = defaults.string(forKey: currentModeKey),
                  let mode = OutputCategory(rawValue: raw) else {
                return .speaker
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: currentModeKey)
        }
    }

    var isCustomMode: Bool {
        get { defaults.bool(forKey: customModeKey) }
        set { defaults.set(newValue, forKey: customModeKey) }
    }

    /// On unless turned off; see `AudioManager.keepsBluetoothHighQuality`.
    var keepsBluetoothHighQuality: Bool {
        get { defaults.object(forKey: "keepBluetoothHighQuality") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepBluetoothHighQuality") }
    }

    // MARK: - Device Categories

    func getCategory(for device: AudioDevice) -> OutputCategory {
        let categories = defaults.dictionary(forKey: deviceCategoriesKey) as? [String: String] ?? [:]
        if let raw = categories[device.uid], let category = OutputCategory(rawValue: raw) {
            return category
        }
        // Default headphone-like devices to headphone category
        return device.looksLikeHeadphones ? .headphone : .speaker
    }

    func setCategory(_ category: OutputCategory, for device: AudioDevice) {
        var categories = defaults.dictionary(forKey: deviceCategoriesKey) as? [String: String] ?? [:]
        categories[device.uid] = category.rawValue
        defaults.set(categories, forKey: deviceCategoriesKey)
    }

    // MARK: - Never Use Devices (never auto-selected)

    func isNeverUse(_ device: AudioDevice) -> Bool {
        let list = defaults.stringArray(forKey: neverUseKey) ?? []
        return list.contains(device.uid)
    }

    func setNeverUse(_ device: AudioDevice, neverUse: Bool) {
        var list = defaults.stringArray(forKey: neverUseKey) ?? []
        if neverUse {
            if !list.contains(device.uid) {
                list.append(device.uid)
            }
        } else {
            list.removeAll { $0 == device.uid }
        }
        defaults.set(list, forKey: neverUseKey)
    }

    // MARK: - Hidden Devices (per category)

    func isHidden(_ device: AudioDevice) -> Bool {
        let key = hiddenKey(for: device)
        let hidden = defaults.stringArray(forKey: key) ?? []
        return hidden.contains(device.uid)
    }

    func isHidden(_ device: AudioDevice, inCategory category: OutputCategory) -> Bool {
        let key = category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey
        let hidden = defaults.stringArray(forKey: key) ?? []
        return hidden.contains(device.uid)
    }

    func hideDevice(_ device: AudioDevice) {
        let key = hiddenKey(for: device)
        var hidden = defaults.stringArray(forKey: key) ?? []
        if !hidden.contains(device.uid) {
            hidden.append(device.uid)
            defaults.set(hidden, forKey: key)
        }
    }

    func hideDevice(_ device: AudioDevice, inCategory category: OutputCategory) {
        let key = category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey
        var hidden = defaults.stringArray(forKey: key) ?? []
        if !hidden.contains(device.uid) {
            hidden.append(device.uid)
            defaults.set(hidden, forKey: key)
        }
    }

    func unhideDevice(_ device: AudioDevice) {
        let key = hiddenKey(for: device)
        var hidden = defaults.stringArray(forKey: key) ?? []
        hidden.removeAll { $0 == device.uid }
        defaults.set(hidden, forKey: key)
    }

    func unhideDevice(_ device: AudioDevice, fromCategory category: OutputCategory) {
        let key = category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey
        var hidden = defaults.stringArray(forKey: key) ?? []
        hidden.removeAll { $0 == device.uid }
        defaults.set(hidden, forKey: key)
    }

    private func hiddenKey(for device: AudioDevice) -> String {
        if device.type == .input {
            return hiddenMicsKey
        } else {
            let category = getCategory(for: device)
            return category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey
        }
    }

    // MARK: - Priority Management

    func sortByPriority(_ devices: [AudioDevice], type: AudioDeviceType) -> [AudioDevice] {
        let key = priorityKey(for: type, category: nil)
        return sortDevices(devices, usingKey: key)
    }

    func sortByPriority(_ devices: [AudioDevice], category: OutputCategory) -> [AudioDevice] {
        let key = priorityKey(for: .output, category: category)
        return sortDevices(devices, usingKey: key)
    }

    func savePriorities(_ devices: [AudioDevice], type: AudioDeviceType) {
        let key = priorityKey(for: type, category: nil)
        savePriorities(devices, key: key)
    }

    func savePriorities(_ devices: [AudioDevice], category: OutputCategory) {
        let key = priorityKey(for: .output, category: category)
        savePriorities(devices, key: key)
    }

    // MARK: - Private Helpers

    private func priorityKey(for type: AudioDeviceType, category: OutputCategory?) -> String {
        switch type {
        case .input:
            return inputPrioritiesKey
        case .output:
            switch category {
            case .speaker, .none:
                return speakerPrioritiesKey
            case .headphone:
                return headphonePrioritiesKey
            }
        }
    }

    /// Ranked devices first in stored order; unranked devices after, in their original
    /// order. `sorted(by:)` isn't stable, so ties are broken by original position.
    private func sortDevices(_ devices: [AudioDevice], usingKey key: String) -> [AudioDevice] {
        let priorities = defaults.stringArray(forKey: key) ?? []
        var rank: [String: Int] = [:]
        for (index, uid) in priorities.enumerated() where rank[uid] == nil {
            rank[uid] = index
        }

        return devices.enumerated().sorted { a, b in
            let rankA = rank[a.element.uid] ?? Int.max
            let rankB = rank[b.element.uid] ?? Int.max
            if rankA != rankB { return rankA < rankB }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Merges the new order of `devices` into the stored list instead of replacing it.
    /// The list shown in the UI only has visible devices; overwriting the stored list with
    /// it used to wipe the position of every disconnected or ignored device.
    private func savePriorities(_ devices: [AudioDevice], key: String) {
        let stored = defaults.stringArray(forKey: key) ?? []
        let newOrder = devices.map(\.uid)
        defaults.set(Self.mergeOrder(stored: stored, visibleOrder: newOrder), forKey: key)
    }

    /// Slots held by visible devices in `stored` are refilled with `visibleOrder`, so hidden
    /// devices keep their position. Visible devices that weren't stored yet are appended.
    static func mergeOrder(stored: [String], visibleOrder: [String]) -> [String] {
        var seen = Set<String>()
        let stored = stored.filter { seen.insert($0).inserted }
        let visible = Set(visibleOrder)

        var remaining = visibleOrder[...]
        var merged: [String] = []
        for uid in stored {
            if visible.contains(uid) {
                if let next = remaining.popFirst() {
                    merged.append(next)
                }
            } else {
                merged.append(uid)
            }
        }
        merged.append(contentsOf: remaining)
        return merged
    }
}
