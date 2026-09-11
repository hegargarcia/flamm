import CryptoKit
import Darwin
import Foundation

struct UpdateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

// Releases use stable numeric versions, optionally prefixed with "v".
struct ReleaseVersion: Comparable {
    let components: [Int]

    init?(_ string: String) {
        let value = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    func update(after current: String, architecture: String) throws -> UpdateDownload? {
        guard !draft, !prerelease else { return nil }
        guard let installed = ReleaseVersion(current), let latest = ReleaseVersion(tag_name) else {
            throw UpdateError("The installed or release version is not a supported numeric version.")
        }
        guard latest > installed else { return nil }
        let name = "Flamm-\(tag_name)-macOS-\(architecture).dmg"
        guard let asset = assets.first(where: { $0.name == name }) else {
            throw UpdateError("Release \(tag_name) has no DMG for this Mac (\(architecture)).")
        }
        guard asset.browser_download_url.scheme == "https",
              asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path.hasPrefix("/hegargarcia/flamm/releases/download/") else {
            throw UpdateError("The release contains an unexpected download address.")
        }
        guard let digest = asset.digest, digest.hasPrefix("sha256:"),
              digest.dropFirst(7).count == 64,
              digest.dropFirst(7).allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw UpdateError("The release does not include a valid SHA-256 digest. Download it from GitHub manually.")
        }
        return UpdateDownload(version: tag_name, url: asset.browser_download_url, sha256: String(digest.dropFirst(7)).lowercased())
    }
}

struct UpdateDownload {
    let version: String
    let url: URL
    let sha256: String
}

enum AppUpdate {
    static let releasesURL = URL(string: "https://github.com/hegargarcia/flamm/releases/latest")!
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func check(currentVersion: String, session: URLSession = .shared) async throws -> UpdateDownload? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/hegargarcia/flamm/releases/latest")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Flamm/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError("GitHub returned an invalid response.") }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else {
            throw UpdateError(http.statusCode == 403 || http.statusCode == 429
                ? "GitHub's request limit was reached. Please try again later."
                : "GitHub could not check for updates (HTTP \(http.statusCode)).")
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data).update(after: currentVersion, architecture: architecture)
    }

    static func validateDestination(_ app: URL) throws {
        let values = try app.resourceValues(forKeys: [.isSymbolicLinkKey, .volumeIsReadOnlyKey])
        guard app.pathExtension == "app", values.isSymbolicLink != true,
              values.volumeIsReadOnly != true, !app.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: app.path) else {
            throw UpdateError("Move Flamm to a writable Applications folder, such as ~/Applications, then reopen it and try again.")
        }
    }

    // Stage on the destination volume so replacement is a rename, never an in-place copy.
    static func prepare(_ download: UpdateDownload, destination: URL) async throws -> PreparedUpdate {
        try validateDestination(destination)
        let fm = FileManager.default
        let workspace = destination.deletingLastPathComponent().appendingPathComponent(".Flamm-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let mount = workspace.appendingPathComponent("mount", isDirectory: true)
        let prepared = PreparedUpdate(workspace: workspace, destination: destination)
        do {
            var request = URLRequest(url: download.url)
            request.timeoutInterval = 120
            let (temporary, response) = try await URLSession.shared.download(for: request)
            defer { try? fm.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("The update download failed. Please try again.")
            }
            let diskImage = workspace.appendingPathComponent("update.dmg")
            try fm.moveItem(at: temporary, to: diskImage)
            try verifyDigest(of: diskImage, expected: download.sha256)
            try fm.createDirectory(at: mount, withIntermediateDirectories: false)
            try await UpdateCommand.run("/usr/bin/hdiutil", ["attach", diskImage.path, "-mountpoint", mount.path, "-nobrowse", "-readonly", "-noautoopen"], timeout: 60)
            let source = mount.appendingPathComponent("Flamm.app")
            try validateBundle(source, version: download.version)
            try await UpdateCommand.run("/usr/bin/ditto", [source.path, prepared.stagedApp.path], timeout: 120)
            try await UpdateCommand.run("/usr/bin/hdiutil", ["detach", mount.path], timeout: 30)
            try await UpdateCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", prepared.stagedApp.path], timeout: 30)
            try fm.removeItem(at: diskImage)
            try PreparedUpdate.installerScript.write(to: prepared.scriptURL, atomically: true, encoding: .utf8)
            return prepared
        } catch {
            // Also attempt detach if attach timed out after mounting the image.
            try? await UpdateCommand.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 15)
            prepared.cleanup()
            throw error
        }
    }

    static func verifyDigest(of file: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError("The downloaded DMG failed its SHA-256 check. Your installed app has not been changed.") }
    }

    static func validateBundle(_ app: URL, version: String) throws {
        let values = try app.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true, let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "dev.hegar.flamm",
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Flamm",
              let actual = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let actualVersion = ReleaseVersion(actual), actualVersion == ReleaseVersion(version) else {
            throw UpdateError("The DMG does not contain the expected version of Flamm.")
        }
        let cpuType = architecture == "arm64" ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64
        guard bundle.executableArchitectures?.contains(NSNumber(value: cpuType)) == true else {
            throw UpdateError("The release does not contain an executable compatible with this Mac.")
        }
        if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard let required = ReleaseVersion(minimum), let current = ReleaseVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"), current >= required else {
                throw UpdateError("This release requires macOS \(minimum) or newer.")
            }
        }
    }
}

// Commands drain output to a file and poll asynchronously with a deadline, keeping the menu responsive.
enum UpdateCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Flamm-command-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            // Reap the child before its files or mount point can be removed.
            while process.isRunning { try? await Task.sleep(nanoseconds: 10_000_000) }
            throw UpdateError("\(URL(fileURLWithPath: executable).lastPathComponent) timed out or was cancelled.")
        }
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            throw UpdateError("\(URL(fileURLWithPath: executable).lastPathComponent) failed. \(detail.prefix(1500))")
        }
    }
}

struct PreparedUpdate {
    let workspace: URL
    let destination: URL
    var stagedApp: URL { workspace.appendingPathComponent("Flamm.app") }
    var scriptURL: URL { workspace.appendingPathComponent("install.sh") }

    func cleanup() { try? FileManager.default.removeItem(at: workspace) }

    func launchInstaller() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), destination.path, workspace.path, "/usr/bin/open", "/usr/bin/osascript"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let ready = workspace.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            if FileManager.default.fileExists(atPath: ready.path) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        throw UpdateError("The update installer could not start. Please try again.")
    }

    // Pass paths as arguments: neither release metadata nor installation paths become shell code.
    // Keep a backup until Launch Services accepts the new app; restore it on a failed install/open.
    static let installerScript = #"""
    #!/bin/sh
    set -eu
    parent_pid="$1"
    destination="$2"
    workspace="$3"
    opener="$4"
    notifier="$5"
    staged="$workspace/Flamm.app"
    backup="$workspace/Previous.app"
    committed=0
    cleanup() {
        result=$?
        trap - EXIT
        if [ "$committed" -eq 0 ] && [ -d "$backup" ]; then
            if [ -e "$destination" ]; then /bin/mv "$destination" "$workspace/Failed.app" || exit 1; fi
            /bin/mv "$backup" "$destination" || exit 1
            "$opener" "$destination" || true
        fi
        if [ "$result" -ne 0 ]; then
            "$notifier" -e 'display alert "Flamm update failed" message "The update could not finish. Reopen Flamm and try again, or download it from GitHub Releases." as critical' >/dev/null 2>&1 || true
        fi
        /bin/rm -rf "$workspace"
        exit "$result"
    }
    trap cleanup EXIT
    [ -d "$staged" ] && [ -d "$destination" ]
    /usr/bin/touch "$workspace/ready"
    attempts=0
    while /bin/kill -0 "$parent_pid" 2>/dev/null; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 300 ] || exit 1
        /bin/sleep 0.1
    done
    /bin/mv "$destination" "$backup"
    /bin/mv "$staged" "$destination"
    "$opener" "$destination"
    committed=1
    """#
}
