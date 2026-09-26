import SwiftUI
import CoreAudio

struct DeviceSectionsView: View {
    @EnvironmentObject var audioManager: AudioManager

    private var visibleSections: [DeviceSection] {
        var sections: [DeviceSection] = []
        if audioManager.isCustomMode || audioManager.currentMode == .speaker {
            sections.append(.speakers)
        }
        if audioManager.isCustomMode || audioManager.currentMode == .headphone {
            sections.append(.headphones)
        }
        sections.append(.microphones)
        return sections
    }

    var body: some View {
        VStack(spacing: 14) {
            if audioManager.isShowingAllDevices {
                AllDevicesBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ForEach(visibleSections, id: \.self) { section in
                DeviceSectionView(section: section)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .animation(Motion.gentle, value: visibleSections)
        .animation(Motion.gentle, value: audioManager.isShowingAllDevices)
    }
}

struct AllDevicesBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Showing disconnected and ignored devices. Drag them to set their priority for when they reconnect.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
        )
    }
}

struct DeviceSectionView: View {
    @EnvironmentObject var audioManager: AudioManager
    let section: DeviceSection

    private var devices: [AudioDevice] { audioManager.devices(in: section) }

    private var isActiveSection: Bool {
        switch section {
        case .microphones: return true
        case .speakers: return audioManager.currentOutputCategory == .speaker
        case .headphones: return audioManager.currentOutputCategory == .headphone
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: section.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isActiveSection ? Color.accentColor : Color.secondary)
                Text(section.title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 6)

            Group {
                if devices.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: section.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Text(section.emptyText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: DeviceListView.rowHeight)
                } else {
                    DeviceListView(section: section, devices: devices)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
        }
    }
}

/// A reorderable list. Rows have a fixed height so drag offsets map exactly to positions:
/// the dragged row follows the pointer and the rows it passes slide aside to make room.
struct DeviceListView: View {
    @EnvironmentObject var audioManager: AudioManager
    let section: DeviceSection
    let devices: [AudioDevice]

    static let rowHeight: CGFloat = 38
    static let rowSpacing: CGFloat = 2
    private var pitch: CGFloat { Self.rowHeight + Self.rowSpacing }

    private struct DragState: Equatable {
        let id: String
        var translation: CGFloat
    }

    @Namespace private var selectionNamespace
    /// Gesture state resets on its own when a drag ends *or* is cancelled (for example the
    /// dragged device disconnects), so a row can't get stuck looking dragged.
    @GestureState(resetTransaction: Transaction(animation: Motion.snappy))
    private var drag: DragState? = nil

    private var currentId: AudioObjectID? { audioManager.currentDeviceId(for: section) }
    private var draggingID: String? { drag?.id }
    private var dragTranslation: CGFloat { drag?.translation ?? 0 }

    private var dragSource: Int? {
        guard let draggingID else { return nil }
        return devices.firstIndex { $0.listID == draggingID }
    }

    private var dragDestination: Int? {
        guard let source = dragSource else { return nil }
        return destination(from: source, translation: dragTranslation)
    }

    private func destination(from source: Int, translation: CGFloat) -> Int {
        let rowsMoved = Int((translation / pitch).rounded())
        return max(0, min(devices.count - 1, source + rowsMoved))
    }

    /// How far a non-dragged row slides to open a gap at the drop position.
    private func shift(for index: Int) -> CGFloat {
        guard let source = dragSource, let destination = dragDestination, index != source else { return 0 }
        if source < destination, index > source, index <= destination { return -pitch }
        if destination < source, index >= destination, index < source { return pitch }
        return 0
    }

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(Array(devices.enumerated()), id: \.element.listID) { index, device in
                let isDragged = device.listID == draggingID
                DeviceRow(
                    device: device,
                    index: index,
                    count: devices.count,
                    section: section,
                    isActive: device.isConnected && device.id == currentId,
                    isDragged: isDragged,
                    selectionNamespace: selectionNamespace
                )
                .frame(height: Self.rowHeight)
                .offset(y: isDragged ? dragTranslation : shift(for: index))
                .zIndex(isDragged ? 1 : 0)
                .animation(isDragged ? nil : Motion.snappy, value: shift(for: index))
                .gesture(devices.count > 1 ? dragGesture(for: device) : nil)
            }
        }
        .animation(Motion.gentle, value: devices.map(\.listID))
        .animation(Motion.snappy, value: currentId)
    }

    private func dragGesture(for device: AudioDevice) -> some Gesture {
        // Global coordinates: the row itself moves while dragging, so local ones would drift.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($drag) { value, state, _ in
                state = DragState(id: device.listID, translation: value.translation.height)
            }
            .onEnded { value in
                guard let source = devices.firstIndex(where: { $0.listID == device.listID }) else { return }
                let target = destination(from: source, translation: value.translation.height)
                guard target != source else { return }
                withAnimation(Motion.snappy) {
                    audioManager.moveDevice(in: section, from: source, to: target)
                }
            }
    }
}

struct DeviceRow: View {
    @EnvironmentObject var audioManager: AudioManager
    let device: AudioDevice
    let index: Int
    let count: Int
    let section: DeviceSection
    let isActive: Bool
    let isDragged: Bool
    let selectionNamespace: Namespace.ID

    @State private var isHovering = false

    private var isNeverUse: Bool { audioManager.isNeverUse(device) }
    private var isIgnored: Bool { audioManager.isDeviceIgnored(device, inCategory: section.category) }
    private var isMuted: Bool { device.isConnected && audioManager.isDeviceMuted(device) }
    private var showsHandle: Bool { (isHovering || isDragged) && count > 1 }

    private var subtitle: String? {
        if !device.isConnected {
            let stored = audioManager.priorityManager.getStoredDevice(uid: device.uid, isInput: device.type == .input)
            return stored.map { "Disconnected · last seen \($0.lastSeenRelative)" } ?? "Disconnected"
        }
        if isNeverUse { return "Never selected automatically" }
        if isIgnored && audioManager.isShowingAllDevices { return "Ignored" }
        if audioManager.isInCallMode(device) { return isActive ? "Playing · call quality" : "Call quality" }
        if isActive { return device.type == .input ? "In use" : "Playing" }
        if audioManager.isSkippedForQuality(device) { return "Only if no other mic is available" }
        return nil
    }

    private var battery: DeviceBattery? { audioManager.battery(for: device) }

    private var helpText: String {
        guard device.isConnected else { return "Reconnect this device to use it" }
        if isActive { return "In use · drag to change priority" }
        return audioManager.isCustomMode ? "Click to use this device" : "Click to make this your top priority"
    }

    var body: some View {
        HStack(spacing: 9) {
            PriorityBadge(number: index + 1, isActive: isActive, showsHandle: showsHandle)

            Image(systemName: device.symbolName)
                .font(.system(size: 13))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .strikethrough(isNeverUse, color: .secondary)
                    .foregroundStyle(device.isConnected && !isNeverUse ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if subtitle != nil || battery != nil {
                    HStack(spacing: 6) {
                        if let subtitle {
                            Text(subtitle)
                                .foregroundStyle(audioManager.isInCallMode(device) ? Color.orange
                                                 : isActive ? Color.accentColor.opacity(0.9) : Color.secondary)
                        }
                        if let battery {
                            BatteryLabel(battery: battery)
                        }
                    }
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .transition(.opacity)
                }
            }

            Spacer(minLength: 4)

            if isMuted {
                Text("Muted")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.gradient))
                    .transition(.scale.combined(with: .opacity))
            }

            Menu {
                DeviceActions(device: device, index: index, count: count, section: section, isActive: isActive)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering && !isDragged ? 1 : 0)
            .allowsHitTesting(isHovering && !isDragged)
            .help("More actions")
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity)
        .background { rowBackground }
        .opacity(device.isConnected ? 1 : 0.6)
        .scaleEffect(isDragged ? 1.03 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Motion.hover) { isHovering = hovering }
        }
        .onTapGesture {
            withAnimation(Motion.snappy) {
                audioManager.activate(device, in: section)
            }
        }
        .contextMenu {
            DeviceActions(device: device, index: index, count: count, section: section, isActive: isActive)
        }
        .help(helpText)
        .animation(Motion.snappy, value: isDragged)
        .animation(Motion.hover, value: isMuted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.name), priority \(index + 1)\(isActive ? ", in use" : "")")
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if isDragged {
            shape
                .fill(.regularMaterial)
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        } else if isActive {
            // Shared geometry makes the highlight glide between rows when the device changes.
            shape
                .fill(Color.accentColor.opacity(0.14))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
                .matchedGeometryEffect(id: "active", in: selectionNamespace)
        } else if isHovering {
            shape.fill(Color.primary.opacity(0.06))
        }
    }
}

/// Battery icon and level; earbuds show left, right, and case.
struct BatteryLabel: View {
    let battery: DeviceBattery

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: battery.symbolName)
                .font(.system(size: 9))
            Text(battery.summary)
                .monospacedDigit()
        }
        .foregroundStyle(battery.isLow ? Color.red : Color.secondary)
        .help(battery.isCharging ? "Charging" : "Battery")
    }
}

/// Priority number; filled when the device is in use, a drag handle on hover.
struct PriorityBadge: View {
    let number: Int
    let isActive: Bool
    let showsHandle: Bool

    var body: some View {
        ZStack {
            if showsHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isActive ? Color.white : Color.secondary)
                    .frame(width: 18, height: 18)
                    .background {
                        if isActive {
                            Circle().fill(Color.accentColor.gradient)
                        } else {
                            Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                        }
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: 20, height: 20)
        .animation(Motion.hover, value: showsHandle)
        .animation(Motion.snappy, value: isActive)
    }
}

/// Actions shared by the row's hover menu and its right-click menu.
struct DeviceActions: View {
    @EnvironmentObject var audioManager: AudioManager
    let device: AudioDevice
    let index: Int
    let count: Int
    let section: DeviceSection
    let isActive: Bool

    private var isIgnored: Bool { audioManager.isDeviceIgnored(device, inCategory: section.category) }
    private var isNeverUse: Bool { audioManager.isNeverUse(device) }

    var body: some View {
        if device.isConnected && !isActive {
            Button("Use Now") { audioManager.useDevice(device) }
        }
        if index > 0 {
            Button("Make Top Priority") { move(to: 0) }
            Button("Move Up") { move(to: index - 1) }
        }
        if index < count - 1 {
            Button("Move Down") { move(to: index + 1) }
        }

        if let category = section.category {
            Divider()
            let other: OutputCategory = category == .speaker ? .headphone : .speaker
            Button("Move to \(other.label)") {
                withAnimation(Motion.gentle) { audioManager.setCategory(other, for: device) }
            }
        }

        Divider()
        if isIgnored || isNeverUse {
            Button("Stop Ignoring") {
                withAnimation(Motion.gentle) { audioManager.restoreDevice(device) }
            }
        } else {
            if let category = section.category {
                Button("Ignore as \(category == .headphone ? "Headphones" : "Speaker")") {
                    withAnimation(Motion.gentle) { audioManager.hideDevice(device, category: category) }
                }
                Button("Ignore Everywhere") {
                    withAnimation(Motion.gentle) { audioManager.hideDeviceEntirely(device) }
                }
            } else {
                Button("Ignore Microphone") {
                    withAnimation(Motion.gentle) { audioManager.hideDevice(device) }
                }
            }
            if device.isConnected {
                Button("Never Select Automatically") {
                    withAnimation(Motion.gentle) { audioManager.setNeverUse(device, neverUse: true) }
                }
            }
        }

        if !device.isConnected {
            Divider()
            Button("Forget Device", role: .destructive) {
                withAnimation(Motion.gentle) { audioManager.forgetDevice(device) }
            }
        }
    }

    private func move(to destination: Int) {
        withAnimation(Motion.snappy) {
            audioManager.moveDevice(in: section, from: index, to: destination)
        }
    }
}

// MARK: - Ignored devices

struct IgnoredDevicesButton: View {
    @EnvironmentObject var audioManager: AudioManager
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("\(audioManager.hiddenDeviceCount) Ignored", systemImage: "eye.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .help("Devices you've ignored or set to never be selected")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            IgnoredDevicesList()
                .environmentObject(audioManager)
        }
    }
}

struct IgnoredDevicesList: View {
    @EnvironmentObject var audioManager: AudioManager

    private var rows: [(device: AudioDevice, kind: String)] {
        audioManager.hiddenSpeakerDevices.map { ($0, "Speaker") }
            + audioManager.hiddenHeadphoneDevices.map { ($0, "Headphones") }
            + audioManager.hiddenInputDevices.map { ($0, "Microphone") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ignored Devices")
                    .font(.system(size: 13, weight: .semibold))
                Text("Hidden from the lists and never switched to automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 2) {
                ForEach(rows, id: \.device.listID) { row in
                    HStack(spacing: 9) {
                        Image(systemName: row.device.symbolName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.device.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(audioManager.isNeverUse(row.device) ? "\(row.kind) · never selected" : row.kind)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Restore") {
                            withAnimation(Motion.gentle) { audioManager.restoreDevice(row.device) }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(Motion.gentle, value: rows.map(\.device.listID))
        }
        .padding(12)
        .frame(width: 290)
    }
}
