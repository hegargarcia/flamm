import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: UpdateController

    var body: some View {
        Button(action: model.toggleConnection) {
            Label(model.connectionLabel, systemImage: model.connectionSymbol)
        }

        if let connectionError = model.connectionError {
            Label(connectionError, systemImage: "exclamationmark.triangle.fill")
            Button("Stop", systemImage: "stop.fill", action: model.disableConnection)
        }

        if let delay = model.retryDelay {
            Text("Automatic retry in up to \(Int(ceil(delay)))s")
        }

        Section("Ports") {
            if model.settings.ports.isEmpty {
                Text("No ports configured")
            } else {
                ForEach(model.settings.ports) { port in
                    let status = model.status(for: port)
                    Menu {
                        if model.isPortRunning(port) {
                            Button("Stop", systemImage: "stop.fill") {
                                model.stopPort(port.id)
                            }
                        } else {
                            Button("Start", systemImage: "play.fill") {
                                model.startPort(port.id)
                            }
                            .disabled(model.connectionState == .connecting)
                        }

                        Divider()

                        Button("Disable", systemImage: "nosign") {
                            model.disablePort(port.id)
                        }
                        .disabled(!port.isEnabled)

                        if let error = model.error(for: port) {
                            Divider()
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                        } else if let warning = model.warning(for: port) {
                            Divider()
                            Label(warning, systemImage: "exclamationmark.triangle")
                        }
                    } label: {
                        Label {
                            Text(port.menuLabel)
                        } icon: {
                            Image(nsImage: status.image)
                                .renderingMode(.original)
                                .accessibilityLabel(status.label)
                        }
                    }
                }
            }
        }

        Divider()

        Menu("SSH Target: \(model.settings.target.isEmpty ? "None" : model.settings.target)") {
            if model.hosts.isEmpty {
                Text("No hosts in ~/.ssh/config")
            } else {
                ForEach(model.hosts, id: \.self) { host in
                    Button {
                        model.selectTarget(host)
                    } label: {
                        if host == model.settings.target {
                            Label(host, systemImage: "checkmark")
                        } else {
                            Text(host)
                        }
                    }
                }
            }
        }

        Button("Settings", systemImage: "gearshape") {
            model.showPortSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button(updater.menuTitle, systemImage: "arrow.down.circle") {
            updater.checkForUpdates(model: model)
        }
        .disabled(updater.isBusy)

        Button("Quit", systemImage: "xmark") {
            Task { @MainActor in
                await model.shutdown()
                NSApp.terminate(nil)
            }
        }
        .keyboardShortcut("q")
        .disabled(updater.isBusy)
    }
}

private extension PortStatus {
    var image: NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { bounds in
            color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    var color: NSColor {
        switch self {
        case .disabled:
            return .systemGray
        case .stopped, .failed:
            return .systemRed
        case .connecting, .warning, .unreachable:
            return .systemYellow
        case .reachable:
            return .systemGreen
        }
    }
}
