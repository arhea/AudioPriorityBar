import SwiftUI
import CoreAudio
import AppKit

enum Motion {
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let gentle = Animation.spring(response: 0.4, dampingFraction: 0.86)
    static let hover = Animation.easeOut(duration: 0.12)
}

struct MenuBarView: View {
    @EnvironmentObject var audioManager: AudioManager
    @State private var listContentHeight: CGFloat = 0

    /// Tall enough for most setups, short enough to stay on screen; longer lists scroll.
    private var maxListHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(220, min(520, screenHeight - 320))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ModePickerView()
                ModeHintView()
                NowPlayingCard()
            }
            .padding(12)

            Divider()
                .padding(.horizontal, 12)

            ScrollView(.vertical) {
                DeviceSectionsView()
                    .padding(12)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ListContentHeightKey.self, value: proxy.size.height)
                        }
                    )
            }
            // MenuBarExtra sizes its window to the content's ideal height, and a ScrollView
            // has none; on macOS 26 that collapses the device list to zero. Size the scroll
            // view to its measured content instead, capped so long lists scroll.
            .frame(height: min(max(listContentHeight, 1), maxListHeight))
            .onPreferenceChange(ListContentHeightKey.self) { height in
                listContentHeight = height
            }

            Divider()
                .padding(.horizontal, 12)

            FooterView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onAppear {
            LaunchAtLoginManager.shared.refresh()
            NotificationManager.shared.refreshAuthorizationStatus()
        }
        .onDisappear {
            if audioManager.isShowingAllDevices {
                audioManager.setShowingAllDevices(false)
            }
        }
    }
}

private struct ListContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Mode picker

struct ModePickerView: View {
    @EnvironmentObject var audioManager: AudioManager
    @Namespace private var namespace

    enum Option: CaseIterable {
        case speaker, headphone, manual

        var title: String {
            switch self {
            case .speaker: return "Speakers"
            case .headphone: return "Headphones"
            case .manual: return "Manual"
            }
        }

        var icon: String {
            switch self {
            case .speaker: return "speaker.wave.2.fill"
            case .headphone: return "headphones"
            case .manual: return "hand.point.up.left.fill"
            }
        }

        var tint: Color {
            self == .manual ? .orange : .accentColor
        }

        var help: String {
            switch self {
            case .speaker: return "Automatically use your highest-priority speaker"
            case .headphone: return "Automatically use your highest-priority headphones"
            case .manual: return "Pause auto-switching and pick devices yourself"
            }
        }
    }

    private var selection: Option {
        if audioManager.isCustomMode { return .manual }
        return audioManager.currentMode == .speaker ? .speaker : .headphone
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Option.allCases, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    select(option)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: option.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(option.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(option.tint.gradient)
                                .shadow(color: option.tint.opacity(0.35), radius: 4, y: 1)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .help(option.help)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func select(_ option: Option) {
        guard option != selection else { return }
        withAnimation(Motion.snappy) {
            switch option {
            case .speaker: audioManager.setAutoMode(.speaker)
            case .headphone: audioManager.setAutoMode(.headphone)
            case .manual: audioManager.setCustomMode(true)
            }
        }
    }
}

struct ModeHintView: View {
    @EnvironmentObject var audioManager: AudioManager

    private var hint: String {
        if audioManager.isCustomMode {
            return "Auto-switching is paused. Click any device to use it."
        }
        switch audioManager.currentMode {
        case .speaker:
            return "Uses your top connected speaker. Click or drag to set priority."
        case .headphone:
            return "Uses your top connected headphones. Speakers return when they disconnect."
        }
    }

    var body: some View {
        Text(hint)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .id(hint)
            .transition(.opacity)
            .animation(Motion.gentle, value: hint)
    }
}

// MARK: - Now playing

struct NowPlayingCard: View {
    @EnvironmentObject var audioManager: AudioManager

    private var output: AudioDevice? { audioManager.currentOutputDevice }
    private var input: AudioDevice? { audioManager.currentInputDevice }
    private let tint = Color.accentColor

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint.gradient)
                    Image(systemName: output?.symbolName ?? "speaker.slash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .id(output?.symbolName)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                .frame(width: 32, height: 32)
                .shadow(color: tint.opacity(0.3), radius: 4, y: 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(output?.name ?? "No output device")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .id(output?.listID)
                        .transition(.slideUp)

                    HStack(spacing: 4) {
                        Image(systemName: audioManager.isActiveInputMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(audioManager.isActiveInputMuted ? Color.red : Color.secondary)
                        Text(input?.name ?? "No microphone")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .id(input?.listID)
                            .transition(.slideUp)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .clipped()

                Spacer(minLength: 0)
            }

            VolumeSliderView()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .animation(Motion.gentle, value: output?.listID)
        .animation(Motion.gentle, value: input?.listID)
    }
}

private extension AnyTransition {
    /// New text slides up into place while the old text slides out the top.
    static var slideUp: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }
}

struct VolumeSliderView: View {
    @EnvironmentObject var audioManager: AudioManager

    private var isMuted: Bool { audioManager.isActiveOutputMuted }

    private var volumeIcon: String {
        if isMuted { return "speaker.slash.fill" }
        return audioManager.currentOutputCategory == .headphone ? "headphones" : "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(Motion.snappy) {
                    audioManager.toggleOutputMute()
                }
            } label: {
                Image(systemName: volumeIcon, variableValue: volumeIcon == "speaker.wave.3.fill" ? Double(audioManager.volume) : nil)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isMuted ? Color.red : Color.accentColor)
                    .frame(width: 22, height: 22)
                    .bounceOnChange(of: isMuted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!audioManager.isMuteSettable && !audioManager.isVolumeSettable)
            .help(isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { Double(audioManager.volume) },
                    set: { audioManager.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .disabled(!audioManager.isVolumeSettable)
            .opacity(isMuted ? 0.5 : 1)

            Text(audioManager.isVolumeSettable ? "\(Int((audioManager.volume * 100).rounded()))%" : "Fixed")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                .help(audioManager.isVolumeSettable ? "" : "This device controls its own volume")
        }
        .onScrollWheel { delta in
            guard audioManager.isVolumeSettable else { return }
            audioManager.setVolume(audioManager.volume + Float(delta))
        }
    }
}

// MARK: - Footer

struct FooterView: View {
    @EnvironmentObject var audioManager: AudioManager

    var body: some View {
        HStack(spacing: 8) {
            if audioManager.hiddenDeviceCount > 0 && !audioManager.isShowingAllDevices {
                IgnoredDevicesButton()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Spacer()

            Button {
                withAnimation(Motion.gentle) {
                    audioManager.setShowingAllDevices(!audioManager.isShowingAllDevices)
                }
            } label: {
                Label(
                    audioManager.isShowingAllDevices ? "Done" : "All Devices",
                    systemImage: audioManager.isShowingAllDevices ? "checkmark" : "clock.arrow.circlepath"
                )
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(audioManager.isShowingAllDevices ? Color.white : Color.secondary)
                .background(
                    Capsule()
                        .fill(audioManager.isShowingAllDevices ? Color.accentColor : Color.primary.opacity(0.07))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .help(audioManager.isShowingAllDevices
                  ? "Hide disconnected devices"
                  : "Show disconnected and ignored devices to edit their priority")

            SettingsMenu()
        }
        .animation(Motion.gentle, value: audioManager.isShowingAllDevices)
        .animation(Motion.gentle, value: audioManager.hiddenDeviceCount)
    }
}

struct SettingsMenu: View {
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var notifications = NotificationManager.shared

    var body: some View {
        Menu {
            Toggle("Notify When Device Changes", isOn: Binding(
                get: { notifications.isEnabled },
                set: { notifications.setEnabled($0) }
            ))
            if notifications.isEnabled && notifications.isBlockedBySystem {
                Button("Allow Notifications in System Settings…") {
                    notifications.openSystemSettings()
                }
            }

            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled || launchAtLogin.requiresApproval },
                set: { launchAtLogin.setEnabled($0) }
            ))
            if launchAtLogin.requiresApproval {
                Button("Allow in Login Items…") {
                    launchAtLogin.openLoginItemsSettings()
                }
            }

            Divider()

            Button("Quit Audio Priority Bar") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }
}

// MARK: - Shared styles

/// Plain button that dips slightly while pressed.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension View {
    /// Bounces an SF Symbol when `value` changes, on macOS 14 and later.
    @ViewBuilder
    func bounceOnChange<V: Equatable>(of value: V) -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }
}

// MARK: - Scroll wheel

struct ScrollWheelModifier: ViewModifier {
    let onScroll: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(
            ScrollWheelReceiver(onScroll: onScroll)
        )
    }
}

struct ScrollWheelReceiver: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        // Trackpads report per-pixel deltas, mice report whole lines; scale to similar speeds.
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.004 : 0.02
        onScroll?(event.scrollingDeltaY * step)
    }
}

extension View {
    /// Calls `action` with a volume delta for scroll-wheel events over this view.
    func onScrollWheel(_ action: @escaping (CGFloat) -> Void) -> some View {
        modifier(ScrollWheelModifier(onScroll: action))
    }
}
