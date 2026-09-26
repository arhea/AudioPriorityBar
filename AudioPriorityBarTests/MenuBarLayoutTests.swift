import XCTest
import SwiftUI
import AppKit

/// Renders the real popover offscreen. Guards against the macOS 26 regression where the
/// device list collapsed to zero height and the popover showed only the header and footer.
@MainActor
final class MenuBarLayoutTests: XCTestCase {
    /// The popover's size when asked for its smallest size, which is how the menu bar window
    /// ends up sized on macOS 26. A ScrollView with only a max height gives up all its space
    /// under that proposal, which is exactly how the device list disappeared.
    private func renderedSize(_ manager: AudioManager) -> CGSize {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: MenuBarView().environmentObject(manager))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        // The list height is measured and fed back through a preference, so lay out a few times.
        for _ in 0..<4 {
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return controller.sizeThatFits(in: .zero)
    }

    func testDeviceListIsVisible() {
        let size = renderedSize(.preview(mode: .speaker))
        XCTAssertEqual(size.width, 340)
        // Header and footer alone are about 230pt; two sections of rows add well over 200.
        XCTAssertGreaterThan(size.height, 450, "device list collapsed to zero height")
    }

    func testManualModeShowsMoreSectionsThanAutoMode() {
        let auto = renderedSize(.preview(mode: .speaker))
        let manual = renderedSize(.preview(mode: .speaker, custom: true))
        XCTAssertGreaterThan(manual.height, auto.height, "manual mode adds the headphones section")
    }

    func testCallModeBannerAddsHeight() {
        let normal = renderedSize(.preview(mode: .headphone))
        let callMode = renderedSize(.preview(mode: .headphone, callMode: true))
        XCTAssertGreaterThan(callMode.height, normal.height)
    }
}
