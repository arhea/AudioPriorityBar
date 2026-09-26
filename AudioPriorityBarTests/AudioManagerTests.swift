import XCTest
import CoreAudio

/// Auto-switching behavior, driven through a fake CoreAudio.
@MainActor
final class AudioManagerTests: XCTestCase {
    private var service: FakeAudioDeviceService!
    private var notifier: RecordingNotifier!
    private var priorities: PriorityManager!
    private var batteries: [AccessoryBattery] = []

    override func setUp() async throws {
        notifier = RecordingNotifier()
        batteries = []
        (priorities, _) = makePriorityManager()
    }

    /// Starts the manager with short timings so tests run quickly.
    private func makeManager(
        devices: [AudioDevice],
        output: AudioDevice? = nil,
        input: AudioDevice? = nil,
        gracePeriod: TimeInterval = 0.3
    ) -> AudioManager {
        service = FakeAudioDeviceService(devices: devices, output: output?.id, input: input?.id)
        return AudioManager(
            priorityManager: priorities,
            deviceService: service,
            batteryMonitor: BatteryMonitor(source: { [unowned self] in self.batteries }),
            notifications: notifier,
            deviceListDebounce: 0.02,
            connectionGracePeriod: gracePeriod,
            retryDelay: 0.05
        )
    }

    // MARK: Startup

    func testStartupAppliesPrioritiesWithoutNotifying() async {
        priorities.savePriorities([Fixture.studioDisplay, Fixture.speakers], category: .speaker)
        priorities.savePriorities([Fixture.usbMic, Fixture.builtInMic], type: .input)

        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic, Fixture.usbMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic)

        XCTAssertEqual(service.defaultOutput, Fixture.studioDisplay.id)
        XCTAssertEqual(service.defaultInput, Fixture.usbMic.id)
        XCTAssertEqual(manager.currentOutputId, Fixture.studioDisplay.id)
        await settle()
        XCTAssertTrue(notifier.changes.isEmpty, "the switch at launch shouldn't notify")
    }

    // MARK: Connecting and disconnecting

    func testHigherPriorityDeviceConnectingTakesOverAndNotifies() async {
        priorities.savePriorities([Fixture.studioDisplay, Fixture.speakers], category: .speaker)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.builtInMic], output: Fixture.speakers, input: Fixture.builtInMic)

        service.connect(Fixture.studioDisplay)

        await waitUntil { manager.currentOutputId == Fixture.studioDisplay.id }
        await waitUntil { !self.notifier.changes.isEmpty }
        XCTAssertEqual(notifier.changes.last, .init(output: "Studio Display Speakers", input: nil,
                                                    reason: "Studio Display Speakers connected"))
    }

    func testLowerPriorityDeviceConnectingDoesNotSwitch() async {
        priorities.savePriorities([Fixture.speakers, Fixture.studioDisplay], category: .speaker)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.builtInMic], output: Fixture.speakers, input: Fixture.builtInMic)

        service.connect(Fixture.studioDisplay, macOSSwitchesTo: Fixture.studioDisplay)

        await settle()
        XCTAssertEqual(manager.currentOutputId, Fixture.speakers.id, "macOS's switch to a new device is undone")
        XCTAssertTrue(notifier.changes.isEmpty, "nothing changed in the end, so nothing to announce")
    }

    func testDisconnectFallsBackToNextPriorityAndNotifies() async {
        priorities.savePriorities([Fixture.studioDisplay, Fixture.speakers], category: .speaker)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.studioDisplay, input: Fixture.builtInMic)

        service.disconnect(uid: Fixture.studioDisplay.uid)

        await waitUntil { manager.currentOutputId == Fixture.speakers.id }
        await waitUntil { !self.notifier.changes.isEmpty }
        XCTAssertEqual(notifier.changes.last?.reason, "Studio Display Speakers disconnected")
        XCTAssertEqual(notifier.changes.count, 1, "one event, one notification")
    }

    // MARK: Modes

    func testHeadphonesConnectingSwitchesToHeadphoneModeAndBack() async {
        let manager = makeManager(devices: [Fixture.speakers, Fixture.builtInMic], output: Fixture.speakers, input: Fixture.builtInMic)
        XCTAssertEqual(manager.currentMode, .speaker)

        service.connect(Fixture.airPodsMax, Fixture.airPodsMaxMic, macOSSwitchesTo: Fixture.airPodsMax)
        await waitUntil { manager.currentMode == .headphone && manager.currentOutputId == Fixture.airPodsMax.id }

        service.disconnect(uid: Fixture.airPodsMax.uid)
        service.disconnect(uid: Fixture.airPodsMaxMic.uid)
        await waitUntil { manager.currentMode == .speaker && manager.currentOutputId == Fixture.speakers.id }
    }

    func testManualModeNeverSwitchesOnItsOwn() async {
        priorities.savePriorities([Fixture.studioDisplay, Fixture.speakers], category: .speaker)
        priorities.isCustomMode = true
        let manager = makeManager(devices: [Fixture.speakers, Fixture.builtInMic], output: Fixture.speakers, input: Fixture.builtInMic)

        service.connect(Fixture.studioDisplay)
        await settle()

        XCTAssertEqual(manager.currentOutputId, Fixture.speakers.id)
        XCTAssertTrue(service.setCalls.isEmpty)
    }

    func testSetAutoModeAppliesPrioritiesOnce() {
        let manager = makeManager(devices: [Fixture.speakers, Fixture.airPodsMax, Fixture.builtInMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic)
        manager.setAutoMode(.headphone)
        XCTAssertEqual(manager.currentOutputId, Fixture.airPodsMax.id)
        XCTAssertEqual(service.setCalls.filter { $0.type == .output }.count, 1)
    }

    // MARK: Respecting the user

    func testPickInControlCenterSticksAndIsAnnounced() async {
        priorities.savePriorities([Fixture.studioDisplay, Fixture.speakers], category: .speaker)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.studioDisplay, input: Fixture.builtInMic, gracePeriod: 0.05)
        await settle(0.1)

        service.userPicks(Fixture.speakers)

        await waitUntil { manager.currentOutputId == Fixture.speakers.id }
        await settle()
        XCTAssertEqual(service.defaultOutput, Fixture.speakers.id, "the user's pick isn't reverted")
        XCTAssertEqual(notifier.changes.last?.reason, "Changed in macOS Sound settings")
    }

    func testPopoverActionsDoNotNotify() async {
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic)
        manager.useDevice(Fixture.studioDisplay)
        await settle()
        XCTAssertEqual(manager.currentOutputId, Fixture.studioDisplay.id)
        XCTAssertTrue(notifier.changes.isEmpty)
    }

    // MARK: Ignored and never-use devices

    func testIgnoredDeviceIsNeverAutoSelectedEvenWhenShowingAllDevices() async {
        priorities.savePriorities([Fixture.studioDisplay, Fixture.speakers], category: .speaker)
        priorities.hideDevice(Fixture.studioDisplay, inCategory: .speaker)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic)
        manager.setShowingAllDevices(true)
        XCTAssertTrue(manager.speakerDevices.contains(Fixture.studioDisplay), "shown for editing")

        service.connect(Fixture.usbMic)
        await settle()

        XCTAssertEqual(manager.currentOutputId, Fixture.speakers.id)
    }

    func testNeverUseDeviceIsSkipped() {
        priorities.savePriorities([Fixture.studioDisplay, Fixture.speakers], category: .speaker)
        priorities.setNeverUse(Fixture.studioDisplay, neverUse: true)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.studioDisplay, input: Fixture.builtInMic)
        XCTAssertEqual(manager.currentOutputId, Fixture.speakers.id)
        XCTAssertTrue(manager.hiddenSpeakerDevices.contains(Fixture.studioDisplay))
    }

    func testRestoreClearsIgnoredAndNeverUse() {
        priorities.hideDevice(Fixture.studioDisplay, inCategory: .speaker)
        priorities.setNeverUse(Fixture.studioDisplay, neverUse: true)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic)
        XCTAssertEqual(manager.hiddenDeviceCount, 1)

        manager.restoreDevice(Fixture.studioDisplay)

        XCTAssertEqual(manager.hiddenDeviceCount, 0)
        XCTAssertFalse(priorities.isNeverUse(Fixture.studioDisplay))
        XCTAssertTrue(manager.speakerDevices.contains(Fixture.studioDisplay))
    }

    // MARK: Reordering and clicking

    func testClickInAutoModeMakesDeviceTopPriority() {
        priorities.savePriorities([Fixture.speakers, Fixture.studioDisplay], category: .speaker)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic)

        manager.activate(Fixture.studioDisplay, in: .speakers)

        XCTAssertEqual(manager.speakerDevices.first, Fixture.studioDisplay)
        XCTAssertEqual(manager.currentOutputId, Fixture.studioDisplay.id)
    }

    func testClickInManualModeOnlySwitches() {
        priorities.savePriorities([Fixture.speakers, Fixture.studioDisplay], category: .speaker)
        priorities.isCustomMode = true
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic)

        manager.activate(Fixture.studioDisplay, in: .speakers)

        XCTAssertEqual(manager.speakerDevices.first, Fixture.speakers, "order unchanged")
        XCTAssertEqual(manager.currentOutputId, Fixture.studioDisplay.id)
    }

    func testReorderingInManualModeDoesNotSwitch() {
        priorities.isCustomMode = true
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic)
        let first = manager.speakerDevices[0]

        manager.moveDevice(in: .speakers, from: 1, to: 0)

        XCTAssertNotEqual(manager.speakerDevices[0], first)
        XCTAssertEqual(manager.currentOutputId, Fixture.speakers.id)
    }

    func testMoveDownByOneRow() {
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic)
        let order = manager.speakerDevices

        manager.moveDevice(in: .speakers, from: 0, to: 1)

        XCTAssertEqual(manager.speakerDevices, [order[1], order[0]], "moving one row down used to be a no-op")
    }

    // MARK: Bluetooth quality

    func testBluetoothMicIsLastResortWhenKeepingHighQuality() {
        priorities.savePriorities([Fixture.airPodsMaxMic, Fixture.builtInMic], type: .input)
        let manager = makeManager(devices: [Fixture.airPodsMax, Fixture.airPodsMaxMic, Fixture.builtInMic],
                                  output: Fixture.airPodsMax, input: Fixture.airPodsMaxMic)

        XCTAssertEqual(manager.currentInputId, Fixture.builtInMic.id)
        XCTAssertTrue(manager.isSkippedForQuality(Fixture.airPodsMaxMic))
    }

    func testBluetoothMicFollowsPriorityWhenSettingIsOff() {
        priorities.savePriorities([Fixture.airPodsMaxMic, Fixture.builtInMic], type: .input)
        priorities.keepsBluetoothHighQuality = false
        let manager = makeManager(devices: [Fixture.airPodsMax, Fixture.airPodsMaxMic, Fixture.builtInMic],
                                  output: Fixture.airPodsMax, input: Fixture.builtInMic)

        XCTAssertEqual(manager.currentInputId, Fixture.airPodsMaxMic.id)
        XCTAssertFalse(manager.isSkippedForQuality(Fixture.airPodsMaxMic))
    }

    func testBluetoothMicUsedWhenItIsTheOnlyMic() {
        let manager = makeManager(devices: [Fixture.airPodsMax, Fixture.airPodsMaxMic], output: Fixture.airPodsMax, input: nil)
        XCTAssertEqual(manager.currentInputId, Fixture.airPodsMaxMic.id)
    }

    func testControlCenterPickDraggingMicAlongIsUndone() async {
        let manager = makeManager(devices: [Fixture.speakers, Fixture.airPodsMax, Fixture.airPodsMaxMic, Fixture.builtInMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic, gracePeriod: 0.05)
        manager.setCustomMode(false)
        await settle(0.1)

        // Picking AirPods as the output in Control Center moves the mic too, as two events.
        service.userPicks(Fixture.airPodsMax)
        service.userPicks(Fixture.airPodsMaxMic)

        await waitUntil { manager.currentOutputId == Fixture.airPodsMax.id && manager.currentInputId == Fixture.builtInMic.id }
        await settle()
        XCTAssertEqual(service.defaultOutput, Fixture.airPodsMax.id, "output choice kept")
        XCTAssertEqual(service.defaultInput, Fixture.builtInMic.id, "mic restored so the AirPods stay high quality")
    }

    func testPickingBluetoothMicOnItsOwnSticks() async {
        let manager = makeManager(devices: [Fixture.speakers, Fixture.airPodsMax, Fixture.airPodsMaxMic, Fixture.builtInMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic, gracePeriod: 0.05)
        await settle(0.1)

        service.userPicks(Fixture.airPodsMaxMic)

        await waitUntil { manager.currentInputId == Fixture.airPodsMaxMic.id }
        await settle()
        XCTAssertEqual(service.defaultInput, Fixture.airPodsMaxMic.id)
    }

    func testCallModeOffersNonBluetoothMic() {
        priorities.keepsBluetoothHighQuality = false
        priorities.savePriorities([Fixture.airPodsMaxMic, Fixture.builtInMic], type: .input)
        let manager = makeManager(devices: [Fixture.airPodsMax, Fixture.airPodsMaxMic, Fixture.builtInMic],
                                  output: Fixture.airPodsMax, input: Fixture.airPodsMaxMic)
        service.callModeIds = [Fixture.airPodsMax.id]
        manager.refreshCallMode()

        XCTAssertTrue(manager.isCurrentOutputInCallMode)
        XCTAssertEqual(manager.callModeFix, Fixture.builtInMic)

        manager.fixCallMode()
        XCTAssertEqual(manager.currentInputId, Fixture.builtInMic.id)
        XCTAssertNil(manager.callModeFix)
    }

    // MARK: Reliability

    func testRetriesWhenDeviceIsNotReady() async {
        priorities.savePriorities([Fixture.studioDisplay, Fixture.speakers], category: .speaker)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.builtInMic], output: Fixture.speakers, input: Fixture.builtInMic)
        service.failingSets = 1

        service.connect(Fixture.studioDisplay)

        await waitUntil { manager.currentOutputId == Fixture.studioDisplay.id }
    }

    // MARK: Review findings

    func testDeviceThatAlwaysRefusesFallsBackToNextPriorityAndStopsRetrying() async {
        priorities.savePriorities([Fixture.studioDisplay, Fixture.airPodsMax, Fixture.speakers], category: .speaker)
        priorities.setCategory(.speaker, for: Fixture.airPodsMax)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.builtInMic], output: Fixture.speakers, input: Fixture.builtInMic)
        service.refusedIds = [Fixture.studioDisplay.id]

        service.connect(Fixture.studioDisplay, Fixture.airPodsMax)

        await waitUntil { manager.currentOutputId == Fixture.airPodsMax.id }
        await settle(0.6)
        let attempts = service.failedSetCount
        await settle(0.6)
        XCTAssertEqual(service.failedSetCount, attempts, "retries must stop")
        XCTAssertLessThanOrEqual(attempts, 8)
    }

    func testRetryAfterPopoverActionDoesNotNotify() async {
        let manager = makeManager(devices: [Fixture.speakers, Fixture.builtInMic], output: Fixture.speakers, input: Fixture.builtInMic)
        service.connect(Fixture.studioDisplay)
        await settle()
        let before = notifier.changes.count
        service.failingSets = 1

        manager.moveDevice(in: .speakers, from: manager.speakerDevices.firstIndex(of: Fixture.studioDisplay)!, to: 0)

        await waitUntil { manager.currentOutputId == Fixture.studioDisplay.id }
        await settle()
        XCTAssertEqual(notifier.changes.count, before, "a retried popover action isn't announced with an old reason")
    }

    func testEventWithNoVisibleChangeKeepsUserPick() async {
        priorities.savePriorities([Fixture.studioDisplay, Fixture.speakers], category: .speaker)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.studioDisplay, input: Fixture.builtInMic, gracePeriod: 0.05)
        await settle(0.1)
        service.userPicks(Fixture.speakers)
        await waitUntil { manager.currentOutputId == Fixture.speakers.id }
        let before = notifier.changes.count

        service.publishHiddenDeviceChange()
        await settle()

        XCTAssertEqual(service.defaultOutput, Fixture.speakers.id, "a hidden aggregate appearing isn't a reason to revert")
        XCTAssertEqual(notifier.changes.count, before)
    }

    func testLaunchInHeadphoneModeWithoutHeadphonesUsesSpeakers() {
        priorities.currentMode = .headphone
        priorities.savePriorities([Fixture.speakers, Fixture.studioDisplay], category: .speaker)
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.studioDisplay, input: Fixture.builtInMic)
        XCTAssertEqual(manager.currentMode, .speaker)
        XCTAssertEqual(manager.currentOutputId, Fixture.speakers.id)
    }

    func testUseNowRightAfterConnectSticks() async {
        let manager = makeManager(devices: [Fixture.speakers, Fixture.builtInMic], output: Fixture.speakers, input: Fixture.builtInMic,
                                  gracePeriod: 0.5)
        service.connect(Fixture.airPodsMax, macOSSwitchesTo: Fixture.airPodsMax)
        await waitUntil { manager.currentOutputId == Fixture.airPodsMax.id }

        manager.useDevice(Fixture.speakers)
        await settle(0.3)

        XCTAssertEqual(service.defaultOutput, Fixture.speakers.id, "an explicit pick inside the grace window sticks")
    }

    func testClickingSkippedBluetoothMicUsesIt() {
        priorities.savePriorities([Fixture.builtInMic, Fixture.airPodsMaxMic], type: .input)
        let manager = makeManager(devices: [Fixture.airPodsMax, Fixture.airPodsMaxMic, Fixture.builtInMic],
                                  output: Fixture.airPodsMax, input: Fixture.builtInMic)

        manager.activate(Fixture.airPodsMaxMic, in: .microphones)

        XCTAssertEqual(manager.currentInputId, Fixture.airPodsMaxMic.id, "clicking a device always switches to it")
    }

    /// A row menu can outlive the list it was built from (a device disconnects while it's open).
    func testMoveWithStaleIndicesIsIgnored() {
        let manager = makeManager(devices: [Fixture.speakers, Fixture.studioDisplay, Fixture.builtInMic],
                                  output: Fixture.speakers, input: Fixture.builtInMic)
        let order = manager.speakerDevices

        manager.moveDevice(in: .speakers, from: 1, to: 2)
        manager.moveDevice(in: .speakers, from: 5, to: 0)
        manager.moveDevice(in: .speakers, from: -1, to: 0)

        XCTAssertEqual(manager.speakerDevices, order)
    }

    func testMuteButtonWorksOnDevicesWithoutAMuteControl() {
        let manager = makeManager(devices: [Fixture.speakers, Fixture.builtInMic], output: Fixture.speakers, input: Fixture.builtInMic)
        service.muteSettable = false
        manager.setVolume(0.6)
        manager.refreshVolume()

        manager.toggleOutputMute()
        XCTAssertTrue(manager.isActiveOutputMuted, "muted by zeroing the volume")

        manager.toggleOutputMute()
        XCTAssertFalse(manager.isActiveOutputMuted)
        XCTAssertEqual(manager.volume, 0.6, accuracy: 0.001, "previous volume restored")
    }

    // MARK: Volume, mute, battery

    func testUnmutingAtZeroVolumeRestoresVolume() {
        let manager = makeManager(devices: [Fixture.speakers, Fixture.builtInMic], output: Fixture.speakers, input: Fixture.builtInMic)
        manager.setVolume(0)
        manager.refreshMuteStatus()
        XCTAssertTrue(manager.isActiveOutputMuted)

        manager.toggleOutputMute()

        XCTAssertFalse(manager.isActiveOutputMuted)
        XCTAssertGreaterThan(manager.volume, 0)
    }

    func testLowBatteryNotifiesOncePerDischarge() {
        let manager = makeManager(devices: [Fixture.airPodsMax, Fixture.builtInMic], output: Fixture.airPodsMax, input: Fixture.builtInMic)

        batteries = [Fixture.battery("AirPods Max", .single, 15)]
        manager.refreshBatteries()
        manager.refreshBatteries()
        XCTAssertEqual(notifier.lowBattery, ["AirPods Max"])
        XCTAssertEqual(manager.battery(for: Fixture.airPodsMax)?.summary, "15%")

        batteries = [Fixture.battery("AirPods Max", .single, 80)]
        manager.refreshBatteries()
        batteries = [Fixture.battery("AirPods Max", .single, 10)]
        manager.refreshBatteries()
        XCTAssertEqual(notifier.lowBattery.count, 2, "warns again after recharging")
    }
}
