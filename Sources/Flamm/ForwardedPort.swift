import Foundation

struct ForwardedPort: Codable, Equatable, Identifiable {
    var id: UUID
    var alias: String
    var localPort: Int
    var remoteHost: String
    var remotePort: Int
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        alias: String,
        localPort: Int,
        remoteHost: String = "127.0.0.1",
        remotePort: Int,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.alias = alias
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.isEnabled = isEnabled
    }

    func hasSameForward(as other: ForwardedPort) -> Bool {
        localPort == other.localPort && remoteHost == other.remoteHost && remotePort == other.remotePort
    }

    var name: String? {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAlias.isEmpty ? nil : trimmedAlias
    }

    var portMapping: String {
        if localPort == remotePort {
            return String(localPort)
        }
        return "\(localPort):\(remotePort)"
    }

    var menuLabel: String {
        guard let name else {
            return portMapping
        }
        return "\(name) · \(portMapping)"
    }
}

struct AppSettings: Codable, Equatable {
    var target: String
    var ports: [ForwardedPort]
    var isProxyEnabled: Bool
}

enum PortStatus: Equatable {
    case disabled
    case stopped
    case failed
    case warning
    case connecting
    case reachable
    case unreachable

    var label: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .stopped:
            return "Stopped"
        case .failed:
            return "Connection failed"
        case .warning:
            return "Local port in use"
        case .connecting:
            return "Connecting"
        case .reachable:
            return "Reachable"
        case .unreachable:
            return "Not reachable"
        }
    }
}

enum PortValidation {
    static func message(for ports: [ForwardedPort]) -> String? {
        for port in ports {
            if !(1...65_535).contains(port.localPort) || !(1...65_535).contains(port.remotePort) {
                return "Ports must be between 1 and 65535."
            }

            if port.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Every port needs a remote host."
            }
        }

        let enabledLocalPorts = ports.filter(\.isEnabled).map(\.localPort)
        if Set(enabledLocalPorts).count != enabledLocalPorts.count {
            return "Enabled proxies cannot share a local port."
        }

        return nil
    }
}
