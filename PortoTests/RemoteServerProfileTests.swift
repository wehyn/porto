import Foundation
import XCTest
@testable import Porto

@MainActor
final class RemoteServerProfileTests: XCTestCase {
    func testSSHImportPlannerMapsOnlySelectedCandidatesAndDisablesProfiles() {
        let selected = SSHHostCandidate(alias: "work", host: "10.0.0.8", username: "deploy", port: 2200, identityFilePath: "/tmp/work.key")
        let ignored = SSHHostCandidate(alias: "ignored", host: "ignored.example", username: "user")

        let imported = SSHConnectionImportPlanner.profiles(
            from: [selected, ignored],
            selectedIDs: [selected.id],
            existingProfiles: []
        )

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.displayName, "work")
        XCTAssertEqual(imported.first?.host, "10.0.0.8")
        XCTAssertEqual(imported.first?.username, "deploy")
        XCTAssertEqual(imported.first?.port, 2200)
        XCTAssertEqual(imported.first?.identityFilePath, "/tmp/work.key")
        XCTAssertFalse(imported.first?.isEnabled ?? true)
    }

    func testSSHImportPlannerFiltersExistingAndRepeatedNamesCaseInsensitively() {
        let existing = RemoteServerProfile(displayName: "Production", host: "old", username: "user")
        let duplicate = SSHHostCandidate(alias: "production", host: "new", username: "user")
        let unique = SSHHostCandidate(alias: "Staging", host: "staging", username: "user")

        let imported = SSHConnectionImportPlanner.profiles(
            from: [duplicate, unique, SSHHostCandidate(alias: "STAGING", host: "other", username: "user")],
            selectedIDs: [duplicate.id, unique.id, "ssh:staging"],
            existingProfiles: [existing]
        )

        XCTAssertEqual(imported.map(\.displayName), ["Staging"])
    }

    func testSSHImportPlannerUsesStableCandidateIDForSelection() {
        let candidate = SSHHostCandidate(alias: "Dev", host: "dev", username: "user")
        let reconstructed = SSHHostCandidate(alias: "Dev", host: "different", username: "other")

        XCTAssertEqual(candidate.id, reconstructed.id)
        XCTAssertEqual(
            SSHConnectionImportPlanner.profiles(from: [reconstructed], selectedIDs: [candidate.id], existingProfiles: []).count,
            1
        )
    }

    func testDefaultsAndInjectedID() {
        let id = UUID()
        let profile = RemoteServerProfile(id: id, displayName: "Dev", host: "dev.example", username: "wayne")
        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.port, 22)
        XCTAssertFalse(profile.isEnabled)
    }

    func testValidationRejectsUnsafeValuesAndPortBounds() {
        let base = RemoteServerProfile(displayName: "Dev", host: "host", username: "user")
        for invalid in ["-host", "host name", "user@host", "host;rm -rf", "host\0x", "host\n", "[]", "example..com", "256.1.1.1", "2001:db8::1::2"] {
            var profile = base
            profile.host = invalid
            XCTAssertThrowsError(try profile.validate()) { error in
                XCTAssertEqual(error as? RemoteServerProfileValidationError, .invalidHost)
            }
        }
        for invalid in ["-user", "", "user name", "user@host", "user:name", "user\0x", "user\n", "user/name", "1user"] {
            var invalidUsername = base
            invalidUsername.username = invalid
            XCTAssertThrowsError(try invalidUsername.validate()) { error in
                XCTAssertEqual(error as? RemoteServerProfileValidationError, .invalidUsername)
            }
        }
        for port in [0, 65_536] {
            var profile = base
            profile.port = port
            XCTAssertThrowsError(try profile.validate())
        }
    }

    func testValidationAcceptsHostnameAndIPv4AndIPv6HostForms() {
        for host in [
            "host", "dev.example", "dev-1.example.com", "192.168.1.20",
            "::1", "2001:db8::10", "[::1]", "fe80::1%en0", "[fe80::1%en0]"
        ] {
            let profile = RemoteServerProfile(displayName: "Dev", host: host, username: "user")
            XCTAssertNoThrow(try profile.validate(), "Expected valid host: \(host)")
        }
    }

    func testValidationAcceptsConventionalUsernameTokens() {
        for username in ["user", "deploy-user", "user.name", "_service", "user_2"] {
            let profile = RemoteServerProfile(displayName: "Dev", host: "host", username: username)
            XCTAssertNoThrow(try profile.validate(), "Expected valid username: \(username)")
        }
    }

    func testDuplicateNamesAreCaseInsensitiveAndEditingOwnProfileIsAllowed() throws {
        let first = RemoteServerProfile(displayName: "Production", host: "one", username: "user")
        var edited = first
        edited.displayName = "production"
        XCTAssertNoThrow(try edited.validate(against: [first]))
        let other = RemoteServerProfile(displayName: "production", host: "two", username: "user")
        XCTAssertThrowsError(try other.validate(against: [first])) { error in
            XCTAssertEqual(error as? RemoteServerProfileValidationError, .duplicateDisplayName)
        }
    }

    func testUserDefaultsPersistenceOrderingDeletionAndIsolation() throws {
        let suiteName = "RemoteServerProfileTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsRemoteServerProfileStore(suite: suite, key: "profiles")
        let bravo = RemoteServerProfile(displayName: "bravo", host: "b", username: "u")
        let alpha = RemoteServerProfile(displayName: "Alpha", host: "a", username: "u")
        try store.save(bravo)
        try store.save(alpha)
        XCTAssertEqual(store.profiles.map(\.displayName), ["Alpha", "bravo"])
        let reloaded = UserDefaultsRemoteServerProfileStore(suite: suite, key: "profiles")
        XCTAssertEqual(reloaded.profiles, store.profiles)
        reloaded.delete(id: alpha.id)
        XCTAssertEqual(reloaded.profiles, [bravo])
        let isolated = UserDefaultsRemoteServerProfileStore(suite: suite, key: "other")
        XCTAssertTrue(isolated.profiles.isEmpty)
    }

    func testFailedReplacementPreservesPriorProfiles() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "RemoteServerProfileTests.\(UUID().uuidString)"))
        let store = UserDefaultsRemoteServerProfileStore(suite: suite, key: "profiles")
        let original = RemoteServerProfile(displayName: "Original", host: "host", username: "user")
        try store.save(original)
        var invalid = original
        invalid.host = "host; exit"
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(store.profiles, [original])
    }
}
