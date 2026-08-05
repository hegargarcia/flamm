import AppKit
import SwiftUI

@MainActor
final class PortSettingsWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let hostingController = NSHostingController(rootView: PortSettingsView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Flamm Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 520))
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    override func showWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
