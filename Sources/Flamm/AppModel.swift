import AppKit
import Foundation
import Network

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
    private let tunnel: any TunnelTransport
    private var lifecycleTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var installedPorts = [UUID: ForwardedPort]()
    private var stoppedPortIDs = Set<UUID>()
    private var sessionTarget: String?
    private var retryAttempt = 0
    private var connectedSince: Date?
    private var forceReconnect = false
    private var isShuttingDown = false
    private var pathMonitor: NWPathMonitor?
    private var networkWasUnavailable = false
    @Published private(set) var retryDelay: TimeInterval?
    private let retryInterval: (Int) -> TimeInterval
    private let isPortAvailable: (Int) -> Bool
    private let monitorConnection: Bool
    private var reachabilityTimer: Timer?
    private var settingsWindowController: PortSettingsWindowController?
    private var connectionGeneration = 0

    private static let settingsKey = "appSettings"
    private static let legacyDefaultsSuiteName = "dev.hegar.ft"

    init(
        defaults: UserDefaults = .standard,
        sshConfig: SSHConfig = SSHConfig(),
        tunnel: (any TunnelTransport)? = nil,
        monitorConnection: Bool = true,
        isPortAvailable: @escaping (Int) -> Bool = LocalPortAvailability.isAvailable,
        retryInterval: @escaping (Int) -> TimeInterval = { attempt in
            min(30, pow(2, Double(min(attempt, 5))) * Double.random(in: 0.8...1.2))
        }
    ) {
        self.tunnel = tunnel ?? SSHTunnel()
        self.retryInterval = retryInterval
        self.isPortAvailable = isPortAvailable
        self.monitorConnection = monitorConnection
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

        if monitorConnection {
            reachabilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.checkReachability() }
            }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in self?.networkChanged(available: path.status == .satisfied) }
            }
            monitor.start(queue: DispatchQueue(label: "dev.hegar.flamm.network"))
            pathMonitor = monitor
            if settings.isProxyEnabled { reconcileSoon() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        reachabilityTimer?.invalidate()
        pathMonitor?.cancel()
        lifecycleTask?.cancel()
        retryTask?.cancel()
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
            return "Stop Connecting"
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
            return "stop.fill"
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
        reconcileSoon()
    }

    func replacePorts(_ ports: [ForwardedPort]) {
        guard settings.ports != ports else { return }
        let previous = settings.ports
        settings.ports = ports
        stoppedPortIDs.formIntersection(ports.filter(\.isEnabled).map(\.id))
        persist()
        // Names and order do not affect an SSH forwarding rule.
        let changed = previous.count != ports.count || ports.contains { port in
            !previous.contains { $0.id == port.id && $0.hasSameForward(as: port) && $0.isEnabled == port.isEnabled }
        }
        if changed { reconcileSoon() }
    }

    func showPortSettings() {
        if settingsWindowController == nil {
            settingsWindowController = PortSettingsWindowController(model: self)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func startPort(_ portID: UUID) {
        guard let index = settings.ports.firstIndex(where: { $0.id == portID }) else { return }
        var ports = settings.ports
        ports[index].isEnabled = true
        if let message = PortValidation.message(for: ports) {
            portErrors[portID] = message
            return
        }
        // Starting one port while stopped should not start every other enabled port.
        if !settings.isProxyEnabled {
            stoppedPortIDs = Set(enabledPorts.map(\.id))
        }
        stoppedPortIDs.remove(portID)
        settings.ports = ports
        settings.isProxyEnabled = true
        portErrors[portID] = nil
        portWarnings[portID] = nil
        persist()
        reconcileSoon()
    }

    func stopPort(_ portID: UUID) {
        stoppedPortIDs.insert(portID)
        stopIfNoPortsDesired()
        reconcileSoon()
    }

    func disablePort(_ portID: UUID) {
        guard let index = settings.ports.firstIndex(where: { $0.id == portID }) else { return }
        settings.ports[index].isEnabled = false
        stoppedPortIDs.remove(portID)
        portErrors[portID] = nil
        portWarnings[portID] = nil
        stopIfNoPortsDesired()
        persist()
        reconcileSoon()
    }

    func disableConnection() {
        settings.isProxyEnabled = false
        retryAttempt = 0
        connectionState = .stopped
        portErrors = [:]
        portWarnings = [:]
        persist()
        reconcileSoon()
    }

    private func enable() {
        if !settings.isProxyEnabled { stoppedPortIDs = [] }
        settings.isProxyEnabled = true
        persist()
        reconcileSoon()
    }

    private var desiredPorts: [ForwardedPort] {
        enabledPorts.filter { !stoppedPortIDs.contains($0.id) }
    }

    private func stopIfNoPortsDesired() {
        if desiredPorts.isEmpty {
            settings.isProxyEnabled = false
            connectionState = .stopped
            persist()
        }
    }

    // Every operation waits for its predecessor, including cancelled work. An in-flight
    // install must finish before a later edit/stop can release its forwarding rule.
    private func reconcileSoon() {
        guard !isShuttingDown else { return }
        retryTask?.cancel()
        retryTask = nil
        retryDelay = nil
        lifecycleTask?.cancel()
        let previous = lifecycleTask
        lifecycleTask = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            await self.reconcile()
        }
    }

    private func closeSession() async {
        connectionGeneration += 1
        resetBackoffAfterStableConnection()
        await tunnel.stop()
        sessionTarget = nil
        installedPorts = [:]
        activePortIDs = []
        reachablePorts = []
        connectedSince = nil
    }

    private func reconcile() async {
        if forceReconnect || sessionTarget != settings.target || !tunnel.isRunning
            || !settings.isProxyEnabled || desiredPorts.isEmpty {
            forceReconnect = false
            await closeSession()
        }
        guard !Task.isCancelled else { return }
        guard settings.isProxyEnabled, !desiredPorts.isEmpty else {
            stopIfNoPortsDesired()
            connectionState = .stopped
            return
        }
        guard !settings.target.isEmpty, PortValidation.message(for: settings.ports) == nil else {
            await closeSession()
            connectionState = .failed("Choose an SSH target and at least one valid port.")
            return
        }

        // Remove all changed mappings first, including port swaps, before installing any.
        for port in Array(installedPorts.values) {
            guard !Task.isCancelled else { return }
            if desiredPorts.contains(where: { $0.id == port.id && $0.hasSameForward(as: port) }) { continue }
            let result = await tunnel.cancelForward(port)
            switch result {
            case .success:
                installedPorts[port.id] = nil
                activePortIDs.remove(port.id)
                reachablePorts.remove(port.id)
            case .cancelled:
                return
            case let .failure(message), let .uncertain(message):
                // A failed cancel leaves ownership uncertain. Reap the master before retrying.
                await connectionFailed(message)
                return
            }
        }
        guard !Task.isCancelled else { return }
        if sessionTarget == nil {
            connectionState = .connecting
            let generation = connectionGeneration
            do {
                try tunnel.start(target: settings.target) { [weak self] status, output in
                    guard let self, !self.isShuttingDown, generation == self.connectionGeneration else { return }
                    self.connectionState = .failed(output.isEmpty ? "SSH exited with status \(status)." : output)
                    self.activePortIDs = []
                    self.reachablePorts = []
                    self.forceReconnect = true
                    self.lifecycleTask?.cancel()
                    self.resetBackoffAfterStableConnection()
                    self.scheduleRetry()
                }
                sessionTarget = settings.target
            } catch {
                await connectionFailed(error.localizedDescription)
                return
            }
        }
        for port in desiredPorts {
            guard !Task.isCancelled else { return }
            if installedPorts[port.id] != nil { continue }
            portErrors[port.id] = nil
            portWarnings[port.id] = nil
            guard isPortAvailable(port.localPort) else {
                portWarnings[port.id] = collisionMessage(for: port)
                continue
            }
            switch await tunnel.installForward(port) {
            case .success:
                installedPorts[port.id] = port
                // A newer reconciliation removes obsolete installs before doing anything else.
                if !Task.isCancelled { activePortIDs.insert(port.id) }
            case .cancelled:
                return
            case let .failure(message):
                guard !Task.isCancelled else { return }
                guard tunnel.isRunning else {
                    await connectionFailed(message)
                    return
                }
                portErrors[port.id] = message
            case let .uncertain(message):
                // Even a timed-out request may have reached the master; close it to release
                // any forwarding whose result could not be confirmed.
                await connectionFailed(message)
                return
            }
        }
        guard !Task.isCancelled else { return }
        activePortIDs = Set(installedPorts.keys)
        if installedPorts.isEmpty {
            await closeSession()
            connectionState = .failed(portErrors.values.first ?? "No requested local ports are available.")
            scheduleRetry()
            return
        }
        connectionState = .connected
        if connectedSince == nil { connectedSince = Date() }
        // Retry occupied ports without interrupting the healthy forwards.
        if installedPorts.count < desiredPorts.count { scheduleRetry() }
        await checkReachability()
    }

    private func connectionFailed(_ message: String) async {
        await closeSession()
        guard !Task.isCancelled else { return }
        connectionState = .failed(message)
        scheduleRetry()
    }

    private func resetBackoffAfterStableConnection() {
        if let connectedSince, Date().timeIntervalSince(connectedSince) >= 30 { retryAttempt = 0 }
        connectedSince = nil
    }

    private func scheduleRetry(after interval: TimeInterval? = nil) {
        guard !isShuttingDown, settings.isProxyEnabled, !desiredPorts.isEmpty, retryTask == nil else { return }
        let delay = interval ?? retryInterval(retryAttempt)
        retryAttempt = min(retryAttempt + 1, 6)
        retryDelay = delay
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.reconcileSoon()
        }
    }

    func networkChanged(available: Bool) {
        let recovered = available && networkWasUnavailable
        networkWasUnavailable = !available
        guard recovered, !isShuttingDown, settings.isProxyEnabled else { return }
        // Give the route a moment to settle, coalescing repeated path notifications.
        forceReconnect = true
        if let retryDelay, retryDelay <= 1 { return }
        retryTask?.cancel()
        retryTask = nil
        scheduleRetry(after: 1)
    }

    func shutdown() async {
        isShuttingDown = true
        retryTask?.cancel()
        retryTask = nil
        retryDelay = nil
        lifecycleTask?.cancel()
        await lifecycleTask?.value
        await closeSession()
    }

    // Allows focused lifecycle tests to wait for all currently requested work.
    func waitForPendingChanges() async {
        await lifecycleTask?.value
    }

    private func checkReachability() async {
        guard monitorConnection, connectionState == .connected else {
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
        lifecycleTask?.cancel()
        retryTask?.cancel()
        tunnel.terminate()
    }
}
