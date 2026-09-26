import SwiftUI

@main
struct AudioPriorityBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var audioManager = AudioManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(audioManager)
        } label: {
            Image(systemName: audioManager.menuBarSymbol, variableValue: audioManager.menuBarVariableValue)
                .accessibilityLabel("Audio Priority Bar")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            NotificationManager.shared.activate()
        }
    }
}
