import AppKit
import CoreAudio

enum AudioDeviceType: String, Codable {
    case input
    case output
}

enum OutputCategory: String, Codable, CaseIterable {
    case speaker
    case headphone

    var icon: String {
        switch self {
        case .speaker: return "speaker.wave.2.fill"
        case .headphone: return "headphones"
        }
    }

    var label: String {
        switch self {
        case .speaker: return "Speakers"
        case .headphone: return "Headphones"
        }
    }
}

/// How a device is attached, from `kAudioDevicePropertyTransportType`. Drives the row icon.
enum AudioTransport: String, Codable {
    case builtIn, usb, bluetooth, airPlay, display, thunderbolt, virtual, continuity, other

    init(coreAudioValue value: UInt32) {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .display
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate: self = .virtual
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: self = .continuity
        default: self = .other
        }
    }
}

struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let type: AudioDeviceType
    var transport: AudioTransport = .other
    var isConnected: Bool = true
    /// CoreAudio model UID. For Bluetooth devices it encodes the product and vendor ID.
    var modelUID: String? = nil
    /// The output stream declares itself as headphones (terminal type 'hdph'), which
    /// Bluetooth headphones and wired headphone jacks do regardless of the device's name.
    var isHeadphoneTerminal: Bool = false

    /// Known Apple or Beats headphones, recognized even if renamed.
    var product: AudioProduct? {
        AudioProduct.lookup(modelUID: modelUID)
    }

    /// Whether this output belongs in Headphones. Name exclusions win (speakerphones and
    /// displays), then the product ID, then the stream's terminal type, then name keywords.
    var looksLikeHeadphones: Bool {
        guard type == .output else { return false }
        if HeadphoneDetection.isSpeakerName(name) { return false }
        if product != nil || isHeadphoneTerminal { return true }
        return HeadphoneDetection.isHeadphone(deviceName: name)
    }

    var isValid: Bool {
        id != kAudioObjectUnknown
    }

    /// Stable identity for SwiftUI lists. `id` can't be used there: every disconnected
    /// device has id 0, and a USB headset's input and output halves share one AudioObjectID.
    var listID: String {
        "\(type.rawValue):\(uid)"
    }

    /// SF Symbol that best describes the physical device.
    var symbolName: String {
        if let product { return product.symbolName }
        let lower = name.lowercased()
        if lower.contains("airpods max") { return AudioProduct.catalog[0x201F]!.symbolName }
        if lower.contains("airpods pro") { return AudioProduct.catalog[0x200E]!.symbolName }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("homepod") { return "homepod.fill" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("display") { return "display" }
        if looksLikeHeadphones { return "headphones" }

        switch transport {
        case .builtIn: return "laptopcomputer"
        case .usb, .bluetooth: return type == .input ? "mic.fill" : "hifispeaker.fill"
        case .airPlay: return "airplayaudio"
        case .display, .thunderbolt: return "display"
        case .virtual: return "waveform"
        case .continuity: return "iphone"
        case .other: return type == .input ? "mic.fill" : "hifispeaker.fill"
        }
    }

    // Create a disconnected placeholder from stored device
    static func disconnected(uid: String, name: String, type: AudioDeviceType, transport: AudioTransport = .other,
                             modelUID: String? = nil, isHeadphoneTerminal: Bool = false) -> AudioDevice {
        AudioDevice(id: 0, uid: uid, name: name, type: type, transport: transport, isConnected: false,
                    modelUID: modelUID, isHeadphoneTerminal: isHeadphoneTerminal)
    }
}

/// One of the three lists in the popover.
enum DeviceSection: Hashable, CaseIterable {
    case speakers
    case headphones
    case microphones

    var category: OutputCategory? {
        switch self {
        case .speakers: return .speaker
        case .headphones: return .headphone
        case .microphones: return nil
        }
    }

    var deviceType: AudioDeviceType {
        self == .microphones ? .input : .output
    }

    var title: String {
        switch self {
        case .speakers: return "Speakers"
        case .headphones: return "Headphones"
        case .microphones: return "Microphones"
        }
    }

    var icon: String {
        switch self {
        case .speakers: return "speaker.wave.2.fill"
        case .headphones: return "headphones"
        case .microphones: return "mic.fill"
        }
    }

    var emptyText: String {
        switch self {
        case .speakers: return "No speakers connected"
        case .headphones: return "No headphones connected"
        case .microphones: return "No microphones connected"
        }
    }
}
