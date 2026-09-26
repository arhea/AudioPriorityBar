import XCTest

final class BatteryTests: XCTestCase {
    func testSingleBattery() {
        let battery = DeviceBattery(parts: [Fixture.battery("AirPods Max", .single, 70)])
        XCTAssertEqual(battery.summary, "70%")
        XCTAssertEqual(battery.listeningLevel, 70)
        XCTAssertFalse(battery.isLow)
    }

    func testEarbudsSummaryAndListeningLevel() {
        let battery = DeviceBattery(parts: [
            Fixture.battery("AirPods Pro", .case, 40),
            Fixture.battery("AirPods Pro", .right, 15),
            Fixture.battery("AirPods Pro", .left, 85),
        ])
        XCTAssertEqual(battery.summary, "L 85% · R 15% · Case 40%")
        XCTAssertEqual(battery.listeningLevel, 15, "the lower earbud is what runs out first")
        XCTAssertTrue(battery.isLow)
    }

    func testChargingIsNeverLow() {
        let battery = DeviceBattery(parts: [Fixture.battery("AirPods Pro", .left, 10, charging: true)])
        XCTAssertFalse(battery.isLow)
        XCTAssertTrue(battery.symbolName.contains("bolt"))
    }

    func testLowCaseAloneDoesNotWarn() {
        let battery = DeviceBattery(parts: [Fixture.battery("AirPods Pro", .case, 5)])
        XCTAssertNil(battery.listeningLevel)
        XCTAssertFalse(battery.isLow)
    }

    func testMatchesBatteryToDeviceByNameAndProduct() {
        let monitor = BatteryMonitor(source: { [] })
        let batteries = [
            Fixture.battery("AirPods Max", .single, 70),
            Fixture.battery("AirPods Max", .single, 30, product: 0x2014),
            Fixture.battery("Other", .single, 50),
        ]
        XCTAssertEqual(monitor.battery(for: Fixture.airPodsMax, in: batteries)?.summary, "70%")
        XCTAssertEqual(monitor.battery(for: Fixture.airPodsMaxMic, in: batteries)?.summary, "70%", "the mic half shows it too")
        XCTAssertNil(monitor.battery(for: Fixture.speakers, in: batteries), "only Bluetooth devices have batteries")
    }

    func testInjectedSourceIsUsed() {
        let monitor = BatteryMonitor(source: { [Fixture.battery("AirPods Max", .single, 42)] })
        XCTAssertEqual(monitor.accessoryBatteries().map(\.level), [42])
    }
}

final class NotificationMessageTests: XCTestCase {
    func testOutputOnly() {
        let message = NotificationManager.message(output: Fixture.airPodsMax, input: nil, reason: "AirPods Max connected")
        XCTAssertEqual(message?.title, "Sound output: AirPods Max")
        XCTAssertEqual(message?.body, "AirPods Max connected")
    }

    func testInputOnly() {
        let message = NotificationManager.message(output: nil, input: Fixture.usbMic, reason: "Shure MV7+ connected")
        XCTAssertEqual(message?.title, "Microphone: Shure MV7+")
    }

    func testSameDeviceForBoth() {
        let message = NotificationManager.message(output: Fixture.airPodsMax, input: Fixture.airPodsMaxMic, reason: "AirPods Max connected")
        XCTAssertEqual(message?.title, "Now using AirPods Max")
        XCTAssertEqual(message?.body, "Sound output and microphone · AirPods Max connected")
    }

    func testDifferentDevices() {
        let message = NotificationManager.message(output: Fixture.speakers, input: Fixture.usbMic, reason: "reason")
        XCTAssertEqual(message?.title, "Sound output: MacBook Pro Speakers")
        XCTAssertEqual(message?.body, "Microphone: Shure MV7+ · reason")
    }

    func testNothingChanged() {
        XCTAssertNil(NotificationManager.message(output: nil, input: nil, reason: "reason"))
    }
}
