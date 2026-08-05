import AppKit
import Foundation

@MainActor
final class AppModel: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case stopped
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var settings: AppSettings
    @Published private(set) var hosts: [String]
    @Published private(set) var connectionState: ConnectionState = .stopped
    @Published private(set) var activePortIDs = Set<UUID>()
    @Published private(set) var reachablePorts = Set<UUID>()
    @Published private(set) var portErrors = [UUID: String]()
    @Published private(set) var portWarnings = [UUID: String]()

    private let defaults: UserDefaults
    private let sshConfig: SSHConfig
    private let tunnel = SSHTunnel()
    private var reachabilityTimer: Timer?
    private var settingsWindowController: PortSettingsWindowController?
    private var connectionGeneration = 0

    private static let settingsKey = "appSettings"
    private static let legacyDefaultsSuiteName = "dev.hegar.ft"

    init(defaults: UserDefaults = .standard, sshConfig: SSHConfig = SSHConfig()) {
        self.defaults = defaults
        self.sshConfig = sshConfig

        let availableHosts = sshConfig.hosts()
        hosts = availableHosts
        var shouldPersistSettings = false
        let currentSettingsData = defaults.data(forKey: Self.settingsKey)
        let savedSettingsData = currentSettingsData
            ?? UserDefaults(suiteName: Self.legacyDefaultsSuiteName)?
                .data(forKey: Self.settingsKey)

        if currentSettingsData == nil, savedSettingsData != nil {
            shouldPersistSettings = true
        }

        if
            let data = savedSettingsData,
            let savedSettings = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            var migratedSettings = savedSettings
            for index in migratedSettings.ports.indices {
                let port = migratedSettings.ports[index]
                if port.alias == "Port \(port.localPort)" {
                    migratedSettings.ports[index].alias = ""
                    shouldPersistSettings = true
                }
            }
            settings = migratedSettings
        } else {
            let preferredTarget = availableHosts.first ?? ""
            settings = AppSettings(
                target: preferredTarget,
                ports: sshConfig.effectiveForwards(for: preferredTarget),
                isProxyEnabled: false
            )
        }

        super.init()

        if shouldPersistSettings, let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        reachabilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkReachability()
            }
        }

        if settings.isProxyEnabled {
            Task { @MainActor [weak self] in
                self?.start()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        reachabilityTimer?.invalidate()
    }

    var enabledPorts: [ForwardedPort] {
        settings.ports.filter(\.isEnabled)
    }

    var menuBarSymbol: String {
        switch connectionState {
        case .connected:
            return "arrow.left.arrow.right.circle.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath.circle"
        case .failed:
            return "exclamationmark.circle.fill"
        case .stopped:
            return "arrow.left.arrow.right.circle"
        }
    }

    var connectionLabel: String {
        switch connectionState {
        case .stopped:
            return "Start"
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Stop"
        case .failed:
            return "Retry Connection"
        }
    }

    var connectionSymbol: String {
        switch connectionState {
        case .stopped, .failed:
            return "play.fill"
        case .connecting:
            return "ellipsis"
        case .connected:
            return "stop.fill"
        }
    }

    var connectionError: String? {
        guard case let .failed(message) = connectionState else {
            return nil
        }

        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return String(firstLine.prefix(120))
    }

    func status(for port: ForwardedPort) -> PortStatus {
        guard port.isEnabled else {
            return .disabled
        }

        if portErrors[port.id] != nil {
            return .failed
        }

        if portWarnings[port.id] != nil {
            return .warning
        }

        switch connectionState {
        case .stopped:
            return .stopped
        case .failed:
            return .failed
        case .connecting:
            return .connecting
        case .connected:
            guard activePortIDs.contains(port.id) else {
                return .stopped
            }
            return reachablePorts.contains(port.id) ? .reachable : .unreachable
        }
    }

    func isPortRunning(_ port: ForwardedPort) -> Bool {
        activePortIDs.contains(port.id)
    }

    func error(for port: ForwardedPort) -> String? {
        guard let message = portErrors[port.id] else {
            return nil
        }
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return String(firstLine.prefix(120))
    }

    func warning(for port: ForwardedPort) -> String? {
        portWarnings[port.id]
    }

    func toggleConnection() {
        switch connectionState {
        case .connected, .connecting:
            disableConnection()
        case .stopped, .failed:
            enable()
        }
    }

    func selectTarget(_ target: String) {
        guard settings.target != target else {
            return
        }

        settings.target = target
        persist()
        restartIfNeeded()
    }

    func replacePorts(_ ports: [ForwardedPort]) {
        settings.ports = ports
        persist()
        restartIfNeeded()
    }

    func showPortSettings() {
        if settingsWindowController == nil {
            settingsWindowController = PortSettingsWindowController(model: self)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func startPort(_ portID: UUID) {
        guard let index = settings.ports.firstIndex(where: { $0.id == portID }) else {
            return
        }

        var candidatePorts = settings.ports
        candidatePorts[index].isEnabled = true
        if let message = PortValidation.message(for: candidatePorts) {
            portErrors[portID] = message
            return
        }

        settings.ports[index].isEnabled = true
        let port = settings.ports[index]
        portErrors[portID] = nil
        portWarnings[portID] = nil
        persist()

        guard !activePortIDs.contains(portID) else {
            return
        }

        switch connectionState {
        case .connected:
            guard LocalPortAvailability.isAvailable(port: port.localPort) else {
                portWarnings[portID] = collisionMessage(for: port)
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                switch await self.tunnel.installForward(port) {
                case .success:
                    self.activePortIDs.insert(portID)
                    await self.checkReachability()
                case let .failure(message):
                    self.portErrors[portID] = message
                }
            }
        case .stopped, .failed:
            settings.isProxyEnabled = true
            persist()
            start([port])
        case .connecting:
            break
        }
    }

    func stopPort(_ portID: UUID) {
        guard
            activePortIDs.contains(portID),
            let port = settings.ports.first(where: { $0.id == portID })
        else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            switch self.tunnel.cancelForward(port) {
            case .success:
                self.finishPortStop(portID)
            case let .failure(message):
                self.portErrors[portID] = message
            }
        }
    }

    func disablePort(_ portID: UUID) {
        guard let index = settings.ports.firstIndex(where: { $0.id == portID }) else {
            return
        }

        settings.ports[index].isEnabled = false
        let port = settings.ports[index]
        portErrors[portID] = nil
        portWarnings[portID] = nil
        persist()

        guard activePortIDs.contains(portID) else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            switch self.tunnel.cancelForward(port) {
            case .success:
                self.finishPortStop(portID)
            case let .failure(message):
                if let index = self.settings.ports.firstIndex(where: { $0.id == portID }) {
                    self.settings.ports[index].isEnabled = true
                    self.persist()
                }
                self.portErrors[portID] = message
            }
        }
    }

    func disableConnection() {
        connectionGeneration += 1
        tunnel.stop()
        settings.isProxyEnabled = false
        connectionState = .stopped
        activePortIDs = []
        reachablePorts = []
        portErrors = [:]
        portWarnings = [:]
        persist()
    }

    private func enable() {
        settings.isProxyEnabled = true
        persist()
        start()
    }

    private func restartIfNeeded() {
        guard settings.isProxyEnabled else {
            return
        }

        guard !enabledPorts.isEmpty else {
            disableConnection()
            return
        }

        connectionGeneration += 1
        tunnel.stop()
        start()
    }

    private func start(_ requestedPorts: [ForwardedPort]? = nil) {
        let requestedPorts = requestedPorts ?? enabledPorts
        guard
            !settings.target.isEmpty,
            !requestedPorts.isEmpty,
            PortValidation.message(for: settings.ports) == nil
        else {
            connectionState = .failed("Choose an SSH target and at least one valid port.")
            return
        }

        connectionGeneration += 1
        let generation = connectionGeneration
        connectionState = .connecting
        activePortIDs = []
        reachablePorts = []
        portErrors = [:]
        for port in requestedPorts {
            portWarnings[port.id] = nil
        }

        let ports = requestedPorts.filter { port in
            if LocalPortAvailability.isAvailable(port: port.localPort) {
                return true
            }

            portWarnings[port.id] = collisionMessage(for: port)
            return false
        }

        guard !ports.isEmpty else {
            settings.isProxyEnabled = false
            connectionState = .stopped
            persist()
            return
        }

        do {
            try tunnel.start(target: settings.target) { [weak self] status, errorOutput in
                guard let self, generation == self.connectionGeneration else {
                    return
                }

                let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                self.connectionState = .failed(
                    message.isEmpty ? "SSH exited with status \(status)." : message
                )
                self.activePortIDs = []
                self.reachablePorts = []
            }
        } catch {
            connectionState = .failed(error.localizedDescription)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let result = await self.tunnel.installForwards(ports)
            guard generation == self.connectionGeneration else {
                return
            }

            switch result {
            case .success:
                self.activePortIDs = Set(ports.map(\.id))
                self.connectionState = .connected
                await self.checkReachability()
            case let .failure(message):
                self.tunnel.stop()
                self.connectionState = .failed(message)
                self.activePortIDs = []
                self.reachablePorts = []
            }
        }
    }

    private func checkReachability() async {
        guard connectionState == .connected else {
            return
        }

        let generation = connectionGeneration
        let ports = settings.ports.filter { activePortIDs.contains($0.id) }
        let results = await withTaskGroup(of: (UUID, Bool).self) { group in
            for port in ports {
                group.addTask {
                    (port.id, await LocalReachability.check(port: port.localPort))
                }
            }

            var results = [(UUID, Bool)]()
            for await result in group {
                results.append(result)
            }
            return results
        }

        guard generation == connectionGeneration, connectionState == .connected else {
            return
        }
        reachablePorts = Set(results.compactMap { id, reachable in
            reachable && activePortIDs.contains(id) ? id : nil
        })
    }

    private func finishPortStop(_ portID: UUID) {
        activePortIDs.remove(portID)
        reachablePorts.remove(portID)
        portErrors[portID] = nil
        portWarnings[portID] = nil

        guard activePortIDs.isEmpty else {
            return
        }

        connectionGeneration += 1
        tunnel.stop()
        settings.isProxyEnabled = false
        connectionState = .stopped
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        defaults.set(data, forKey: Self.settingsKey)
    }

    private func collisionMessage(for port: ForwardedPort) -> String {
        "Local port \(port.localPort) is already in use."
    }

    @objc private func applicationWillTerminate() {
        tunnel.stop()
    }
}
