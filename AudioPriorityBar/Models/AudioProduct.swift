import AppKit

/// Headphones recognized by their Bluetooth vendor and product ID. CoreAudio publishes
/// these in the model UID of Bluetooth devices ("201f 4c" is product 0x201F from Apple,
/// vendor 0x004C), so recognition survives the user renaming the device.
struct AudioProduct: Equatable {
    let name: String
    /// SF Symbols to try in order; newer symbols fall back to older ones on older macOS.
    let symbols: [String]

    static let appleVendorID = 0x004C

    /// Apple and Beats headphones. Every entry is a headphone or earbud, never a speaker.
    static let catalog: [Int: AudioProduct] = [
        0x2002: AudioProduct(name: "AirPods", symbols: ["airpods"]),
        0x200F: AudioProduct(name: "AirPods (2nd generation)", symbols: ["airpods"]),
        0x2013: AudioProduct(name: "AirPods (3rd generation)", symbols: ["airpods.gen3", "airpods"]),
        0x2019: AudioProduct(name: "AirPods 4", symbols: ["airpods.gen4", "airpods.gen3", "airpods"]),
        0x201B: AudioProduct(name: "AirPods 4", symbols: ["airpods.gen4", "airpods.gen3", "airpods"]),
        0x200E: AudioProduct(name: "AirPods Pro", symbols: ["airpods.pro", "airpodspro"]),
        0x2014: AudioProduct(name: "AirPods Pro 2", symbols: ["airpods.pro", "airpodspro"]),
        0x2024: AudioProduct(name: "AirPods Pro 2", symbols: ["airpods.pro", "airpodspro"]),
        0x200A: AudioProduct(name: "AirPods Max", symbols: ["airpods.max", "airpodsmax"]),
        0x201F: AudioProduct(name: "AirPods Max", symbols: ["airpods.max", "airpodsmax"]),
        0x2003: AudioProduct(name: "Powerbeats3", symbols: ["beats.earphones", "earbuds"]),
        0x2006: AudioProduct(name: "Beats Solo3", symbols: ["beats.headphones", "headphones"]),
        0x2009: AudioProduct(name: "Beats Studio3", symbols: ["beats.headphones", "headphones"]),
        0x200B: AudioProduct(name: "Powerbeats Pro", symbols: ["beats.powerbeatspro", "beats.earphones", "earbuds"]),
        0x200C: AudioProduct(name: "Beats Solo Pro", symbols: ["beats.headphones", "headphones"]),
        0x2010: AudioProduct(name: "Beats Flex", symbols: ["beats.earphones", "earbuds"]),
        0x2011: AudioProduct(name: "Beats Studio Buds", symbols: ["beats.studiobuds", "earbuds"]),
        0x2012: AudioProduct(name: "Beats Fit Pro", symbols: ["beats.fitpro", "earbuds"]),
        0x2016: AudioProduct(name: "Beats Studio Buds+", symbols: ["beats.studiobuds", "earbuds"]),
        0x2017: AudioProduct(name: "Beats Studio Pro", symbols: ["beats.headphones", "headphones"]),
    ]

    /// Parses a CoreAudio Bluetooth model UID of the form "<product hex> <vendor hex>".
    static func ids(fromModelUID modelUID: String?) -> (product: Int, vendor: Int)? {
        guard let parts = modelUID?.split(separator: " "), parts.count == 2,
              let product = Int(parts[0], radix: 16), let vendor = Int(parts[1], radix: 16) else {
            return nil
        }
        return (product, vendor)
    }

    static func lookup(modelUID: String?) -> AudioProduct? {
        guard let ids = ids(fromModelUID: modelUID), ids.vendor == appleVendorID else { return nil }
        return catalog[ids.product]
    }

    /// First symbol this macOS version has, falling back to generic headphones.
    var symbolName: String {
        symbols.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "headphones"
    }
}
