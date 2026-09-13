import Darwin
import Foundation
import XCTest
@testable import Porto

final class SSHHostCatalogTests: XCTestCase {
    func testDiscoversLiteralAliasesWithOpenSSHSyntaxIncludesAndDeterministicCasePolicy() throws {
        let home = try copyFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sshDirectory = home.appendingPathComponent(".ssh", isDirectory: true)
        let catalog = SSHHostCatalog(
            homeDirectory: home,
            environment: ["PORTO_SSH_INCLUDE": sshDirectory.path]
        )

        let result = catalog.load()

        XCTAssertEqual(
            result.hosts.map(\.alias),
            [
                "after-match", "alpha", "Bravo", "charlie", "continued-alias",
                "duplicate", "environment-expanded", "equals-form", "escaped alias", "escaped#hash",
                "Foo", "hash#alias", "nested-relative", "quoted alias", "tilde-expanded", "zeta"
            ]
        )
        XCTAssertFalse(result.hosts.map(\.alias).contains("must-not-appear"))
        XCTAssertFalse(result.hosts.map(\.alias).contains(where: { $0.contains("*") || $0.hasPrefix("!") }))
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(result.filesRead, 6)
        XCTAssertGreaterThan(result.bytesRead, 0)
        XCTAssertFalse(result.retainedPreviousCatalog)
    }

    func testHidesGitHubKeyButKeepsOrbStackLocalAliases() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = try makeSSHDirectory(in: home)
        let config = "Host github.com ORB production orb-stack\n"
        try Data(config.utf8).write(to: ssh.appendingPathComponent("config"))

        let result = SSHHostCatalog(homeDirectory: home, defaultUsername: "user").load()

        XCTAssertEqual(result.hosts.map(\.alias), ["ORB", "orb-stack", "production"])
        XCTAssertEqual(result.candidates.map(\.alias), ["ORB", "orb-stack", "production"])
    }

    func testExtractsSafeMetadataAndUsesDeterministicDefaults() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = try makeSSHDirectory(in: home)
        let config = """
        Host zeta alpha
            HostName host.example
            User alice
            Port 2200
            IdentityFile ~/.ssh/id_ed25519
        Host alpha
            HostName should-not-win.example
            User bob
        Host orb
            HostName %h
            User bad$user
            Port 0
            IdentityFile $HOME/id_rsa
        Host defaults
        Host unsafe
            HostName host;touch /tmp/x
            IdentityFile ~/.ssh/id_%h
        Match exec "false"
            HostName ignored.example
            User ignored
            Port 99
        Host after-match
        """
        try Data(config.utf8).write(to: ssh.appendingPathComponent("config"))

        let result = SSHHostCatalog(homeDirectory: home, defaultUsername: "local-user").load()

        XCTAssertEqual(result.candidates.map(\.alias), ["after-match", "alpha", "defaults", "orb", "unsafe", "zeta"])
        let byAlias = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.alias, $0) })
        XCTAssertEqual(byAlias["alpha"]?.host, "host.example")
        XCTAssertEqual(byAlias["alpha"]?.username, "alice")
        XCTAssertEqual(byAlias["alpha"]?.port, 2200)
        XCTAssertEqual(
            byAlias["alpha"]?.identityFilePath,
            home.appendingPathComponent(".ssh/id_ed25519").standardizedFileURL.path
        )
        XCTAssertEqual(byAlias["defaults"]?.host, "defaults")
        XCTAssertEqual(byAlias["defaults"]?.username, "local-user")
        XCTAssertEqual(byAlias["defaults"]?.port, 22)
        XCTAssertEqual(byAlias["orb"]?.host, "orb")
        XCTAssertEqual(byAlias["orb"]?.username, "local-user")
        XCTAssertNil(byAlias["orb"]?.identityFilePath)
        XCTAssertEqual(byAlias["unsafe"]?.host, "unsafe")
        XCTAssertEqual(byAlias["after-match"]?.username, "local-user")
        XCTAssertEqual(byAlias["alpha"]?.id, SSHHostCandidate(alias: "ALPHA", host: "x", username: "u").id)
        XCTAssertEqual(byAlias["alpha"]?.addressLabel, "host.example:2200")
        XCTAssertEqual(SSHHostCandidate(alias: "ipv6", host: "2001:db8::1", username: "u").addressLabel, "2001:db8::1")
    }

    func testInvalidFallbackUsernameDoesNotProduceCandidates() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = try makeSSHDirectory(in: home)
        try Data("Host defaults\n".utf8).write(to: ssh.appendingPathComponent("config"))

        let result = SSHHostCatalog(homeDirectory: home, defaultUsername: "bad user").load()

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.hosts.map(\.alias), ["defaults"])
    }

    func testOmitsAliasesThatCannotBecomeDirectProfiles() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = try makeSSHDirectory(in: home)
        let config = """
        Host \"needs manual\"
        Host valid
            HostName 192.168.1.20
        """
        try Data(config.utf8).write(to: ssh.appendingPathComponent("config"))

        let result = SSHHostCatalog(homeDirectory: home, defaultUsername: "user").load()

        XCTAssertEqual(result.hosts.map(\.alias), ["needs manual", "valid"])
        XCTAssertEqual(result.candidates.map(\.alias), ["valid"])
    }

    func testMissingRootIsAnIntentionalEmptyCatalogAndDoesNotRetainPrior() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let prior = [SSHHost(alias: "prior")]

        let result = SSHHostCatalog(homeDirectory: home).load(previous: prior)

        XCTAssertEqual(result.hosts, [])
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertFalse(result.retainedPreviousCatalog)
    }

    func testRootMustResolveToARegularFileButSymlinkedRootIsAllowed() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let config = ssh.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)

        let directoryResult = SSHHostCatalog(homeDirectory: home).load()
        XCTAssertEqual(directoryResult.hosts, [])
        XCTAssertEqual(directoryResult.diagnostics, [.rootIsNotRegularFile])

        try FileManager.default.removeItem(at: config)
        let actual = ssh.appendingPathComponent("actual-config")
        try Data("Host symlinked\n".utf8).write(to: actual)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: actual)

        let symlinkResult = SSHHostCatalog(homeDirectory: home).load()
        XCTAssertEqual(symlinkResult.hosts.map(\.alias), ["symlinked"])
        XCTAssertEqual(symlinkResult.diagnostics, [])
    }

    func testCanonicalCycleDetectionStopsRecursiveIncludes() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = try makeSSHDirectory(in: home)
        try Data("Host root\nInclude loop.conf\n".utf8).write(to: ssh.appendingPathComponent("config"))
        try FileManager.default.createSymbolicLink(
            at: ssh.appendingPathComponent("loop.conf"),
            withDestinationURL: ssh.appendingPathComponent("config")
        )

        let result = SSHHostCatalog(homeDirectory: home).load()

        XCTAssertEqual(result.hosts.map(\.alias), ["root"])
        XCTAssertEqual(result.filesRead, 1)
        XCTAssertEqual(result.diagnostics, [.includeCycleSkipped])
    }

    func testRelativeIncludesAlwaysResolveAgainstSSHDirectory() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = try makeSSHDirectory(in: home)
        let subdirectory = ssh.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try Data("Include sub/first.conf\n".utf8).write(to: ssh.appendingPathComponent("config"))
        try Data("Host first\nInclude root-relative.conf\n".utf8)
            .write(to: subdirectory.appendingPathComponent("first.conf"))
        try Data("Host correct\n".utf8).write(to: ssh.appendingPathComponent("root-relative.conf"))
        try Data("Host wrong\n".utf8).write(to: subdirectory.appendingPathComponent("root-relative.conf"))

        let result = SSHHostCatalog(homeDirectory: home).load()

        XCTAssertEqual(result.hosts.map(\.alias), ["correct", "first"])
    }

    func testRejectsUnsafeControlEmptyWildcardNegatedAndLeadingDashAliases() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = try makeSSHDirectory(in: home)
        let config = """
        Host safe -option !negative wildcard* question? [class] ""
        Host "control\u{0001}alias" nul\u{0000}alias
        Host "unterminated
        HOST MixedCase
        """
        try Data(config.utf8).write(to: ssh.appendingPathComponent("config"))

        let result = SSHHostCatalog(homeDirectory: home).load()

        XCTAssertEqual(result.hosts.map(\.alias), ["MixedCase", "safe"])
    }

    func testDepthFileAndAggregateByteLimitsAreEnforced() throws {
        let depthHome = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: depthHome) }
        let depthSSH = try makeSSHDirectory(in: depthHome)
        try Data("Host root\nInclude one\n".utf8).write(to: depthSSH.appendingPathComponent("config"))
        try Data("Host one\nInclude two\n".utf8).write(to: depthSSH.appendingPathComponent("one"))
        try Data("Host two\n".utf8).write(to: depthSSH.appendingPathComponent("two"))
        let depth = SSHHostCatalog(
            homeDirectory: depthHome,
            limits: .init(maximumDepth: 1, maximumFiles: 20, maximumBytes: 10_000)
        ).load()
        XCTAssertEqual(depth.hosts.map(\.alias), ["one", "root"])
        XCTAssertTrue(depth.diagnostics.contains(.depthLimitReached))

        let fileHome = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fileHome) }
        let fileSSH = try makeSSHDirectory(in: fileHome)
        try Data("Host root\nInclude one two\n".utf8).write(to: fileSSH.appendingPathComponent("config"))
        try Data("Host one\n".utf8).write(to: fileSSH.appendingPathComponent("one"))
        try Data("Host two\n".utf8).write(to: fileSSH.appendingPathComponent("two"))
        let files = SSHHostCatalog(
            homeDirectory: fileHome,
            limits: .init(maximumDepth: 10, maximumFiles: 2, maximumBytes: 10_000)
        ).load()
        XCTAssertEqual(files.hosts.map(\.alias), ["one", "root"])
        XCTAssertEqual(files.filesRead, 2)
        XCTAssertTrue(files.diagnostics.contains(.fileLimitReached))

        let byteHome = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: byteHome) }
        let byteSSH = try makeSSHDirectory(in: byteHome)
        try Data("Host root\nInclude large\n".utf8).write(to: byteSSH.appendingPathComponent("config"))
        try Data("Host should-not-fit\n".utf8).write(to: byteSSH.appendingPathComponent("large"))
        let bytes = SSHHostCatalog(
            homeDirectory: byteHome,
            limits: .init(maximumDepth: 10, maximumFiles: 20, maximumBytes: 30)
        ).load()
        XCTAssertEqual(bytes.hosts.map(\.alias), ["root"])
        XCTAssertTrue(bytes.diagnostics.contains(.byteLimitReached))
        XCTAssertLessThanOrEqual(bytes.bytesRead, 30)
    }

    func testUnreadableRootRetainsPriorWithoutExposingConfigurationDataInDiagnostics() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = try makeSSHDirectory(in: home)
        let config = ssh.appendingPathComponent("config")
        try Data("Host private-production-name\n".utf8).write(to: config)
        XCTAssertEqual(chmod(config.path, 0), 0)
        defer { _ = chmod(config.path, S_IRUSR | S_IWUSR) }

        let result = SSHHostCatalog(homeDirectory: home).load(previous: [
            SSHHost(alias: "prior"),
            SSHHost(alias: "ORB"),
            SSHHost(alias: "github.com")
        ])

        XCTAssertEqual(result.hosts.map(\.alias), ["prior", "ORB"])
        XCTAssertTrue(result.retainedPreviousCatalog)
        XCTAssertEqual(result.diagnostics, [.rootUnreadable])
        XCTAssertFalse(String(describing: result.diagnostics).contains("private-production-name"))
    }

    func testUnreadableIncludeIsSkippedWithContentFreeDiagnostic() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = try makeSSHDirectory(in: home)
        try Data("Host root\nInclude secret.conf\n".utf8).write(to: ssh.appendingPathComponent("config"))
        let included = ssh.appendingPathComponent("secret.conf")
        try Data("Host secret-alias\n".utf8).write(to: included)
        XCTAssertEqual(chmod(included.path, 0), 0)
        defer { _ = chmod(included.path, S_IRUSR | S_IWUSR) }

        let result = SSHHostCatalog(homeDirectory: home).load()

        XCTAssertEqual(result.hosts.map(\.alias), ["root"])
        XCTAssertEqual(result.diagnostics, [.includedFileUnreadable])
    }

    private func copyFixtureHome() throws -> URL {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SSHConfig", isDirectory: true)
        let destination = try temporaryDirectory()
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: fixture, to: destination)
        return destination
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Porto-SSHHostCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSSHDirectory(in home: URL) throws -> URL {
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        return ssh
    }
}
