import AppKit
import UserNotifications

/// Where `AudioManager` sends announcements; tests record them instead.
@MainActor
protocol DeviceChangeNotifying: AnyObject {
    func postDeviceChange(output: AudioDevice?, input: AudioDevice?, reason: String)
    func postLowBattery(device: AudioDevice, battery: DeviceBattery)
}

/// Posts a notification when the default output or microphone changes on its own:
/// a device connects or disconnects, or another app or macOS switches it.
@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate, DeviceChangeNotifying {
    static let shared = NotificationManager()

    @Published private(set) var isEnabled: Bool
    /// The user turned notifications off for the app in System Settings.
    @Published private(set) var isBlockedBySystem = false

    private let enabledKey = "notifyOnDeviceChange"
    /// Reusing one identifier replaces the previous banner, so Notification Center keeps
    /// only the latest switch instead of a stack of them.
    private let requestIdentifier = "device-change"

    private override init() {
        isEnabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        super.init()
    }

    /// UNUserNotificationCenter throws outside an app bundle (SwiftUI previews, test harnesses).
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Call once at launch.
    func activate() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        if isEnabled {
            requestAuthorization()
        } else {
            refreshAuthorizationStatus()
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        guard isAvailable else { return }
        if enabled {
            requestAuthorization()
        } else {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
        }
    }

    func refreshAuthorizationStatus() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let blocked = settings.authorizationStatus == .denied
            Task { @MainActor in self.isBlockedBySystem = blocked }
        }
    }

    func openSystemSettings() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)") {
            NSWorkspace.shared.open(url)
        }
    }

    func postDeviceChange(output: AudioDevice?, input: AudioDevice?, reason: String) {
        guard isEnabled, isAvailable, let message = Self.message(output: output, input: input, reason: reason) else { return }

        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.threadIdentifier = requestIdentifier
        // No sound: it would play through the device that was just switched to.

        let request = UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("AudioPriorityBar: failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    func postLowBattery(device: AudioDevice, battery: DeviceBattery) {
        guard isEnabled, isAvailable, let level = battery.listeningLevel else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(device.name) battery low"
        content.body = "\(level)% remaining"
        content.threadIdentifier = "battery"
        let request = UNNotificationRequest(identifier: "battery-\(device.uid)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("AudioPriorityBar: failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func message(output: AudioDevice?, input: AudioDevice?, reason: String) -> (title: String, body: String)? {
        switch (output, input) {
        case let (output?, input?) where output.name == input.name:
            return ("Now using \(output.name)", "Sound output and microphone · \(reason)")
        case let (output?, input?):
            return ("Sound output: \(output.name)", "Microphone: \(input.name) · \(reason)")
        case let (output?, nil):
            return ("Sound output: \(output.name)", reason)
        case let (nil, input?):
            return ("Microphone: \(input.name)", reason)
        case (nil, nil):
            return nil
        }
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, error in
            if let error {
                NSLog("AudioPriorityBar: notification authorization failed: \(error.localizedDescription)")
            }
            Task { @MainActor in self.refreshAuthorizationStatus() }
        }
    }

    // A menu bar app counts as frontmost while its popover is open; show banners anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
