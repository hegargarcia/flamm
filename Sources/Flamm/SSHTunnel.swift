import Darwin
import Foundation

@MainActor
protocol TunnelTransport: AnyObject {
    var isRunning: Bool { get }
    func start(target: String, onExit: @escaping (Int32, String) -> Void) throws
    func installForward(_ port: ForwardedPort) async -> SSHTunnel.ForwardingResult
    func cancelForward(_ port: ForwardedPort) async -> SSHTunnel.ForwardingResult
    func stop() async
    func terminate()
}

@MainActor
final class SSHTunnel: TunnelTransport {
    private enum ControlCommand: String {
        case forward
        case cancel
    }

    enum ForwardingResult {
        case success
        case cancelled
        case failure(String)
        case uncertain(String)
    }

    private(set) var process: Process?
    private var errorOutput = ProcessOutput()
    private var controlPath: String?
    private let executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        self.executableURL = executableURL
    }

    var isRunning: Bool { process?.isRunning == true }

    func start(target: String, onExit: @escaping (Int32, String) -> Void) throws {
        precondition(process == nil, "Await stop before replacing an SSH session.")
        let controlPath = "/tmp/dev.hegar.flamm.\(UUID().uuidString).sock"
        self.controlPath = controlPath
        let output = ProcessOutput()
        errorOutput = output
        let process = makeProcess(arguments: [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "ControlMaster=yes",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            target,
        ], output: output)
        process.terminationHandler = { process in
            Task { @MainActor in
                onExit(process.terminationStatus, output.text)
            }
        }
        try process.run()
        self.process = process
    }

    func installForward(_ port: ForwardedPort) async -> ForwardingResult {
        guard let controlPath else {
            return .failure("SSH control socket was not configured.")
        }
        for _ in 0..<70 {
            guard !Task.isCancelled else { return .cancelled }
            guard isRunning else {
                return .failure(errorOutput.text.isEmpty ? "SSH exited before connecting." : errorOutput.text)
            }
            if FileManager.default.fileExists(atPath: controlPath) {
                return await request(.forward, port: port)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .failure("Timed out waiting for the SSH connection.")
    }

    func cancelForward(_ port: ForwardedPort) async -> ForwardingResult {
        await request(.cancel, port: port)
    }

    // Used during application termination, when the main run loop can no longer await cleanup.
    func terminate() {
        process?.terminationHandler = nil
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if let controlPath { try? FileManager.default.removeItem(atPath: controlPath) }
    }

    func stop() async {
        if let process {
            process.terminationHandler = nil
            await Self.stopProcess(process)
        }
        self.process = nil
        if let controlPath { try? FileManager.default.removeItem(atPath: controlPath) }
        controlPath = nil
    }

    private func request(_ command: ControlCommand, port: ForwardedPort) async -> ForwardingResult {
        guard let controlPath, isRunning else {
            return .failure("SSH control socket is not available.")
        }
        guard !Task.isCancelled else { return .cancelled }
        let remoteHost = port.remoteHost.contains(":") ? "[\(port.remoteHost)]" : port.remoteHost
        let specification = "127.0.0.1:\(port.localPort):\(remoteHost):\(port.remotePort)"
        let output = ProcessOutput()
        let process = makeProcess(arguments: [
            "-F", "/dev/null", "-S", controlPath,
            "-O", command.rawValue, "-L", specification, "ft-control",
        ], output: output)
        do { try process.run() } catch { return .failure(error.localizedDescription) }

        // Once sent, finish the command even if settings change. The coordinator must know
        // whether a forward was installed before it can safely remove or replace it.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            await Self.pause()
        }
        if process.isRunning {
            await Self.stopProcess(process)
            return .uncertain("Timed out trying to \(command.rawValue) \(port.menuLabel).")
        }
        guard process.terminationStatus == 0 else {
            return .failure(output.text.isEmpty ? "Could not \(command.rawValue) \(port.menuLabel)." : output.text)
        }
        return .success
    }

    private func makeProcess(arguments: [String], output: ProcessOutput) -> Process {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                output.append(data)
            }
        }
        return process
    }

    private static func stopProcess(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { await pause() }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // Never let cancellation skip confirmed exit and release of the listening sockets.
        while process.isRunning { await pause() }
    }

    private static func pause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.02) {
                continuation.resume()
            }
        }
    }
}

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        data = Data(data.suffix(4_000))
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
