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

extension StoredDevice {
    private enum CodingKeys: String, CodingKey {
        case uid, name, isInput, lastSeen, transport, modelUID, isHeadphoneTerminal
    }

    /// Tolerant of fields this build doesn't understand (e.g. a transport added by a newer
    /// build), so one odd record can't make the whole list unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        name = try container.decode(String.self, forKey: .name)
        isInput = try container.decode(Bool.self, forKey: .isInput)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        transport = (try? container.decodeIfPresent(String.self, forKey: .transport)).flatMap { $0.flatMap(AudioTransport.init(rawValue:)) }
        modelUID = try? container.decodeIfPresent(String.self, forKey: .modelUID)
        isHeadphoneTerminal = try? container.decodeIfPresent(Bool.self, forKey: .isHeadphoneTerminal)
    }
}

/// Decodes to nil instead of failing, so arrays can skip unreadable elements.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
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
        upgradeNeverUseEntries()
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

    /// Decoded once and kept in sync by `saveKnownDevices`; rows read it on every render.
    private var knownDevicesCache: [StoredDevice]?

    func getKnownDevices() -> [StoredDevice] {
        if let knownDevicesCache { return knownDevicesCache }
        guard let data = defaults.data(forKey: knownDevicesKey),
              let records = try? JSONDecoder().decode([Lossy<StoredDevice>].self, from: data) else {
            return []
        }
        let devices = records.compactMap(\.value)
        knownDevicesCache = devices
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

    /// Forgets one direction of a device, including its priority and ignore settings, so it
    /// comes back as new if it's ever plugged in again.
    func forgetDevice(_ device: AudioDevice) {
        let isInput = device.type == .input
        var known = getKnownDevices()
        known.removeAll { $0.uid == device.uid && $0.isInput == isInput }
        saveKnownDevices(known)

        let listKeys = isInput
            ? [inputPrioritiesKey, hiddenMicsKey]
            : [speakerPrioritiesKey, headphonePrioritiesKey, hiddenSpeakersKey, hiddenHeadphonesKey]
        for key in listKeys {
            if var list = defaults.stringArray(forKey: key), list.contains(device.uid) {
                list.removeAll { $0 == device.uid }
                defaults.set(list, forKey: key)
            }
        }
        setNeverUse(device, neverUse: false)
        if !isInput {
            var categories = defaults.dictionary(forKey: deviceCategoriesKey) as? [String: String] ?? [:]
            if categories.removeValue(forKey: device.uid) != nil {
                defaults.set(categories, forKey: deviceCategoriesKey)
            }
        }
    }

    /// Records that `devices` were present just now, e.g. at the moment they disconnect.
    func markSeen(_ devices: [AudioDevice]) {
        let keys = Set(devices.map(\.listID))
        guard !keys.isEmpty else { return }
        let now = Date()
        let known = getKnownDevices().map { stored -> StoredDevice in
            guard keys.contains("\(stored.isInput ? "input" : "output"):\(stored.uid)") else { return stored }
            var updated = stored
            updated.lastSeen = now
            return updated
        }
        saveKnownDevices(known)
    }

    func saveKnownDevices(_ devices: [StoredDevice]) {
        knownDevicesCache = devices
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

        // Collect every old-to-new claim first; only one-to-one pairs are safe to migrate.
        var newUIDsByOld: [String: Set<String>] = [:]
        var oldUIDsByNew: [String: Set<String>] = [:]
        // Bluetooth UIDs are the device's MAC address and never change.
        for device in unknownDevices where device.transport != .bluetooth {
            let isInput = device.type == .input
            // Two new devices sharing a name (e.g. identical mics) is ambiguous; leave them alone.
            let sameNameNewDevices = unknownDevices.filter { $0.name == device.name && $0.type == device.type }
            // Transport and, when both are known, model must match too, so a different generic
            // "USB Audio Device" can't inherit another one's settings. Older records lack both.
            let candidates = known.filter {
                $0.name == device.name && $0.isInput == isInput && !connectedUIDs.contains($0.uid)
                    && ($0.transport == nil || $0.transport == device.transport)
                    && ($0.modelUID == nil || device.modelUID == nil || $0.modelUID == device.modelUID)
            }
            guard sameNameNewDevices.count == 1, candidates.count == 1 else { continue }
            newUIDsByOld[candidates[0].uid, default: []].insert(device.uid)
            oldUIDsByNew[device.uid, default: []].insert(candidates[0].uid)
        }

        let migrations = newUIDsByOld.compactMap { oldUID, newUIDs -> (String, String)? in
            guard newUIDs.count == 1, let newUID = newUIDs.first, oldUIDsByNew[newUID]?.count == 1 else { return nil }
            return (oldUID, newUID)
        }.sorted { $0.0 < $1.0 }

        for (oldUID, newUID) in migrations {
            replaceUID(oldUID, with: newUID)
        }
    }

    private func replaceUID(_ oldUID: String, with newUID: String) {
        let listKeys = [
            inputPrioritiesKey, speakerPrioritiesKey, headphonePrioritiesKey,
            neverUseKey, hiddenMicsKey, hiddenSpeakersKey, hiddenHeadphonesKey,
        ]
        for key in listKeys where key != neverUseKey {
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

        if var neverUse = defaults.stringArray(forKey: neverUseKey) {
            for direction in ["input", "output"] where neverUse.contains("\(direction):\(oldUID)") {
                neverUse.removeAll { $0 == "\(direction):\(oldUID)" }
                if !neverUse.contains("\(direction):\(newUID)") {
                    neverUse.append("\(direction):\(newUID)")
                }
            }
            defaults.set(neverUse, forKey: neverUseKey)
        }

        // Rename the old records, dropping any whose direction the new UID already has.
        let existing = Set(getKnownDevices().filter { $0.uid == newUID }.map(\.isInput))
        let known = getKnownDevices().compactMap { stored -> StoredDevice? in
            guard stored.uid == oldUID else { return stored }
            guard !existing.contains(stored.isInput) else { return nil }
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

    /// Entries are per direction ("input:UID" / "output:UID"): a USB headset's mic and output
    /// share one UID, and never-using the mic mustn't hide the headphones.
    func isNeverUse(_ device: AudioDevice) -> Bool {
        let list = defaults.stringArray(forKey: neverUseKey) ?? []
        return list.contains(device.listID)
    }

    func setNeverUse(_ device: AudioDevice, neverUse: Bool) {
        var list = defaults.stringArray(forKey: neverUseKey) ?? []
        if neverUse {
            if !list.contains(device.listID) {
                list.append(device.listID)
            }
        } else {
            list.removeAll { $0 == device.listID }
        }
        defaults.set(list, forKey: neverUseKey)
    }

    /// Older builds stored bare UIDs, which meant both directions; keep that meaning.
    private func upgradeNeverUseEntries() {
        guard let list = defaults.stringArray(forKey: neverUseKey),
              list.contains(where: { !$0.hasPrefix("input:") && !$0.hasPrefix("output:") }) else { return }
        var upgraded: [String] = []
        for entry in list {
            let expanded = entry.hasPrefix("input:") || entry.hasPrefix("output:") ? [entry] : ["input:\(entry)", "output:\(entry)"]
            for value in expanded where !upgraded.contains(value) {
                upgraded.append(value)
            }
        }
        defaults.set(upgraded, forKey: neverUseKey)
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
