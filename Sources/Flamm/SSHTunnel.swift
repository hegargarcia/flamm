import Foundation

@MainActor
final class SSHTunnel {
    private enum ControlCommand: String {
        case forward
        case cancel
    }

    enum ForwardingResult {
        case success
        case failure(String)
    }

    private(set) var process: Process?
    private var errorOutput = ""
    private var controlPath: String?

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start(
        target: String,
        onExit: @escaping (Int32, String) -> Void
    ) throws {
        stop()
        errorOutput = ""

        let controlPath = "/tmp/dev.hegar.flamm.\(UUID().uuidString).sock"
        self.controlPath = controlPath

        let process = Process()
        let errorPipe = Pipe()
        let arguments = [
            "-N",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=yes",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            target,
        ]

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
                return
            }

            Task { @MainActor in
                self?.errorOutput = String((self?.errorOutput ?? "") + chunk).suffix(4_000).description
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                errorPipe.fileHandleForReading.readabilityHandler = nil
                onExit(process.terminationStatus, self?.errorOutput ?? "")
            }
        }

        try process.run()
        self.process = process
    }

    func installForwards(_ ports: [ForwardedPort]) async -> ForwardingResult {
        let ready = await waitUntilReady()
        if case .failure = ready {
            return ready
        }

        for port in ports where port.isEnabled {
            let result = request(.forward, port: port)
            if case .failure = result {
                return result
            }
        }

        return .success
    }

    func installForward(_ port: ForwardedPort) async -> ForwardingResult {
        let ready = await waitUntilReady()
        if case .failure = ready {
            return ready
        }
        return request(.forward, port: port)
    }

    func cancelForward(_ port: ForwardedPort) -> ForwardingResult {
        request(.cancel, port: port)
    }

    func stop() {
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }

        self.process = nil
        if let controlPath {
            try? FileManager.default.removeItem(atPath: controlPath)
        }
        self.controlPath = nil
    }

    private func waitUntilReady() async -> ForwardingResult {
        guard let controlPath else {
            return .failure("SSH control socket was not configured.")
        }

        for _ in 0..<120 {
            if FileManager.default.fileExists(atPath: controlPath) {
                return .success
            }

            guard isRunning else {
                let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(message.isEmpty ? "SSH exited before connecting." : message)
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return .failure("Timed out waiting for the SSH connection.")
    }

    private func request(_ command: ControlCommand, port: ForwardedPort) -> ForwardingResult {
        guard let controlPath else {
            return .failure("SSH control socket is not available.")
        }

        let remoteHost = port.remoteHost.contains(":")
            ? "[\(port.remoteHost)]"
            : port.remoteHost
        let specification = "127.0.0.1:\(port.localPort):\(remoteHost):\(port.remotePort)"
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-F", "/dev/null",
            "-S", controlPath,
            "-O", command.rawValue,
            "-L", specification,
            "ft-control",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty {
                return .failure(message)
            }
            return .failure("Could not \(command.rawValue) \(port.menuLabel).")
        }

        return .success
    }
}
