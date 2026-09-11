import Darwin
import Foundation

@MainActor
enum TransportTests {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-ssh")
        // This fixture holds a real loopback listener and ignores TERM. It does not use SSH,
        // credentials, or a remote host. Large stderr also exercises nonblocking pipe draining.
        let script = #"""
        #!/usr/bin/python3
        import signal, socket, sys, time
        if "-O" in sys.argv:
            if sys.argv[sys.argv.index("-O") + 1] == "cancel":
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                while True:
                    time.sleep(1)
            sys.stderr.write("x" * 200000)
            sys.exit(0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        with open(sys.argv[-1], "w") as output:
            output.write(str(listener.getsockname()[1]))
        control = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("ControlPath="))
        open(control, "w").close()
        while True:
            time.sleep(1)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let portFile = directory.appendingPathComponent("port")
        let tunnel = SSHTunnel(executableURL: executable)
        defer { tunnel.terminate() }
        try tunnel.start(target: portFile.path) { _, _ in preconditionFailure("Stopped session delivered an exit callback") }
        var reportedPort: Int?
        for _ in 0..<200 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let port = Int(text) {
                reportedPort = port
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let port = reportedPort else { preconditionFailure("Fixture did not open its listener") }
        precondition(!LocalPortAvailability.isAvailable(port: port))
        let forward = ForwardedPort(alias: "Fixture", localPort: port, remotePort: 3000)
        guard case .success = await tunnel.installForward(forward) else {
            preconditionFailure("Control command failed to drain large output")
        }
        // Control commands must time out, and the main actor must continue servicing work.
        var heartbeat = false
        let command = Task { await tunnel.cancelForward(forward) }
        let ticker = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            heartbeat = true
        }
        guard case let .uncertain(message) = await command.value else {
            preconditionFailure("Hung control command did not fail")
        }
        precondition(message.contains("Timed out"))
        precondition(heartbeat)
        await ticker.value
        let start = Date()
        let stop = Task { await tunnel.stop() }
        stop.cancel()
        await stop.value
        precondition(Date().timeIntervalSince(start) < 4)
        precondition(!tunnel.isRunning)
        precondition(LocalPortAvailability.isAvailable(port: port), "Stop returned before releasing its listener")
        print("Passed: real subprocess timeout, forced exit, pipe draining, and port release")
    }
}
