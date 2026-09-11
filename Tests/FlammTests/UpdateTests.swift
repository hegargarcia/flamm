import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func expectFailure(_ message: String, _ operation: () throws -> Void) {
    do {
        try operation()
        fatalError(message)
    } catch { }
}

private final class GitHubStub: URLProtocol {
    static var status = 200
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json", "GitHub API media type")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main
struct UpdateTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Flamm update ' $ test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        expect(ReleaseVersion("v1.10.0")! > ReleaseVersion("1.9.9")!, "Numeric ordering")
        expect(ReleaseVersion("1.1") == ReleaseVersion("1.1.0"), "Equivalent versions")
        for invalid in ["", "1..0", "1.0.0-beta", "1.2.3.4", "-1", "１", String(repeating: "9", count: 30)] {
            expect(ReleaseVersion(invalid) == nil, "Reject unsupported version \(invalid)")
        }
        let asset = GitHubRelease.Asset(name: "Flamm-v1.10.0-macOS-arm64.dmg", browser_download_url: URL(string: "https://github.com/hegargarcia/flamm/releases/download/v1.10.0/Flamm-v1.10.0-macOS-arm64.dmg")!, digest: "sha256:" + String(repeating: "a", count: 64))
        let release = GitHubRelease(tag_name: "v1.10.0", draft: false, prerelease: false, assets: [asset])
        let available = try release.update(after: "1.9.0", architecture: "arm64")
        expect(available?.version == "v1.10.0", "Select matching DMG")
        let same = try release.update(after: "1.10.0", architecture: "arm64")
        let older = try release.update(after: "2.0.0", architecture: "arm64")
        expect(same == nil && older == nil, "Never reinstall or downgrade")
        expectFailure("Missing architecture must fail") { _ = try release.update(after: "1", architecture: "x86_64") }
        for (url, digest) in [(asset.browser_download_url, nil), (URL(string: "https://example.com/update.dmg")!, asset.digest)] {
            let bad = GitHubRelease(tag_name: release.tag_name, draft: false, prerelease: false, assets: [.init(name: asset.name, browser_download_url: url, digest: digest)])
            expectFailure("Reject unverified release") { _ = try bad.update(after: "1", architecture: "arm64") }
        }
        let prerelease = GitHubRelease(tag_name: "v2.0.0", draft: false, prerelease: true, assets: [])
        let ignored = try prerelease.update(after: "1", architecture: "arm64")
        expect(ignored == nil, "Ignore prereleases")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        GitHubStub.status = 404
        let none = try await AppUpdate.check(currentVersion: "1", session: session)
        expect(none == nil, "No published releases")
        GitHubStub.status = 429
        do {
            _ = try await AppUpdate.check(currentVersion: "1", session: session)
            fatalError("Rate limit should fail")
        } catch { expect(error.localizedDescription.contains("limit"), "Explain rate limit") }
        GitHubStub.status = 200
        GitHubStub.body = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v1.10.0", "draft": false, "prerelease": false,
            "assets": [["name": "Flamm-v1.10.0-macOS-\(AppUpdate.architecture).dmg",
                        "browser_download_url": asset.browser_download_url.absoluteString,
                        "digest": asset.digest!]],
        ])
        let decoded = try await AppUpdate.check(currentVersion: "1.0.0", session: session)
        expect(decoded?.version == "v1.10.0", "Decode GitHub release response")
        GitHubStub.body = Data("invalid json".utf8)
        do {
            _ = try await AppUpdate.check(currentVersion: "1", session: session)
            fatalError("Malformed API response should fail")
        } catch { }

        let digestFile = root.appendingPathComponent("digest")
        try Data("abc".utf8).write(to: digestFile)
        try AppUpdate.verifyDigest(of: digestFile, expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        expectFailure("Corruption must fail") { try AppUpdate.verifyDigest(of: digestFile, expected: String(repeating: "0", count: 64)) }
        let destination = root.appendingPathComponent("Flamm.app")
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        try AppUpdate.validateDestination(destination)
        let linked = root.appendingPathComponent("Link.app")
        try fm.createSymbolicLink(at: linked, withDestinationURL: destination)
        expectFailure("Reject symlink destination") { try AppUpdate.validateDestination(linked) }
        expectFailure("Reject invalid app") { try AppUpdate.validateBundle(destination, version: "1.0.0") }

        try await testInstaller(root: root, failOpen: false)
        try await testInstaller(root: root, failOpen: true)
        try await testInstallerWait(root: root, removeStaged: false)
        try await testInstallerWait(root: root, removeStaged: true)
        let start = Date()
        do {
            try await UpdateCommand.run("/bin/sleep", ["20"], timeout: 0.1)
            fatalError("Command must time out")
        } catch { expect(Date().timeIntervalSince(start) < 3, "Bound subprocess wait") }

        if CommandLine.arguments.contains("--live-download") {
            guard let download = try await AppUpdate.check(currentVersion: "0.0.0") else { fatalError("Expected published release") }
            let prepared = try await AppUpdate.prepare(download, destination: destination)
            expect(fm.fileExists(atPath: prepared.stagedApp.appendingPathComponent("Contents/MacOS/Flamm").path), "Stage real release")
            prepared.cleanup()
            print("Live GitHub DMG download, digest, mount, bundle, signature, architecture, and staging passed")
        }
        print("Flamm update tests passed")
    }

    static func fixture(root: URL) throws -> (PreparedUpdate, URL) {
        let folder = root.appendingPathComponent(UUID().uuidString)
        let workspace = folder.appendingPathComponent("work")
        let destination = folder.appendingPathComponent("Flamm.app")
        let prepared = PreparedUpdate(workspace: workspace, destination: destination)
        for app in [destination, prepared.stagedApp] {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        }
        try "old".write(to: destination.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        try "new".write(to: prepared.stagedApp.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        try PreparedUpdate.installerScript.write(to: prepared.scriptURL, atomically: true, encoding: .utf8)
        return (prepared, folder)
    }

    static func testInstaller(root: URL, failOpen: Bool) async throws {
        let (prepared, folder) = try fixture(root: root)
        let opener = folder.appendingPathComponent("open-fixture")
        // On failure, reject the new app, then accept the restored old one.
        let script = "#!/bin/sh\n[ \"$(/bin/cat \"$1/version\")\" = \"\(failOpen ? "old" : "new")\" ]\n"
        try script.write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: opener.path)
        do {
            try await UpdateCommand.run("/bin/sh", [prepared.scriptURL.path, "2147483647", prepared.destination.path, prepared.workspace.path, opener.path, "/usr/bin/true"], timeout: 5)
            expect(!failOpen, "Failed relaunch must report failure")
        } catch { if !failOpen { throw error } }
        let installed = try String(contentsOf: prepared.destination.appendingPathComponent("version"), encoding: .utf8)
        expect(installed == (failOpen ? "old" : "new"), "Install or restore original")
        expect(!FileManager.default.fileExists(atPath: prepared.workspace.path), "Clean installer files")
    }

    static func testInstallerWait(root: URL, removeStaged: Bool) async throws {
        let (prepared, _) = try fixture(root: root)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["20"]
        try parent.run()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [prepared.scriptURL.path, String(parent.processIdentifier), prepared.destination.path, prepared.workspace.path, "/usr/bin/true", "/usr/bin/true"]
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        defer {
            if parent.isRunning { parent.terminate() }
            if helper.isRunning { helper.terminate() }
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: prepared.workspace.appendingPathComponent("ready").path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let before = try String(contentsOf: prepared.destination.appendingPathComponent("version"), encoding: .utf8)
        expect(before == "old", "Do not replace while the app runs")
        if removeStaged { try FileManager.default.removeItem(at: prepared.stagedApp) }
        parent.terminate()
        while helper.isRunning, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        expect(!helper.isRunning && (helper.terminationStatus == 0) == !removeStaged, "Installer finishes after parent exits")
        let after = try String(contentsOf: prepared.destination.appendingPathComponent("version"), encoding: .utf8)
        expect(after == (removeStaged ? "old" : "new"), "Replace or restore after a failed rename")
    }
}
