import Darwin
import Foundation

@main
struct SelfTest {
    static func main() {
        let config = """
        Host *
          ServerAliveInterval 30
        Host dev-box staging !blocked *.internal # only concrete aliases are shown
          User developer
        Match originalhost dev-box
          HostName dev-box.local
        """
        precondition(SSHConfig.parseHostPatterns(config) == ["dev-box", "staging"])

        let effectiveConfig = """
        host dev-box
        localforward 1355 [127.0.0.1]:1355
        localforward 8080 [::1]:3000
        """
        let ports = SSHConfig.parseEffectiveForwards(effectiveConfig)
        precondition(ports.count == 2)
        precondition(ports[0].alias.isEmpty)
        precondition(ports[0].localPort == 1355)
        precondition(ports[0].remoteHost == "127.0.0.1")
        precondition(ports[0].remotePort == 1355)
        precondition(ports[0].portMapping == "1355")
        precondition(ports[1].remoteHost == "::1")
        precondition(ports[1].remotePort == 3000)
        precondition(ports[1].portMapping == "8080:3000")

        let duplicatePorts = [
            ForwardedPort(alias: "Web", localPort: 4000, remotePort: 4000),
            ForwardedPort(alias: "API", localPort: 4000, remotePort: 4001),
        ]
        precondition(
            PortValidation.message(for: duplicatePorts)
                == "Enabled proxies cannot share a local port."
        )

        var oneDisabled = duplicatePorts
        oneDisabled[1].isEnabled = false
        precondition(PortValidation.message(for: oneDisabled) == nil)

        let occupiedPort = makeOccupiedLoopbackPort()
        precondition(!LocalPortAvailability.isAvailable(port: occupiedPort.port))
        close(occupiedPort.socketDescriptor)
        precondition(LocalPortAvailability.isAvailable(port: occupiedPort.port))

        print("Flamm self-tests passed")
    }

    private static func makeOccupiedLoopbackPort() -> (socketDescriptor: Int32, port: Int) {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        precondition(socketDescriptor >= 0)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    socketDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        precondition(bindResult == 0)
        precondition(listen(socketDescriptor, 1) == 0)

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(socketDescriptor, socketAddress, &addressLength)
            }
        }
        precondition(nameResult == 0)

        return (socketDescriptor, Int(UInt16(bigEndian: address.sin_port)))
    }
}
