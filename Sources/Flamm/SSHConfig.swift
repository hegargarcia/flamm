import Foundation

struct SSHConfig {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func hosts() -> [String] {
        var visited = Set<URL>()
        let configURL = homeDirectory.appendingPathComponent(".ssh/config")
        return Array(Set(hosts(in: configURL, visited: &visited))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func effectiveForwards(for target: String) -> [ForwardedPort] {
        let process = Process()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", target]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }

        guard let contents = String(data: data, encoding: .utf8) else {
            return []
        }

        return Self.parseEffectiveForwards(contents)
    }

    static func parseHostPatterns(_ contents: String) -> [String] {
        contents.split(whereSeparator: \.isNewline).flatMap { rawLine -> [String] in
            let fields = fields(in: rawLine)
            guard fields.first?.lowercased() == "host" else {
                return []
            }

            return fields.dropFirst().filter { host in
                !host.hasPrefix("!") && !host.contains("*") && !host.contains("?")
            }
        }
    }

    static func parseEffectiveForwards(_ contents: String) -> [ForwardedPort] {
        contents.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, fields[0].lowercased() == "localforward" else {
                return nil
            }

            let localFields = fields[1].split(separator: ":")
            let localPortText = localFields.last.map(String.init) ?? fields[1]
            let remote = fields[2]
            guard
                let localPort = Int(localPortText),
                let separator = remote.lastIndex(of: ":"),
                let remotePort = Int(remote[remote.index(after: separator)...])
            else {
                return nil
            }

            var remoteHost = String(remote[..<separator])
            if remoteHost.hasPrefix("[") && remoteHost.hasSuffix("]") {
                remoteHost.removeFirst()
                remoteHost.removeLast()
            }

            return ForwardedPort(
                alias: "",
                localPort: localPort,
                remoteHost: remoteHost,
                remotePort: remotePort
            )
        }
    }

    private func hosts(in configURL: URL, visited: inout Set<URL>) -> [String] {
        let standardizedURL = configURL.standardizedFileURL
        guard !visited.contains(standardizedURL) else {
            return []
        }
        visited.insert(standardizedURL)

        guard let contents = try? String(contentsOf: standardizedURL, encoding: .utf8) else {
            return []
        }

        var foundHosts = Self.parseHostPatterns(contents)
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = Self.fields(in: line)
            guard fields.first?.lowercased() == "include" else {
                continue
            }

            for pattern in fields.dropFirst() {
                for includedURL in resolveInclude(pattern) {
                    foundHosts.append(contentsOf: hosts(in: includedURL, visited: &visited))
                }
            }
        }

        return foundHosts
    }

    private static func fields(in line: Substring) -> [String] {
        let uncommented = line.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0]
        return uncommented.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func resolveInclude(_ pattern: String) -> [URL] {
        let expandedPattern: String
        if pattern.hasPrefix("~/") {
            expandedPattern = homeDirectory.appendingPathComponent(String(pattern.dropFirst(2))).path
        } else if pattern.hasPrefix("/") {
            expandedPattern = pattern
        } else {
            expandedPattern = homeDirectory.appendingPathComponent(".ssh/\(pattern)").path
        }

        guard expandedPattern.contains("*") || expandedPattern.contains("?") else {
            return [URL(fileURLWithPath: expandedPattern)]
        }

        let patternURL = URL(fileURLWithPath: expandedPattern)
        let directory = patternURL.deletingLastPathComponent()
        let filenamePattern = patternURL.lastPathComponent
        guard let filenames = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        let regularExpression = "^" + NSRegularExpression.escapedPattern(for: filenamePattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        guard let regex = try? NSRegularExpression(pattern: regularExpression) else {
            return []
        }

        return filenames.compactMap { filename in
            let range = NSRange(filename.startIndex..., in: filename)
            guard regex.firstMatch(in: filename, range: range) != nil else {
                return nil
            }
            return directory.appendingPathComponent(filename)
        }
    }
}
