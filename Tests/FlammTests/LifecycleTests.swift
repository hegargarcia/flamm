import Foundation

@main
@MainActor
final class LifecycleTests {
    static func main() async throws {
        let tests = LifecycleTests()
        let cases: [(String, () async throws -> Void)] = [
            ("identical settings and labels", tests.testIdenticalNamesAndOrderDoNotTouchConnections),
            ("mapping replacement", tests.testMappingEditReleasesOldForwardAndKeepsUnchangedForward),
            ("port swap", tests.testPortSwapCancelsBothBeforeInstallingEither),
            ("target replacement and stale exit", tests.testTargetReplacementWaitsForConfirmedExitAndIgnoresOldExit),
            ("disable during install", tests.testDisableDuringInstallRemovesLateForwardWithoutRestartingMaster),
            ("stop during install", tests.testStopDuringInstallReleasesLateForwardAndDoesNotRetry),
            ("recovery preserves stop", tests.testRecoveryPreservesIndividuallyStoppedPorts),
            ("backoff and stop", tests.testRepeatedFailuresBackOffAndStopCancelsRetry),
            ("cancel failure", tests.testCancelFailureClosesMasterBeforeReplacement),
            ("occupied port recovery", tests.testOccupiedPortRecoveryKeepsHealthyForward),
            ("uncertain install result", tests.testUncertainInstallReleasesMasterBeforeRetry),
            ("rejected forward", tests.testRejectedForwardKeepsHealthyForward),
            ("shutdown", tests.testShutdownAwaitsPendingInstallAndPreservesLaunchPreference),
            ("network recovery", tests.testNetworkRecoveryExpeditesAndCoalescesRetryButRespectsStop),
        ]
        for (name, test) in cases {
            tests.setUp()
            try await test()
            tests.tearDown()
            print("Passed: \(name)")
        }
        try await TransportTests.run()
        print("Flamm lifecycle tests passed")
    }

    private var defaults: UserDefaults!
    private var suite: String!

    private func setUp() {
        suite = "dev.hegar.flamm.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    private func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func model(
        _ tunnel: FakeTunnel,
        ports: [ForwardedPort],
        isPortAvailable: @escaping (Int) -> Bool = { _ in true },
        retryInterval: @escaping (Int) -> TimeInterval = { _ in 60 }
    ) throws -> AppModel {
        let settings = AppSettings(target: "test-host", ports: ports, isProxyEnabled: false)
        defaults.set(try JSONEncoder().encode(settings), forKey: "appSettings")
        return AppModel(defaults: defaults, tunnel: tunnel, monitorConnection: false, isPortAvailable: isPortAvailable, retryInterval: retryInterval)
    }

    private func ports() -> [ForwardedPort] {
        [ForwardedPort(alias: "Web", localPort: 49151, remotePort: 3000),
         ForwardedPort(alias: "DB", localPort: 49152, remotePort: 5432)]
    }

    func testIdenticalNamesAndOrderDoNotTouchConnections() async throws {
        let tunnel = FakeTunnel()
        var ports = ports()
        let model = try model(tunnel, ports: ports)
        model.toggleConnection()
        await model.waitForPendingChanges()
        let events = tunnel.events
        model.replacePorts(ports)
        ports[0].alias = "Renamed"
        model.replacePorts(ports.reversed())
        await model.waitForPendingChanges()
        expectEqual(tunnel.events, events)
        expectEqual(model.activePortIDs, Set(ports.map(\.id)))
        model.disableConnection()
        await model.waitForPendingChanges()
    }

    func testMappingEditReleasesOldForwardAndKeepsUnchangedForward() async throws {
        let tunnel = FakeTunnel()
        var ports = ports()
        let model = try model(tunnel, ports: ports)
        model.toggleConnection()
        await model.waitForPendingChanges()
        tunnel.events = []
        ports[0].remotePort = 3001
        model.replacePorts(ports)
        await model.waitForPendingChanges()
        expectEqual(tunnel.events, ["cancel:49151:3000", "install:49151:3001"])
        expectEqual(model.activePortIDs, Set(ports.map(\.id)))
        model.disableConnection()
        await model.waitForPendingChanges()
    }

    func testPortSwapCancelsBothBeforeInstallingEither() async throws {
        let tunnel = FakeTunnel()
        var ports = ports()
        let model = try model(tunnel, ports: ports)
        model.toggleConnection()
        await model.waitForPendingChanges()
        tunnel.events = []
        ports.swapAt(0, 1)
        let localPort = ports[0].localPort
        ports[0].localPort = ports[1].localPort
        ports[1].localPort = localPort
        model.replacePorts(ports)
        await model.waitForPendingChanges()
        expectEqual(tunnel.events.count, 4)
        expectTrue(tunnel.events.prefix(2).allSatisfy { $0.hasPrefix("cancel:") })
        expectTrue(tunnel.events.suffix(2).allSatisfy { $0.hasPrefix("install:") })
        model.disableConnection()
        await model.waitForPendingChanges()
    }

    func testTargetReplacementWaitsForConfirmedExitAndIgnoresOldExit() async throws {
        let tunnel = FakeTunnel()
        let model = try model(tunnel, ports: ports())
        model.toggleConnection()
        await model.waitForPendingChanges()
        let oldExit = tunnel.onExit
        tunnel.events = []
        tunnel.holdStop = true
        model.selectTarget("new-host")
        await eventually { tunnel.stopContinuation != nil }
        expectEqual(tunnel.events, ["stopping"])
        oldExit?(255, "late exit")
        model.selectTarget("latest-host")
        tunnel.finishStop()
        await model.waitForPendingChanges()
        expectEqual(tunnel.events.prefix(3), ["stopping", "stopped", "start:latest-host"])
        expectEqual(model.connectionState, .connected)
        model.disableConnection()
        await model.waitForPendingChanges()
    }

    func testDisableDuringInstallRemovesLateForwardWithoutRestartingMaster() async throws {
        let tunnel = FakeTunnel()
        let ports = ports()
        let model = try model(tunnel, ports: ports)
        tunnel.holdInstall = true
        model.toggleConnection()
        await eventually { tunnel.installContinuation != nil }
        model.disablePort(ports[0].id)
        tunnel.finishInstall()
        await model.waitForPendingChanges()
        expectEqual(model.activePortIDs, [ports[1].id])
        expectEqual(tunnel.events.filter { $0.hasPrefix("start:") }.count, 1)
        expectTrue(tunnel.events.contains("cancel:49151:3000"))
        expectFalse(tunnel.installed.contains(ports[0].localPort))
        model.disableConnection()
        await model.waitForPendingChanges()
    }

    func testStopDuringInstallReleasesLateForwardAndDoesNotRetry() async throws {
        let tunnel = FakeTunnel()
        let model = try model(tunnel, ports: ports(), retryInterval: { _ in 0.01 })
        tunnel.holdInstall = true
        model.toggleConnection()
        await eventually { tunnel.installContinuation != nil }
        model.disableConnection()
        tunnel.finishInstall()
        await model.waitForPendingChanges()
        try await Task.sleep(nanoseconds: 30_000_000)
        expectFalse(tunnel.isRunning)
        expectTrue(tunnel.installed.isEmpty)
        expectEqual(model.connectionState, .stopped)
        expectNil(model.retryDelay)
        expectEqual(tunnel.events.filter { $0.hasPrefix("start:") }.count, 1)
    }

    func testRecoveryPreservesIndividuallyStoppedPorts() async throws {
        let tunnel = FakeTunnel()
        let ports = ports()
        let model = try model(tunnel, ports: ports, retryInterval: { _ in 0.01 })
        model.toggleConnection()
        await model.waitForPendingChanges()
        model.stopPort(ports[0].id)
        await model.waitForPendingChanges()
        tunnel.events = []
        tunnel.exit()
        await eventually { tunnel.events.contains("install:49152:5432") }
        await model.waitForPendingChanges()
        expectFalse(tunnel.events.contains("install:49151:3000"))
        expectEqual(model.activePortIDs, [ports[1].id])
        expectEqual(model.connectionState, .connected)
        model.disableConnection()
        await model.waitForPendingChanges()
    }

    func testRepeatedFailuresBackOffAndStopCancelsRetry() async throws {
        let tunnel = FakeTunnel()
        tunnel.failStart = true
        var attempts = [Int]()
        let model = try model(tunnel, ports: ports(), retryInterval: { attempt in
            attempts.append(attempt)
            return 0.01
        })
        model.toggleConnection()
        await eventually { attempts.count >= 4 }
        expectEqual(Array(attempts.prefix(4)), [0, 1, 2, 3])
        model.disableConnection()
        await model.waitForPendingChanges()
        let count = attempts.count
        try await Task.sleep(nanoseconds: 40_000_000)
        expectEqual(attempts.count, count)
        expectNil(model.retryDelay)
        expectEqual(model.connectionState, .stopped)
    }

    func testCancelFailureClosesMasterBeforeReplacement() async throws {
        let tunnel = FakeTunnel()
        var ports = ports()
        let model = try model(tunnel, ports: ports, retryInterval: { _ in 0.01 })
        model.toggleConnection()
        await model.waitForPendingChanges()
        tunnel.events = []
        tunnel.failCancel = true
        ports[0].remotePort = 3001
        model.replacePorts(ports)
        await eventually { tunnel.events.contains("install:49151:3001") }
        await model.waitForPendingChanges()
        expectEqual(Array(tunnel.events.prefix(4)), ["cancel:49151:3000", "stopping", "stopped", "start:test-host"])
        model.disableConnection()
        await model.waitForPendingChanges()
    }

    func testNetworkRecoveryExpeditesAndCoalescesRetryButRespectsStop() async throws {
        let tunnel = FakeTunnel()
        tunnel.failStart = true
        let model = try model(tunnel, ports: ports())
        model.toggleConnection()
        await model.waitForPendingChanges()
        expectEqual(model.retryDelay, 60)
        model.networkChanged(available: false)
        model.networkChanged(available: true)
        expectEqual(model.retryDelay, 1)
        model.networkChanged(available: true)
        expectEqual(model.retryDelay, 1)
        model.disableConnection()
        await model.waitForPendingChanges()
        model.networkChanged(available: false)
        model.networkChanged(available: true)
        expectNil(model.retryDelay)
    }

    func testOccupiedPortRecoveryKeepsHealthyForward() async throws {
        let tunnel = FakeTunnel()
        let ports = ports()
        var occupied = true
        let model = try model(tunnel, ports: ports, isPortAvailable: { port in
            port != ports[1].localPort || !occupied
        }, retryInterval: { _ in 0.03 })
        model.toggleConnection()
        await model.waitForPendingChanges()
        expectEqual(model.activePortIDs, [ports[0].id])
        expectTrue(model.portWarnings[ports[1].id] != nil)
        occupied = false
        await eventually { model.activePortIDs.contains(ports[1].id) }
        await model.waitForPendingChanges()
        expectEqual(tunnel.events.filter { $0.hasPrefix("start:") }.count, 1)
        expectFalse(tunnel.events.contains("cancel:49151:3000"))
        expectNil(model.portWarnings[ports[1].id])
        expectNil(model.retryDelay)
        model.disableConnection()
        await model.waitForPendingChanges()
    }

    func testUncertainInstallReleasesMasterBeforeRetry() async throws {
        let tunnel = FakeTunnel()
        let ports = ports()
        tunnel.failInstallPort = ports[1].localPort
        let model = try model(tunnel, ports: ports, retryInterval: { _ in 0.03 })
        model.toggleConnection()
        await model.waitForPendingChanges()
        expectFalse(tunnel.isRunning)
        expectTrue(tunnel.installed.isEmpty)
        expectTrue(model.activePortIDs.isEmpty)
        tunnel.failInstallPort = nil
        await eventually { model.activePortIDs.count == 2 }
        await model.waitForPendingChanges()
        expectEqual(model.connectionState, .connected)
        model.disableConnection()
        await model.waitForPendingChanges()
    }

    func testRejectedForwardKeepsHealthyForward() async throws {
        let tunnel = FakeTunnel()
        let ports = ports()
        tunnel.rejectInstallPort = ports[1].localPort
        let model = try model(tunnel, ports: ports, retryInterval: { _ in 0.03 })
        model.toggleConnection()
        await model.waitForPendingChanges()
        expectEqual(model.activePortIDs, [ports[0].id])
        expectTrue(tunnel.isRunning)
        expectTrue(model.portErrors[ports[1].id] != nil)
        tunnel.rejectInstallPort = nil
        await eventually { model.activePortIDs.count == 2 }
        await model.waitForPendingChanges()
        expectEqual(tunnel.events.filter { $0.hasPrefix("start:") }.count, 1)
        expectNil(model.portErrors[ports[1].id])
        model.disableConnection()
        await model.waitForPendingChanges()
    }

    func testShutdownAwaitsPendingInstallAndPreservesLaunchPreference() async throws {
        let tunnel = FakeTunnel()
        let model = try model(tunnel, ports: ports())
        tunnel.holdInstall = true
        model.toggleConnection()
        await eventually { tunnel.installContinuation != nil }
        let shutdown = Task { await model.shutdown() }
        await Task.yield()
        tunnel.finishInstall()
        await shutdown.value
        expectFalse(tunnel.isRunning)
        expectTrue(tunnel.installed.isEmpty)
        expectTrue(model.settings.isProxyEnabled)
        model.networkChanged(available: false)
        model.networkChanged(available: true)
        expectNil(model.retryDelay)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #file, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Timed out waiting for lifecycle event", file: file, line: line)
    }
}

@MainActor
private final class FakeTunnel: TunnelTransport {
    var isRunning = false
    var events = [String]()
    var installed = Set<Int>()
    var onExit: ((Int32, String) -> Void)?
    var holdInstall = false
    var holdStop = false
    var failStart = false
    var failCancel = false
    var failInstallPort: Int?
    var rejectInstallPort: Int?
    var installContinuation: CheckedContinuation<Void, Never>?
    var stopContinuation: CheckedContinuation<Void, Never>?

    func start(target: String, onExit: @escaping (Int32, String) -> Void) throws {
        expectFalse(isRunning, "Old master must exit before replacement starts")
        events.append("start:\(target)")
        if failStart { throw NSError(domain: "test", code: 1) }
        self.onExit = onExit
        isRunning = true
    }

    func installForward(_ port: ForwardedPort) async -> SSHTunnel.ForwardingResult {
        events.append("install:\(port.localPort):\(port.remotePort)")
        if holdInstall { await withCheckedContinuation { installContinuation = $0 } }
        if failInstallPort == port.localPort { return .uncertain("install timed out") }
        if rejectInstallPort == port.localPort { return .failure("install rejected") }
        expectTrue(installed.insert(port.localPort).inserted, "Old mapping must be removed before replacement")
        return .success
    }

    func cancelForward(_ port: ForwardedPort) async -> SSHTunnel.ForwardingResult {
        events.append("cancel:\(port.localPort):\(port.remotePort)")
        if failCancel { return .failure("cancel failed") }
        installed.remove(port.localPort)
        return .success
    }

    func stop() async {
        guard isRunning else { return }
        events.append("stopping")
        if holdStop { await withCheckedContinuation { stopContinuation = $0 } }
        isRunning = false
        installed = []
        events.append("stopped")
    }

    func terminate() { isRunning = false }

    func finishInstall() {
        holdInstall = false
        installContinuation?.resume()
        installContinuation = nil
    }

    func finishStop() {
        holdStop = false
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func exit() {
        isRunning = false
        installed = []
        onExit?(255, "Connection lost")
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}

private func expectTrue(_ value: Bool, _ message: String = "Expected true", file: StaticString = #file, line: UInt = #line) {
    precondition(value, message, file: file, line: line)
}

private func expectFalse(_ value: Bool, _ message: String = "Expected false", file: StaticString = #file, line: UInt = #line) {
    precondition(!value, message, file: file, line: line)
}

private func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "Expected nil", file: file, line: line)
}
