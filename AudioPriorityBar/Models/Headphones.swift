import Foundation

/// Keywords used to detect headphone-like devices and auto-categorize them
struct HeadphoneDetection {
    /// Device name keywords that indicate headphones/earbuds.
    /// Matched at the start of a word (see `containsWord`), so "ear" matches "Nothing Ear"
    /// and "Earbuds" but not "Gear" or "Clear".
    static let keywords: [String] = [
        // Generic terms
        "headphone",
        "headset",
        "earphone",
        "earbud",
        "buds",
        "ear",

        // Apple
        "airpods",
        "earpods",
        "beats",
        "powerbeats",

        // Sony
        "wh-1000",  // WH-1000XM series
        "wf-1000",  // WF-1000XM series
        "linkbuds",
        "inzone",

        // Samsung
        "galaxy buds",

        // Bose
        "quietcomfort",
        "qc ultra",
        "qc45",
        "qc35",
        "soundsport",

        // Sennheiser
        "momentum",
        "hd 4",
        "hd 5",
        "pxc",

        // Jabra (Speak speakerphones are excluded below)
        "jabra",

        // JBL
        "jbl tune",
        "jbl live",
        "jbl tour",
        "jbl reflect",

        // Other brands
        "soundcore",
        "skullcandy",
        "oneplus buds",
        "freebuds",
        "oppo enco",
        "technics eah",
        "b&w px",
        "px7",
        "px8",
        "denon perl",
        "focal bathys",
        "hifiman",
        "shure aonic",
        "audio-technica ath",
        "ath-",
        "beyerdynamic",
        "beoplay",
        "akg",
        "plantronics",
        "voyager",
        "blackwire",
        "savi",
        "bt700",
        "encorepro",
        "marshall major",
        "marshall minor",
        "marshall mid",
        "marshall motif",
        "marshall monitor",
        "razer",
        "steelseries",
        "arctis",
        "hyperx",
        "logitech g pro",
        "astro",
        "corsair",
        "1more",
        "tozo",
        "fiio",
        "moondrop",
    ]

    /// Names that identify speakers, speakerphones, and displays. Checked first so that
    /// brands making both ("Jabra Speak", "Beats Pill", "Poly Sync") land in Speakers.
    static let speakerKeywords: [String] = [
        "speak",      // speaker, speakers, speakerphone, Jabra Speak
        "soundbar",
        "sound bar",
        "pill",       // Beats Pill
        "homepod",
        "display",
        "sync",       // Poly Sync speakerphones
        "beosound",
        "beolit",
        "hdmi",
        "tv",
        "4k",
        "soundcore motion",
        "soundcore boom",
        "soundcore flare",
        "ue boom",
        "megaboom",
        "wonderboom",
        "uboom",
        "nommo",
        "leviathan",
        "steelseries arena",
        "calisto",
        "panacast",
        "beoplay a",
        "beoplay p2",
        "beoplay p6",
        "beoplay m",
    ]

    /// Headphones whose names trip a speaker exclusion ("TV" in TV listening headsets,
    /// "monitor" style names). Checked before the exclusions.
    static let headphoneOverrides: [String] = [
        "tv ears",
        "tv clear",
        "marshall monitor",
    ]

    /// Check if a device name matches headphone patterns
    static func isHeadphone(deviceName: String) -> Bool {
        let nameLower = deviceName.lowercased()
        if headphoneOverrides.contains(where: { containsWord(nameLower, prefix: $0) }) {
            return true
        }
        if isSpeakerName(deviceName) {
            return false
        }
        return keywords.contains { containsWord(nameLower, prefix: $0) }
    }

    /// Names that identify a speaker, speakerphone, or display even if other signals say headphones.
    static func isSpeakerName(_ deviceName: String) -> Bool {
        let nameLower = deviceName.lowercased()
        if headphoneOverrides.contains(where: { containsWord(nameLower, prefix: $0) }) {
            return false
        }
        return speakerKeywords.contains { containsWord(nameLower, prefix: $0) }
    }

    /// True if `prefix` occurs in `text` starting at a word boundary. Only the start is
    /// anchored so that "buds" still matches "Buds2" and "headphone" matches "Headphones".
    static func containsWord(_ text: String, prefix: String) -> Bool {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: prefix, range: searchStart..<text.endIndex) {
            if range.lowerBound == text.startIndex {
                return true
            }
            let previous = text[text.index(before: range.lowerBound)]
            if !previous.isLetter && !previous.isNumber {
                return true
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }
}
