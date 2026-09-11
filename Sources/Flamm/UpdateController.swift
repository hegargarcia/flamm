import AppKit
import SwiftUI

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var menuTitle = "Check for Updates…"

    func checkForUpdates(model: AppModel) {
        guard !isBusy else { return }
        isBusy = true
        menuTitle = "Checking for Updates…"
        Task {
            defer {
                isBusy = false
                menuTitle = "Check for Updates…"
            }
            do {
                guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
                    throw UpdateError("Updates are available in the packaged Flamm.app. Build or install the app bundle first.")
                }
                guard let download = try await AppUpdate.check(currentVersion: current) else {
                    showAlert(title: "You're up to date", message: "Flamm \(current) is the latest available version.")
                    return
                }
                let destination = Bundle.main.bundleURL
                try AppUpdate.validateDestination(destination)
                let alert = NSAlert()
                alert.messageText = "Flamm \(download.version) is available"
                alert.informativeText = "You have version \(current). Install the update and restart Flamm? Active SSH tunnels will briefly disconnect. Your settings will be preserved."
                alert.addButton(withTitle: "Install and Restart")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                menuTitle = "Downloading Update…"
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try await AppUpdate.prepare(download, destination: destination)
                }.value
                menuTitle = "Restarting…"
                do {
                    try await prepared.launchInstaller()
                } catch {
                    prepared.cleanup()
                    throw error
                }
                await model.shutdown()
                NSApp.terminate(nil)
            } catch {
                showAlert(title: "Could not update Flamm", message: error.localizedDescription, offerDownload: true)
            }
        }
    }

    private func showAlert(title: String, message: String, offerDownload: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if offerDownload { alert.addButton(withTitle: "Open GitHub Releases") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(AppUpdate.releasesURL) }
    }
}
