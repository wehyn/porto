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

        let result = await runner.run(alias: "Production Linux")

        XCTAssertEqual(SSHCommandRunner.executableURL.path, "/usr/bin/ssh")
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.terminationReason, .exit)
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "fixture warning\n")
        XCTAssertEqual(
            String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init),
            ["LC_ALL=C", "SSH_AUTH_SOCK=/tmp/porto-test-agent.sock"]
                + expectedArguments(alias: "Production Linux").map { "ARG=\($0)" }
        )
    }

    func testSuccessPreservesBoundedStderr() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let runner = SSHCommandRunner(
            executableURL: fixture,
            environment: ["PORTO_RUNNER_TEST": "success"]
        )

        let result = await runner.run(alias: "host")

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.stdout, Data("socket output\n".utf8))
        XCTAssertEqual(result.stderr, Data("diagnostic output\n".utf8))
        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testConcurrentRunIsBusyAndDoesNotTakeOverActiveSlot() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let runner = SSHCommandRunner(executableURL: fixture, timeout: .seconds(2))
        let firstTask = Task { await runner.run(alias: "slow") }
        try await Task.sleep(for: .milliseconds(50))

        let secondResult = await runner.run(alias: "host")
        firstTask.cancel()
        let firstResult = await firstTask.value

        XCTAssertEqual(secondResult.failure, .busy)
        XCTAssertEqual(firstResult.failure, .cancelled)
        let followUp = await runner.run(alias: "host")
        XCTAssertNil(followUp.failure)
    }

    func testTimeoutTerminatesChildAndReleasesSlotAfterCleanup() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        // Keep enough headroom for the follow-up launch under a loaded test
        // host while still exercising the timeout cleanup path with sleep 10.
        let runner = SSHCommandRunner(executableURL: fixture, timeout: .milliseconds(500))

        let result = await runner.run(alias: "slow")
        let followUp = await runner.run(alias: "host")

        XCTAssertEqual(result.failure, .timedOut)
        XCTAssertEqual(result.terminationReason, .signal)
        XCTAssertNil(followUp.failure)
    }

    func testTaskCancellationTerminatesChildAndReleasesSlot() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let runner = SSHCommandRunner(executableURL: fixture, timeout: .seconds(2))
        let task = Task { await runner.run(alias: "slow") }
        try await Task.sleep(for: .milliseconds(50))

        task.cancel()
        let result = await task.value
        let followUp = await runner.run(alias: "host")

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertNil(followUp.failure)
    }

    func testExplicitCancellationAwaitsCleanupAndSlotRelease() async throws {
        let fixture = try makeFixtureExecutable()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let runner = SSHCommandRunner(executableURL: fixture, timeout: .seconds(2))
        let task = Task { await runner.run(alias: "slow") }
        try await Task.sleep(for: .milliseconds(50))

        await runner.cancelActive()
        let followUp = await runner.run(alias: "host")
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

        let stdoutResult = await stdoutRunner.run(alias: "overflow-stdout")
        let stderrResult = await stderrRunner.run(alias: "overflow-stderr")

        XCTAssertEqual(stdoutResult.failure, .outputTooLarge(stream: .stdout))
        XCTAssertLessThanOrEqual(stdoutResult.stdout.count, 1_024)
        XCTAssertEqual(stderrResult.failure, .outputTooLarge(stream: .stderr))
        XCTAssertLessThanOrEqual(stderrResult.stderr.count, 1_024)
    }

    func testLaunchFailureAndInvalidAliasesDoNotStartAChild() async {
        let runner = SSHCommandRunner(
            executableURL: URL(fileURLWithPath: "/definitely/not-a-porto-executable")
        )

        let launchFailure = await runner.run(alias: "host")
        let leadingDash = await runner.run(alias: "-oProxyCommand=bad")
        let controlCharacter = await runner.run(alias: "bad\nhost")
        let empty = await runner.run(alias: "")

        XCTAssertEqual(launchFailure.failure, .launchFailed)
        XCTAssertEqual(leadingDash.failure, .invalidAlias)
        XCTAssertEqual(controlCharacter.failure, .invalidAlias)
        XCTAssertEqual(empty.failure, .invalidAlias)
    }

    private func expectedArguments(alias: String) -> [String] {
        [
            "-T",
            "-n",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "ConnectionAttempts=1",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "PermitLocalCommand=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "RequestTTY=no",
            "-o", "RemoteCommand=none",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "--",
            alias,
            "LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin ss -H -n -O -a -t -u -p -e"
        ]
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
