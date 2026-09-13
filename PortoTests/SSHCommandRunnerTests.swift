import Darwin
import Foundation
import XCTest
@testable import Porto

final class SSHCommandRunnerTests: XCTestCase {
    func testExactExecutableArgumentsAndEnvironment() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let runner = SSHCommandRunner(
            executableURL: fixture,
            environment: [
                "LC_ALL": "not-C",
                "SSH_AUTH_SOCK": "/tmp/porto-test-agent.sock",
                "PORTO_RUNNER_TEST": "capture"
            ]
        )

        let targetProfile = profile(host: "prod.example", username: "remote-user")
        let result = await runner.run(profile: targetProfile, operation: .scan)

        XCTAssertEqual(SSHCommandRunner.executableURL.path, "/usr/bin/ssh")
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.terminationReason, .exit)
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "fixture warning\n")
        XCTAssertEqual(
            String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init),
            ["LC_ALL=C", "SSH_AUTH_SOCK=/tmp/porto-test-agent.sock"]
                + expectedArguments(profile: targetProfile).map { "ARG=\($0)" }
        )
    }

    func testSuccessPreservesBoundedStderr() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let runner = SSHCommandRunner(
            executableURL: fixture,
            environment: ["PORTO_RUNNER_TEST": "success"]
        )

        let result = await runner.run(profile: profile(), operation: .scan)

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.stdout, Data("socket output\n".utf8))
        XCTAssertEqual(result.stderr, Data("diagnostic output\n".utf8))
        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testConcurrentRunIsBusyAndDoesNotTakeOverActiveSlot() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let runner = SSHCommandRunner(executableURL: fixture, timeout: .seconds(2))
        let slowProfile = profile(host: "slow")
        let firstTask = Task { await runner.run(profile: slowProfile, operation: .scan) }
        try await Task.sleep(for: .milliseconds(50))

        let secondResult = await runner.run(profile: profile(), operation: .scan)
        firstTask.cancel()
        let firstResult = await firstTask.value

        XCTAssertEqual(secondResult.failure, .busy)
        XCTAssertEqual(firstResult.failure, .cancelled)
        let followUp = await runner.run(profile: profile(), operation: .scan)
        XCTAssertNil(followUp.failure)
    }

    func testTimeoutTerminatesChildAndReleasesSlotAfterCleanup() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        // Keep enough headroom for the follow-up launch under a loaded test
        // host while still exercising the timeout cleanup path with sleep 10.
        let runner = SSHCommandRunner(executableURL: fixture, timeout: .milliseconds(500))

        let slowProfile = profile(host: "slow")
        let result = await runner.run(profile: slowProfile, operation: .scan)
        let followUp = await runner.run(profile: profile(), operation: .scan)

        XCTAssertEqual(result.failure, .timedOut)
        XCTAssertEqual(result.terminationReason, .signal)
        XCTAssertNil(followUp.failure)
    }

    func testTaskCancellationTerminatesChildAndReleasesSlot() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let runner = SSHCommandRunner(executableURL: fixture, timeout: .seconds(2))
        let slowProfile = profile(host: "slow")
        let task = Task { await runner.run(profile: slowProfile, operation: .scan) }
        try await Task.sleep(for: .milliseconds(50))

        task.cancel()
        let result = await task.value
        let followUp = await runner.run(profile: profile(), operation: .scan)

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertNil(followUp.failure)
    }

    func testExplicitCancellationAwaitsCleanupAndSlotRelease() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let runner = SSHCommandRunner(executableURL: fixture, timeout: .seconds(2))
        let slowProfile = profile(host: "slow")
        let task = Task { await runner.run(profile: slowProfile, operation: .scan) }
        try await Task.sleep(for: .milliseconds(50))

        await runner.cancelActive()
        let followUp = await runner.run(profile: profile(), operation: .scan)
        let result = await task.value

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertNil(followUp.failure)
    }

    func testStdoutAndStderrOverflowAreReportedSeparately() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let stdoutRunner = SSHCommandRunner(
            executableURL: fixture,
            stdoutLimit: 1_024,
            stderrLimit: 1_024,
            timeout: .seconds(2)
        )
        let stderrRunner = SSHCommandRunner(
            executableURL: fixture,
            stdoutLimit: 1_024,
            stderrLimit: 1_024,
            timeout: .seconds(2)
        )

        let stdoutResult = await stdoutRunner.run(profile: profile(host: "overflow-stdout"), operation: .scan)
        let stderrResult = await stderrRunner.run(profile: profile(host: "overflow-stderr"), operation: .scan)

        XCTAssertEqual(stdoutResult.failure, .outputTooLarge(stream: .stdout))
        XCTAssertLessThanOrEqual(stdoutResult.stdout.count, 1_024)
        XCTAssertEqual(stderrResult.failure, .outputTooLarge(stream: .stderr))
        XCTAssertLessThanOrEqual(stderrResult.stderr.count, 1_024)
    }

    func testLaunchFailureAndInvalidProfilesDoNotStartAChild() async {
        let runner = SSHCommandRunner(
            executableURL: URL(fileURLWithPath: "/definitely/not-a-porto-executable")
        )

        let launchFailure = await runner.run(profile: profile(), operation: .scan)
        var leadingDashProfile = profile()
        leadingDashProfile.host = "-oProxyCommand=bad"
        var controlCharacterProfile = profile()
        controlCharacterProfile.host = "bad\nhost"
        var emptyProfile = profile()
        emptyProfile.host = ""
        let leadingDash = await runner.run(profile: leadingDashProfile, operation: .scan)
        let controlCharacter = await runner.run(profile: controlCharacterProfile, operation: .scan)
        let empty = await runner.run(profile: emptyProfile, operation: .scan)

        XCTAssertEqual(launchFailure.failure, .launchFailed)
        XCTAssertEqual(leadingDash.failure, .invalidProfile)
        XCTAssertEqual(controlCharacter.failure, .invalidProfile)
        XCTAssertEqual(empty.failure, .invalidProfile)
    }

    func testCustomPortAndIdentityPathRemainSeparateArgumentsWithoutReadingKey() throws {
        let targetProfile = profile(host: "[2001:db8::10]", username: "remote-user", port: 2200, identityFilePath: "/tmp/key with spaces")

        let arguments = SSHCommandRunner.arguments(for: targetProfile, operation: .scan)

        XCTAssertEqual(arguments, expectedArguments(profile: targetProfile, hostArgument: "2001:db8::10"))
        XCTAssertEqual(targetProfile.host, "[2001:db8::10]")
        let separatorIndex = try XCTUnwrap(arguments?.firstIndex(of: "--"))
        XCTAssertEqual(arguments?[separatorIndex], "--")
        XCTAssertEqual(arguments?[separatorIndex + 1], "2001:db8::10")
        XCTAssertFalse(arguments?.contains { $0.contains("PRIVATE") || $0.contains("BEGIN") } ?? true)
    }

    func testSignalCommandsAreExactAndContainerIDsAreValidated() throws {
        let targetProfile = profile()
        XCTAssertEqual(
            SSHCommandRunner.arguments(for: targetProfile, operation: .signal(.term, pid: 42))?.last,
            "/bin/kill -TERM -- 42"
        )
        XCTAssertEqual(
            SSHCommandRunner.arguments(for: targetProfile, operation: .signal(.kill, pid: 42))?.last,
            "/bin/kill -KILL -- 42"
        )
        let id = "0123456789abcdef"
        XCTAssertEqual(
            SSHCommandRunner.arguments(for: targetProfile, operation: .signalContainer(.term, containerID: id))?.last,
            "docker kill --signal TERM -- \(id)"
        )
        XCTAssertEqual(
            SSHCommandRunner.arguments(for: targetProfile, operation: .signalContainer(.kill, containerID: id))?.last,
            "docker kill --signal KILL -- \(id)"
        )
        XCTAssertNil(SSHCommandRunner.arguments(for: targetProfile, operation: .signalContainer(.term, containerID: "0123456789AB")))
        XCTAssertNil(SSHCommandRunner.arguments(for: targetProfile, operation: .signalContainer(.term, containerID: "short")))
    }

    private func expectedArguments(profile: RemoteServerProfile, hostArgument: String? = nil) -> [String] {
        var arguments = [
            "-T",
            "-n",
            "-F", "/dev/null",
            "-l", profile.username,
            "-p", String(profile.port)
        ]
        if let identityFilePath = profile.identityFilePath {
            arguments += ["-i", identityFilePath]
        }
        arguments += [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "ConnectionAttempts=1",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "PreferredAuthentications=publickey",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "PermitLocalCommand=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "RequestTTY=no",
            "-o", "RemoteCommand=none",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "--",
            hostArgument ?? profile.host,
            SSHCommandRunner.remoteCommand
        ]
        return arguments
    }

    private func profile(
        host: String = "host",
        username: String = "user",
        port: Int = 22,
        identityFilePath: String? = nil
    ) -> RemoteServerProfile {
        RemoteServerProfile(
            displayName: "Test",
            host: host,
            username: username,
            port: port,
            identityFilePath: identityFilePath,
            isEnabled: true
        )
    }

    private func makeFixtureExecutable() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("porto-ssh-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("ssh-fixture")
        let script = #"""
        #!/bin/sh
        previous=''
        penultimate=''
        for value in "$@"; do
            penultimate="$previous"
            previous="$value"
        done
        alias="$penultimate"
        if [ "$alias" = "slow" ]; then
            exec /bin/sleep 10
        fi
        if [ "$alias" = "overflow-stdout" ]; then
            while :; do printf '0123456789abcdef0123456789abcdef\n'; done
        fi
        if [ "$alias" = "overflow-stderr" ]; then
            while :; do printf '0123456789abcdef0123456789abcdef\n' >&2; done
        fi
        if [ "${PORTO_RUNNER_TEST-}" = "capture" ]; then
            printf 'LC_ALL=%s\n' "$LC_ALL"
            printf 'SSH_AUTH_SOCK=%s\n' "${SSH_AUTH_SOCK-unset}"
            for value in "$@"; do printf 'ARG=%s\n' "$value"; done
            printf 'fixture warning\n' >&2
            exit 0
        fi
        printf 'socket output\n'
        printf 'diagnostic output\n' >&2
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        guard chmod(executable.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return executable
    }
}
