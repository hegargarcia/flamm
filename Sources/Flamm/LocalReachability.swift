import Darwin
import Foundation
import Network

enum LocalPortAvailability {
    static func isAvailable(port: Int) -> Bool {
        guard (1...65_535).contains(port) else {
            return false
        }

        // On macOS a reusable loopback bind can shadow an existing wildcard listener.
        // Check both addresses so reuse never hides a live all-interface service.
        return canBind(port: port, address: inet_addr("127.0.0.1"))
            && canBind(port: port, address: INADDR_ANY)
    }

    private static func canBind(port: Int, address hostAddress: in_addr_t) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            return false
        }
        defer { close(socketDescriptor) }

        // Match SSH's listener reuse: closed listeners may still have established
        // channels or TIME_WAIT sockets. A live listener must still block this bind.
        var reuseAddress: Int32 = 1
        guard setsockopt(
            socketDescriptor, SOL_SOCKET, SO_REUSEADDR,
            &reuseAddress, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { return false }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: hostAddress)

        let result = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    socketDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }

        return result == 0
    }
}

enum LocalReachability {
    static func check(port: Int, timeout: TimeInterval = 0.8) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
            let completion = ReachabilityCompletion(continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(true, connection: connection)
                case .failed, .cancelled:
                    completion.finish(false, connection: connection)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                completion.finish(false, connection: connection)
            }
        }
    }
}

private final class ReachabilityCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<Bool, Never>
    private var didResume = false

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ reachable: Bool, connection: NWConnection) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else {
            return
        }

        didResume = true
        connection.cancel()
        continuation.resume(returning: reachable)
    }
}
