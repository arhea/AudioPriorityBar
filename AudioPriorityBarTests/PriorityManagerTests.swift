import XCTest

final class PriorityManagerTests: XCTestCase {
    private func output(_ uid: String, _ name: String, transport: AudioTransport = .usb) -> AudioDevice {
        AudioDevice(id: 1, uid: uid, name: name, type: .output, transport: transport)
    }

    private func input(_ uid: String, _ name: String, transport: AudioTransport = .usb) -> AudioDevice {
        AudioDevice(id: 2, uid: uid, name: name, type: .input, transport: transport)
    }

    // MARK: Ordering

    func testMergeOrderKeepsHiddenDevicesInTheirSlots() {
        XCTAssertEqual(PriorityManager.mergeOrder(stored: ["A", "X", "B"], visibleOrder: ["B", "A"]), ["B", "X", "A"])
        XCTAssertEqual(PriorityManager.mergeOrder(stored: ["A", "X", "B"], visibleOrder: ["N", "A", "B"]), ["N", "X", "A", "B"])
        XCTAssertEqual(PriorityManager.mergeOrder(stored: [], visibleOrder: ["A", "B"]), ["A", "B"])
        XCTAssertEqual(PriorityManager.mergeOrder(stored: ["A", "A", "B"], visibleOrder: ["B", "A"]), ["B", "A"])
    }

    /// Upstream issue #25: unplugging a dock and reordering used to wipe the dock's position.
    func testReorderWhileDisconnectedKeepsDisconnectedDevicePosition() {
        let (manager, defaults) = makePriorityManager()
        let a = output("A", "Speakers A"), dock = output("X", "Dock Speakers"), b = output("B", "Speakers B")
        manager.savePriorities([a, dock, b], category: .speaker)

        manager.savePriorities([b, a], category: .speaker)

        XCTAssertEqual(defaults.stringArray(forKey: "speakerPriorities"), ["B", "X", "A"])
        XCTAssertEqual(manager.sortByPriority([a, b, dock], category: .speaker).map(\.uid), ["B", "X", "A"])
    }

    func testSortIsStableForUnrankedDevices() {
        let (manager, _) = makePriorityManager()
        let ranked = output("B", "b")
        manager.savePriorities([ranked], category: .speaker)
        let unranked = (0..<20).map { output("u\($0)", "d\($0)") }

        let sorted = manager.sortByPriority(unranked + [ranked], category: .speaker).map(\.uid)

        XCTAssertEqual(sorted, ["B"] + unranked.map(\.uid))
    }

    // MARK: Reconnecting with a new UID

    /// Upstream PR #31: Studio Display and docks come back with a new UID after a replug.
    func testSettingsFollowDeviceThatReconnectsWithNewUID() {
        let (manager, defaults) = makePriorityManager()
        let oldOut = output("usb:1-2", "Studio Display Speakers")
        let oldIn = input("usb:1-2", "Studio Display Microphone")
        let builtIn = output("builtin", "MacBook Pro Speakers", transport: .builtIn)
        manager.rememberDevices([oldOut, oldIn, builtIn])
        manager.savePriorities([oldOut, builtIn], category: .speaker)
        manager.savePriorities([oldIn], type: .input)
        manager.setCategory(.speaker, for: oldOut)
        manager.hideDevice(oldIn)

        let newOut = output("usb:3-1", "Studio Display Speakers")
        let newIn = input("usb:3-1", "Studio Display Microphone")
        manager.migrateReconnectedDevices([newOut, newIn, builtIn])
        manager.rememberDevices([newOut, newIn, builtIn])

        XCTAssertEqual(defaults.stringArray(forKey: "speakerPriorities"), ["usb:3-1", "builtin"])
        XCTAssertEqual(defaults.stringArray(forKey: "inputPriorities"), ["usb:3-1"])
        XCTAssertTrue(manager.isHidden(newIn))
        XCTAssertEqual((defaults.dictionary(forKey: "deviceCategories") as? [String: String])?["usb:3-1"], "speaker")
        XCTAssertFalse(manager.getKnownDevices().contains { $0.uid == "usb:1-2" })
    }

    func testAmbiguousReconnectsAreNotMigrated() {
        let (manager, defaults) = makePriorityManager()
        let m1 = input("m1", "USB Mic"), m2 = input("m2", "USB Mic")
        manager.rememberDevices([m1, m2])
        manager.savePriorities([m1, m2], type: .input)

        manager.migrateReconnectedDevices([input("m3", "USB Mic")])
        manager.migrateReconnectedDevices([input("m4", "USB Mic"), input("m5", "USB Mic")])

        XCTAssertEqual(defaults.stringArray(forKey: "inputPriorities"), ["m1", "m2"])
    }

    func testReconnectWithDifferentTransportIsNotMigrated() {
        let (manager, defaults) = makePriorityManager()
        let usb = output("usbA", "USB Audio Device", transport: .usb)
        manager.rememberDevices([usb])
        manager.savePriorities([usb], category: .speaker)

        manager.migrateReconnectedDevices([output("hdmi", "USB Audio Device", transport: .display)])
        XCTAssertEqual(defaults.stringArray(forKey: "speakerPriorities"), ["usbA"])

        manager.migrateReconnectedDevices([output("usbC", "USB Audio Device", transport: .usb)])
        XCTAssertEqual(defaults.stringArray(forKey: "speakerPriorities"), ["usbC"])
    }

    func testBluetoothIsNeverMigrated() {
        let (manager, defaults) = makePriorityManager()
        let first = output("aa-bb:output", "AirPods Pro", transport: .bluetooth)
        manager.rememberDevices([first])
        manager.savePriorities([first], category: .headphone)

        manager.migrateReconnectedDevices([output("cc-dd:output", "AirPods Pro", transport: .bluetooth)])

        XCTAssertEqual(defaults.stringArray(forKey: "headphonePriorities"), ["aa-bb:output"], "a second pair is a different device")
    }

    func testStillConnectedDeviceBlocksMigration() {
        let (manager, defaults) = makePriorityManager()
        let a = output("a", "Speaker")
        manager.rememberDevices([a])
        manager.savePriorities([a], category: .speaker)

        manager.migrateReconnectedDevices([a, output("b", "Speaker")])

        XCTAssertEqual(defaults.stringArray(forKey: "speakerPriorities"), ["a"])
    }

    // MARK: Known devices

    func testKnownDevicesAreKeyedByUIDAndDirection() {
        let (manager, _) = makePriorityManager()
        manager.rememberDevices([output("h", "Jabra Evolve2 65"), input("h", "Jabra Evolve2 65")])
        XCTAssertEqual(manager.getKnownDevices().count, 2)

        manager.forgetDevice(output("h", "Jabra Evolve2 65"))

        XCTAssertEqual(manager.getKnownDevices().map(\.isInput), [true])
    }

    func testKnownDeviceRemembersModelForDisconnectedPlaceholders() {
        let (manager, _) = makePriorityManager()
        manager.rememberDevices([Fixture.airPodsMax])
        let stored = manager.getKnownDevices().first
        XCTAssertEqual(stored?.modelUID, "201f 4c")
        XCTAssertEqual(stored?.isHeadphoneTerminal, true)
    }

    func testRecordsFromOlderBuildsStillDecode() throws {
        let json = #"[{"uid":"a","name":"A","isInput":false,"lastSeen":0}]"#
        let records = try JSONDecoder().decode([StoredDevice].self, from: Data(json.utf8))
        XCTAssertEqual(records.first?.uid, "a")
        XCTAssertNil(records.first?.transport)
        XCTAssertNil(records.first?.modelUID)
    }

    // MARK: Settings

    func testLegacySettingsImportOnce() throws {
        let legacySuite = "AudioPriorityBarTests.legacy.\(UUID().uuidString)"
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
        defer { legacy.removePersistentDomain(forName: legacySuite) }
        legacy.set(["old1", "old2"], forKey: "speakerPriorities")
        legacy.set(true, forKey: "customMode")
        legacy.set(try JSONEncoder().encode([StoredDevice(uid: "old1", name: "Old", isInput: false, lastSeen: Date())]),
                   forKey: "knownDevices")

        let name = UUID().uuidString
        let (manager, defaults) = makePriorityManager(name, legacy: legacy)
        XCTAssertEqual(defaults.stringArray(forKey: "speakerPriorities"), ["old1", "old2"])
        XCTAssertTrue(manager.isCustomMode)
        XCTAssertEqual(manager.getKnownDevices().first?.uid, "old1")

        defaults.set(["changed"], forKey: "speakerPriorities")
        _ = PriorityManager(defaults: defaults, legacyDefaults: legacy)
        XCTAssertEqual(defaults.stringArray(forKey: "speakerPriorities"), ["changed"], "never imports twice")
    }

    func testKeepBluetoothHighQualityDefaultsOn() {
        let (manager, _) = makePriorityManager()
        XCTAssertTrue(manager.keepsBluetoothHighQuality)
        manager.keepsBluetoothHighQuality = false
        XCTAssertFalse(manager.keepsBluetoothHighQuality)
    }

    func testExplicitCategoryWinsOverDetection() {
        let (manager, _) = makePriorityManager()
        XCTAssertEqual(manager.getCategory(for: Fixture.airPodsMax), .headphone)
        manager.setCategory(.speaker, for: Fixture.airPodsMax)
        XCTAssertEqual(manager.getCategory(for: Fixture.airPodsMax), .speaker)
    }

    // MARK: Review findings

    /// A USB headset's mic and output share one UID; never-using the mic must not hide the output.
    func testNeverUseIsPerDirection() {
        let (manager, _) = makePriorityManager()
        let mic = input("H", "Logitech USB Headset")
        let speaker = output("H", "Logitech USB Headset")

        manager.setNeverUse(mic, neverUse: true)

        XCTAssertTrue(manager.isNeverUse(mic))
        XCTAssertFalse(manager.isNeverUse(speaker))
    }

    func testNeverUseFromOlderBuildsAppliesToBothDirections() {
        let (_, defaults) = makePriorityManager("never-legacy")
        defaults.set(["H"], forKey: "neverUseDevices")
        let manager = PriorityManager(defaults: defaults, legacyDefaults: nil)
        XCTAssertTrue(manager.isNeverUse(input("H", "Headset")))
        XCTAssertTrue(manager.isNeverUse(output("H", "Headset")))
    }

    func testOldDeviceClaimedByTwoNewDevicesIsNotMigrated() {
        let (manager, defaults) = makePriorityManager()
        let oldIn = input("A", "USB Audio"), oldOut = output("A", "USB Audio")
        manager.rememberDevices([oldIn, oldOut])
        manager.savePriorities([oldOut], category: .speaker)

        manager.migrateReconnectedDevices([input("MIC", "USB Audio"), output("DAC", "USB Audio")])

        XCTAssertEqual(defaults.stringArray(forKey: "speakerPriorities"), ["A"], "ambiguous: two different devices claim A")
    }

    func testMigrationRequiresMatchingModelWhenKnown() {
        let (manager, defaults) = makePriorityManager()
        let old = AudioDevice(id: 1, uid: "old", name: "USB PnP Sound Device", type: .output, transport: .usb, modelUID: "C-Media A")
        manager.rememberDevices([old])
        manager.savePriorities([old], category: .speaker)

        let other = AudioDevice(id: 2, uid: "new", name: "USB PnP Sound Device", type: .output, transport: .usb, modelUID: "Generic B")
        manager.migrateReconnectedDevices([other])

        XCTAssertEqual(defaults.stringArray(forKey: "speakerPriorities"), ["old"])
    }

    func testMigrationDoesNotDuplicateKnownRecords() {
        let (manager, _) = makePriorityManager()
        // X's output is already known; only X's input is new and matches A's input.
        manager.rememberDevices([input("A", "Dock Audio"), output("A", "Dock Audio"), output("X", "Dock Audio")])
        manager.migrateReconnectedDevices([input("X", "Dock Audio"), output("X", "Dock Audio")])

        let keys = manager.getKnownDevices().map { "\($0.isInput):\($0.uid)" }
        XCTAssertEqual(keys.count, Set(keys).count, "no duplicate records")
    }

    func testOneUnreadableRecordDoesNotWipeKnownDevices() {
        let (manager, defaults) = makePriorityManager()
        let json = #"[{"uid":"a","name":"A","isInput":false,"lastSeen":0,"transport":"usb"},{"uid":"b","name":"B","isInput":false,"lastSeen":0,"transport":"hologram"}]"#
        defaults.set(Data(json.utf8), forKey: "knownDevices")

        let known = manager.getKnownDevices()

        XCTAssertEqual(known.map(\.uid), ["a", "b"], "unknown transport decodes as unknown instead of dropping everything")
        XCTAssertNil(known[1].transport)
    }

    func testForgetClearsThatDirectionsSettings() {
        let (manager, defaults) = makePriorityManager()
        let old = output("old", "Old Speaker")
        manager.rememberDevices([old])
        manager.savePriorities([old], category: .speaker)
        manager.hideDevice(old, inCategory: .speaker)
        manager.setNeverUse(old, neverUse: true)

        manager.forgetDevice(old)

        XCTAssertEqual(defaults.stringArray(forKey: "speakerPriorities") ?? [], [])
        XCTAssertFalse(manager.isHidden(old, inCategory: .speaker))
        XCTAssertFalse(manager.isNeverUse(old))
    }

    func testDisconnectStampsLastSeen() {
        let (manager, _) = makePriorityManager()
        let device = output("d", "Dock")
        manager.rememberDevices([device])
        var records = manager.getKnownDevices()
        records[0].lastSeen = Date(timeIntervalSinceNow: -5 * 3600)
        manager.saveKnownDevices(records)

        manager.markSeen([device])

        XCTAssertLessThan(Date().timeIntervalSince(manager.getKnownDevices()[0].lastSeen), 5)
    }
}
