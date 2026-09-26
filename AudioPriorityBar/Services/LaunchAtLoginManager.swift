import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled = false
    /// Registered, but the user still has to allow it in System Settings > Login Items.
    @Published private(set) var requiresApproval = false

    private init() {
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("AudioPriorityBar: failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)")
        }
        refresh()
    }

    /// Re-reads the real status; the user can change it in System Settings at any time.
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
