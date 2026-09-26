# Audio Priority Bar

<p align="center">
  <img src="icon.png" width="128" height="128" alt="Audio Priority Bar Icon">
</p>

A native macOS menu bar app that automatically manages audio device priorities. Set your preferred order for speakers, headphones, and microphones - the app automatically switches to the highest-priority connected device.

> This is a fork of [tobi/AudioPriorityBar](https://github.com/tobi/AudioPriorityBar) with bug fixes (including the empty popover on macOS 26), a redesigned popover, and device-change notifications.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

![Screenshot](screenshot.jpeg)

## Features

- **Priority-based auto-switching**: Devices are ranked by priority. When a higher-priority device connects, it automatically becomes active.
- **Separate speaker/headphone modes**: Output devices are categorized as either speakers or headphones, each with their own priority list. Connecting headphones switches to headphone mode; disconnecting them switches back.
- **Manual mode**: Pause auto-switching and pick devices yourself.
- **Respects your choice**: Picking a device in Control Center or System Settings sticks until the next device connects or disconnects.
- **Notifications**: Get a notification when the output or microphone changes on its own (a device connects or disconnects, or macOS switches it). Changes you make in the popover don't notify.
- **Device memory**: Remembers every device you've connected, including devices that come back with a new ID after a replug (Studio Display, docks). "All Devices" shows disconnected ones so you can set their priority ahead of time.
- **Ignore / never use**: Hide a device from one category or everywhere, or keep it listed but never switch to it automatically.
- **Drag-to-reorder**: Drag rows, click a row to make it your top priority, or use the row's menu.
- **Volume and mute**: Adjust volume with the slider or scroll wheel; click the speaker icon to mute.

## Installation

### Requirements
- macOS 13.0 (Ventura) or later

### Build from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/arhea/AudioPriorityBar.git
   cd AudioPriorityBar
   ```

2. Build using the build script:
   ```bash
   ./build.sh
   ```

3. The app will be at `dist/AudioPriorityBar.app`

Or open `AudioPriorityBar.xcodeproj` in Xcode and build with ⌘R.

### Download Release
Check the [Releases](https://github.com/arhea/AudioPriorityBar/releases) page for pre-built binaries. Each zip ships with a `.sha256` checksum.

Builds are ad-hoc signed but not notarized, so macOS will block the first launch. Verify the checksum, then right-click the app and choose **Open**, or allow it in **System Settings > Privacy & Security**.

## Usage

### Modes

| Mode | Behavior |
|------|----------|
| **Speakers** | Shows speakers and microphones; uses the highest-priority connected speaker |
| **Headphones** | Shows headphones and microphones; uses the highest-priority connected headphones |
| **Manual** | Shows everything; auto-switching is paused and clicking a device uses it |

The card at the top always shows what's playing and which microphone is in use.

### Managing Priorities

- **Click a device**: Makes it #1 and switches to it (in Manual mode, just switches to it)
- **Drag a row**: Reorder; other rows slide aside to show where it will land
- **Row menu** (hover `…` or right-click): Use Now, Make Top Priority, Move Up/Down, move between Speakers and Headphones, Ignore, Never Select Automatically, Forget Device

### All Devices

Click **All Devices** in the footer to show disconnected and ignored devices inline, with "last seen" times. Drag them to set their priority for when they reconnect, or forget ones you no longer use. Click **Done** to go back.

### Ignored Devices

The **Ignored** button in the footer lists ignored and never-use devices. **Restore** brings one back.

### Settings

The gear menu has **Notify When Device Changes**, **Launch at Login**, and **Quit**.

## How It Works

1. **Device Discovery**: Uses CoreAudio to enumerate audio devices and listen for changes. Hidden devices (private aggregates from Zoom, Teams, and recorders) and devices that can't be the system default are skipped.
2. **Priority Storage**: Device priorities are stored in UserDefaults, keyed by device UID. Reordering merges into the stored order, so disconnected devices keep their place. A device that reappears with a new UID but the same name as a single missing device inherits its settings.
3. **Auto-Switching**: When devices connect or disconnect, the app selects the highest-priority available device for the current mode. It also moves the alert-sound device along with the output when the alert device was following it.
4. **Categories**: Each output device is assigned to either "speaker" or "headphone" category, with separate priority lists. Names are matched against known headphone brands, with speakerphones and speakers (Jabra Speak, Beats Pill, Poly Sync) excluded.
5. **Settings migration**: Settings from releases that used the `com.example.AudioPriorityBar` bundle ID are imported once on first launch.

## Project Structure

```
AudioPriorityBar/
├── AudioPriorityBarApp.swift       # App entry and MenuBarExtra
├── Models/
│   ├── AudioDevice.swift           # Device model, categories, sections
│   └── Headphones.swift            # Headphone name detection
├── Services/
│   ├── AudioManager.swift          # App state, auto-switching, change tracking
│   ├── AudioDeviceService.swift    # CoreAudio wrapper
│   ├── PriorityManager.swift       # Priority persistence and UID migration
│   ├── NotificationManager.swift   # Device-change notifications
│   └── LaunchAtLoginManager.swift  # Login item
└── Views/
    ├── MenuBarView.swift           # Popover shell, mode picker, now playing, footer
    └── DeviceListView.swift        # Sections, reorderable rows, ignored devices
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

Built with SwiftUI and CoreAudio for macOS.
