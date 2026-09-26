import SwiftUI

@main
struct AudioPriorityBarApp: App {
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
