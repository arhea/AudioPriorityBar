import Foundation
import IOKit.ps

/// Battery level of a Bluetooth accessory, or one part of it (an AirPod, the case).
struct AccessoryBattery: Equatable {
    enum Part: String {
        case single = "Single"
        case left = "Left"
        case right = "Right"
        case `case` = "Case"
    }

    let name: String
    let productID: Int?
    let vendorID: Int?
    let part: Part
    let level: Int
    let isCharging: Bool
    let lowWarningLevel: Int
}

/// Battery levels for a whole device, e.g. both AirPods and the case.
struct DeviceBattery: Equatable {
    let parts: [AccessoryBattery]

    /// The level that matters for listening: the lower earbud, or the single battery.
    var listeningLevel: Int? {
        let worn = parts.filter { $0.part != .case }
        return worn.map(\.level).min()
    }

    var isCharging: Bool {
        parts.contains { $0.part != .case && $0.isCharging }
    }

    var isLow: Bool {
        guard let level = listeningLevel, !isCharging else { return false }
        let threshold = parts.first { $0.part != .case }?.lowWarningLevel ?? 20
        return level <= threshold
    }

    /// "70%", or "L 80% · R 75% · Case 50%" for earbuds.
    var summary: String {
        if parts.count == 1, let only = parts.first {
            return "\(only.level)%"
        }
        let order: [AccessoryBattery.Part] = [.left, .right, .case, .single]
        return order.compactMap { part in
            guard let battery = parts.first(where: { $0.part == part }) else { return nil }
            switch part {
            case .left: return "L \(battery.level)%"
            case .right: return "R \(battery.level)%"
            case .case: return "Case \(battery.level)%"
            case .single: return "\(battery.level)%"
            }
        }.joined(separator: " · ")
    }

    /// SF Symbol for the listening level, with a bolt while charging.
    var symbolName: String {
        if isCharging { return "battery.100percent.bolt" }
        switch listeningLevel ?? 0 {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Reads accessory batteries (AirPods, Beats, other Bluetooth headsets) from IOKit power
/// sources, the same source `pmset -g accps` uses. Accessories are only published through
/// `IOPSCopyPowerSourcesByType`, which IOKit exports but doesn't declare in a public header,
/// so it's resolved at runtime; if it's ever missing, batteries simply aren't shown.
final class BatteryMonitor {
    private typealias CopyPowerSourcesByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    /// kIOPSSourceForAccessories in IOPowerSourcesPrivate.h
    private static let accessorySourceType: Int32 = 4

    private static let copyPowerSourcesByType: CopyPowerSourcesByType? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(symbol, to: CopyPowerSourcesByType.self)
    }()

    var onChange: (() -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private let source: (() -> [AccessoryBattery])?

    /// `source` replaces the IOKit lookup, for tests.
    init(source: (() -> [AccessoryBattery])? = nil) {
        self.source = source
    }

    func accessoryBatteries() -> [AccessoryBattery] {
        if let source { return source() }
        guard let copy = Self.copyPowerSourcesByType,
              let info = copy(Self.accessorySourceType)?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return []
        }

        return list.compactMap { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let name = description[kIOPSNameKey] as? String,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  (description[kIOPSIsPresentKey] as? Bool) ?? true else {
                return nil
            }
            let max = (description[kIOPSMaxCapacityKey] as? Int) ?? 100
            let level = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            return AccessoryBattery(
                name: name,
                productID: description["Product ID"] as? Int,
                vendorID: description["Vendor ID"] as? Int,
                part: (description["Part Identifier"] as? String).flatMap(AccessoryBattery.Part.init(rawValue:)) ?? .single,
                level: level,
                isCharging: (description[kIOPSIsChargingKey] as? Bool) ?? false,
                lowWarningLevel: (description["Low Warn Level"] as? Int) ?? 20
            )
        }
    }

    /// Battery for `device`, matched by name and, when CoreAudio knows it, product and vendor ID.
    func battery(for device: AudioDevice, in batteries: [AccessoryBattery]) -> DeviceBattery? {
        guard device.isConnected, device.transport == .bluetooth else { return nil }
        let ids = AudioProduct.ids(fromModelUID: device.modelUID)
        let parts = batteries.filter { battery in
            guard battery.name == device.name else { return false }
            if let ids, let product = battery.productID, let vendor = battery.vendorID {
                return product == ids.product && vendor == ids.vendor
            }
            return true
        }
        return parts.isEmpty ? nil : DeviceBattery(parts: parts)
    }

    /// Calls `onChange` whenever any power source changes, including accessory batteries.
    func startMonitoring() {
        guard runLoopSource == nil, source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }
}
