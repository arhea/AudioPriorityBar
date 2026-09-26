import XCTest
import CoreAudio

/// Headphone vs. speaker classification, product recognition, and device identity.
final class DeviceDetectionTests: XCTestCase {
    func testHeadphoneNames() {
        let headphones = [
            "AirPods Pro", "Alex’s AirPods Max", "External Headphones", "Jabra Evolve2 65", "Jabra Elite 8 Active",
            "Galaxy Buds2 Pro", "Pixel Buds Pro", "Nothing Ear (2)", "WH-1000XM5", "Bose QC Ultra Earbuds",
            "Poly Voyager Focus 2", "Beats Studio Pro", "SteelSeries Arctis Nova", "Sennheiser MOMENTUM 4", "USB Headset",
        ]
        for name in headphones {
            XCTAssertTrue(HeadphoneDetection.isHeadphone(deviceName: name), name)
        }
    }

    /// Substring matching used to put these in Headphones ("ear" in "Gear", "jabra" in speakerphones).
    func testSpeakerNames() {
        let speakers = [
            "MacBook Pro Speakers", "Jabra Speak2 75", "Jabra Speak 750", "Beats Pill", "Poly Sync 20",
            "Studio Display Speakers", "LG UltraFine Display", "Living Room HomePod", "Edifier R1280DB",
            "Anker PowerConf S3", "Sonos Beam", "Clear Audio USB", "Gear Box", "Samsung TV",
            "Bowers & Wilkins Zeppelin", "Elite Soundbar",
        ]
        for name in speakers {
            XCTAssertFalse(HeadphoneDetection.isHeadphone(deviceName: name), name)
        }
    }

    func testWordPrefixMatching() {
        XCTAssertTrue(HeadphoneDetection.containsWord("galaxy buds2", prefix: "buds"))
        XCTAssertTrue(HeadphoneDetection.containsWord("earbuds", prefix: "ear"))
        XCTAssertFalse(HeadphoneDetection.containsWord("gear", prefix: "ear"))
        XCTAssertFalse(HeadphoneDetection.containsWord("clear", prefix: "ear"))
    }

    // MARK: Products

    func testParsesCoreAudioBluetoothModelUID() {
        let ids = AudioProduct.ids(fromModelUID: "201f 4c")
        XCTAssertEqual(ids?.product, 0x201F)
        XCTAssertEqual(ids?.vendor, 0x4C)
        XCTAssertNil(AudioProduct.ids(fromModelUID: "Digital Mic"))
        XCTAssertNil(AudioProduct.ids(fromModelUID: nil))
    }

    func testRecognizesAppleProducts() {
        XCTAssertEqual(AudioProduct.lookup(modelUID: "201f 4c")?.name, "AirPods Max")
        XCTAssertEqual(AudioProduct.lookup(modelUID: "200e 4c")?.name, "AirPods Pro")
        XCTAssertEqual(AudioProduct.lookup(modelUID: "2012 4c")?.name, "Beats Fit Pro")
        XCTAssertNil(AudioProduct.lookup(modelUID: "201f 5d"), "same product ID from another vendor")
    }

    func testEveryCatalogEntryHasASymbol() {
        for (id, product) in AudioProduct.catalog {
            XCTAssertFalse(product.symbols.isEmpty, String(format: "0x%X", id))
            XCTAssertFalse(product.symbolName.isEmpty)
        }
    }

    func testRenamedAirPodsAreStillHeadphones() {
        let renamed = AudioDevice(id: 1, uid: "x:output", name: "Work Cans", type: .output, transport: .bluetooth, modelUID: "201f 4c")
        XCTAssertTrue(renamed.looksLikeHeadphones)
        XCTAssertTrue(renamed.symbolName.contains("airpods"), renamed.symbolName)
    }

    func testHeadphoneTerminalTypeCountsForAnyBrand() {
        let unknown = AudioDevice(id: 1, uid: "y", name: "BT-2200", type: .output, transport: .bluetooth, isHeadphoneTerminal: true)
        XCTAssertTrue(unknown.looksLikeHeadphones)
    }

    func testSpeakerNameBeatsHeadphoneSignals() {
        let speakerphone = AudioDevice(id: 1, uid: "s", name: "Jabra Speak2 75", type: .output, transport: .usb, isHeadphoneTerminal: true)
        XCTAssertFalse(speakerphone.looksLikeHeadphones)
    }

    func testBluetoothSpeakerWithoutSignalsStaysSpeaker() {
        let speaker = AudioDevice(id: 1, uid: "b", name: "Kitchen", type: .output, transport: .bluetooth)
        XCTAssertFalse(speaker.looksLikeHeadphones)
    }

    func testInputsAreNeverHeadphones() {
        XCTAssertFalse(Fixture.airPodsMaxMic.looksLikeHeadphones)
    }

    // MARK: Identity

    /// Disconnected devices all have AudioObjectID 0, and a headset's input and output halves
    /// can share one, so neither can key a SwiftUI list.
    func testListIDsAreUnique() {
        let a = AudioDevice.disconnected(uid: "a", name: "A", type: .output)
        let b = AudioDevice.disconnected(uid: "b", name: "B", type: .output)
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a.listID, b.listID)

        let headsetIn = AudioDevice(id: 5, uid: "h", name: "H", type: .input)
        let headsetOut = AudioDevice(id: 5, uid: "h", name: "H", type: .output)
        XCTAssertNotEqual(headsetIn.listID, headsetOut.listID)
    }

    func testTransportMapping() {
        XCTAssertEqual(AudioTransport(coreAudioValue: kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(AudioTransport(coreAudioValue: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(AudioTransport(coreAudioValue: kAudioDeviceTransportTypeHDMI), .display)
        XCTAssertEqual(AudioTransport(coreAudioValue: kAudioDeviceTransportTypeAggregate), .virtual)
        XCTAssertEqual(AudioTransport(coreAudioValue: 0), .other)
    }
}
