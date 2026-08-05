import SwiftUI

struct PortSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var ports: [ForwardedPort] = []
    @State private var validationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ports")
                        .font(.title2.weight(.semibold))
                    Text("Choose what Flamm forwards and add optional names for the menu.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label(
                    model.settings.target.isEmpty ? "No SSH target" : model.settings.target,
                    systemImage: "network"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach($ports) { $port in
                        PortEditorRow(port: $port) {
                            ports.removeAll { $0.id == port.id }
                        }
                    }
                }
                .padding(20)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Divider()

            HStack {
                Button("Add Port", systemImage: "plus") {
                    ports.append(
                        ForwardedPort(
                            alias: "",
                            localPort: nextAvailablePort,
                            remotePort: nextAvailablePort
                        )
                    )
                }

                Spacer()

                Button("Revert") {
                    loadPorts()
                }
                .disabled(ports == model.settings.ports)

                Button("Apply") {
                    apply()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ports == model.settings.ports)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: loadPorts)
    }

    private var nextAvailablePort: Int {
        let usedPorts = Set(ports.map(\.localPort))
        return (8_000...65_535).first { !usedPorts.contains($0) } ?? 8_000
    }

    private func loadPorts() {
        ports = model.settings.ports
        validationMessage = nil
    }

    private func apply() {
        if let message = PortValidation.message(for: ports) {
            validationMessage = message
            return
        }

        validationMessage = nil
        model.replacePorts(
            ports.map { port in
                var normalized = port
                normalized.alias = port.alias.trimmingCharacters(in: .whitespacesAndNewlines)
                normalized.remoteHost = port.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized
            }
        )
    }
}

private struct PortEditorRow: View {
    @Binding var port: ForwardedPort
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Toggle("Enable \(port.menuLabel)", isOn: $port.isEnabled)
                    .labelsHidden()

                TextField("Name (optional)", text: $port.alias)
                    .textFieldStyle(.plain)
                    .font(.headline)

                Spacer(minLength: 8)

                Text(port.portMapping)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove \(port.menuLabel)")
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                EndpointEditor(
                    title: "Local",
                    systemImage: "laptopcomputer",
                    host: .constant("127.0.0.1"),
                    port: $port.localPort,
                    hostIsEditable: false
                )

                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                EndpointEditor(
                    title: "Remote",
                    systemImage: "server.rack",
                    host: $port.remoteHost,
                    port: $port.remotePort,
                    hostIsEditable: true
                )
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
    }
}

private struct EndpointEditor: View {
    let title: String
    let systemImage: String
    @Binding var host: String
    @Binding var port: Int
    let hostIsEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                if hostIsEditable {
                    TextField("Host", text: $host)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(host)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(":")
                    .foregroundStyle(.tertiary)

                TextField("Port", value: $port, format: .number.grouping(.never))
                    .frame(width: 72)
            }
            .textFieldStyle(.roundedBorder)
            .font(.body.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
