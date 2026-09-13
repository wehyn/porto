import Darwin
import Foundation

enum SSHCommandOutputStream: Sendable, Equatable {
    case stdout
    case stderr
}

enum SSHCommandTerminationReason: Sendable, Equatable {
    case exit
    case signal
}

enum SSHCommandRunnerFailure: Sendable, Equatable {
    case invalidProfile
    case launchFailed
    case timedOut
    case outputTooLarge(stream: SSHCommandOutputStream)
    case readFailed
    case busy
    case cancelled
}

enum RemoteSSHSignal: Int32, Sendable, Equatable { case term = 15; case kill = 9 }

enum RemoteSSHOperation: Sendable, Equatable {
    case scan
    case signal(RemoteSSHSignal, pid: Int32)
}

struct SSHCommandExecutionResult: Sendable, Equatable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32?
    let terminationReason: SSHCommandTerminationReason?
    let failure: SSHCommandRunnerFailure?
    let durationMilliseconds: Int

    var wasCancelled: Bool { failure == .cancelled }
}

protocol SSHCommandRunning: Sendable {
    func run(profile: RemoteServerProfile, operation: RemoteSSHOperation) async -> SSHCommandExecutionResult
    func cancelActive() async
}

actor SSHCommandRunner: SSHCommandRunning {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    static let stdoutLimit = 16 * 1024 * 1024
    static let stderrLimit = 256 * 1024
    static let timeout: Duration = .seconds(5)
    static let remoteCommand = "LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c 'ss -H -n -O -a -t -u -p -e; ss_status=$?; printf \"__PORTO_DOCKER__\\n\"; if command -v docker >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then timeout -k 1 1 docker ps --format \"{{.ID}}\\t{{.Names}}\\t{{.Ports}}\" 2>/dev/null || true; fi; exit \"$ss_status\"'"

    private let executableURL: URL
    private let stdoutLimit: Int
    private let stderrLimit: Int
    private let timeout: Duration
    private let environment: [String: String]
    private var activeProcess: SSHProcessBox?
    private var cancellationRequested = false

    init(
        executableURL: URL = SSHCommandRunner.executableURL,
        stdoutLimit: Int = SSHCommandRunner.stdoutLimit,
        stderrLimit: Int = SSHCommandRunner.stderrLimit,
        timeout: Duration = SSHCommandRunner.timeout,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableURL = executableURL
        self.stdoutLimit = max(0, stdoutLimit)
        self.stderrLimit = max(0, stderrLimit)
        self.timeout = timeout
        var childEnvironment = environment
        childEnvironment["LC_ALL"] = "C"
        self.environment = childEnvironment
    }

    static func arguments(for profile: RemoteServerProfile, operation: RemoteSSHOperation) -> [String]? {
        guard isValid(profile) else { return nil }
        var arguments = ["-T", "-n", "-F", "/dev/null", "-l", profile.username, "-p", String(profile.port)]
        if let identity = profile.identityFilePath { arguments += ["-i", identity] }
        arguments += [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "ConnectionAttempts=1",
            "-o", "NumberOfPasswordPrompts=0", "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no", "-o", "PreferredAuthentications=publickey",
            "-o", "StrictHostKeyChecking=yes", "-o", "PermitLocalCommand=no",
            "-o", "ClearAllForwardings=yes", "-o", "RequestTTY=no", "-o", "RemoteCommand=none",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "--", sshHost(for: profile.host)
        ]
        switch operation {
        case .scan: arguments.append(remoteCommand)
        case let .signal(signal, pid):
            guard pid > 0 else { return nil }
            let name = signal == .term ? "TERM" : "KILL"
            arguments.append("/bin/kill -\(name) -- \(pid)")
        }
        return arguments
    }

    private static func sshHost(for host: String) -> String {
        guard host.first == "[", host.last == "]" else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static func isValid(_ profile: RemoteServerProfile) -> Bool {
        guard (try? profile.validate()) != nil else { return false }
        guard profile.host.first != "-", profile.username.first != "-" else { return false }
        if let path = profile.identityFilePath {
            guard !path.isEmpty, path.first != "-",
                  path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        }
        return true
    }

    func run(profile: RemoteServerProfile, operation: RemoteSSHOperation) async -> SSHCommandExecutionResult {
        guard activeProcess == nil else {
            return Self.immediateFailure(.busy)
        }
        guard let arguments = Self.arguments(for: profile, operation: operation) else {
            return Self.immediateFailure(.invalidProfile)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let processBox = SSHProcessBox(process)
        let stdout = SSHFileHandleBox(stdoutPipe.fileHandleForReading)
        let stderr = SSHFileHandleBox(stderrPipe.fileHandleForReading)
        activeProcess = processBox
        cancellationRequested = false
        let start = DispatchTime.now().uptimeNanoseconds

        guard !Task.isCancelled else {
            activeProcess = nil
            return Self.result(
                stdout: Data(),
                stderr: Data(),
                process: processBox,
                failure: .cancelled,
                started: false,
                start: start
            )
        }

        do {
            try process.run()
        } catch {
            activeProcess = nil
            return Self.result(
                stdout: Data(),
                stderr: Data(),
                process: processBox,
                failure: .launchFailed,
                started: false,
                start: start
            )
        }

        let execution = await withTaskCancellationHandler(operation: {
            await execute(
                process: processBox,
                stdout: stdout,
                stderr: stderr,
                start: start
            )
        }, onCancel: {
            Task { await self.requestCancellation() }
        })

        activeProcess = nil
        cancellationRequested = false
        return execution
    }

    func cancelActive() async {
        guard activeProcess != nil else { return }
        requestCancellation()
        while activeProcess != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func requestCancellation() {
        guard let activeProcess else { return }
        cancellationRequested = true
        activeProcess.terminate()
    }

    private func execute(
        process: SSHProcessBox,
        stdout: SSHFileHandleBox,
        stderr: SSHFileHandleBox,
        start: UInt64
    ) async -> SSHCommandExecutionResult {
        let signals = SSHRunnerSignals()
        let outputLimit = stdoutLimit
        let errorLimit = stderrLimit
        let stdoutTask = Task.detached(priority: .utility) {
            let result = stdout.readLimited(to: outputLimit)
            signals.record(result, stream: .stdout)
            return result
        }
        let stderrTask = Task.detached(priority: .utility) {
            let result = stderr.readLimited(to: errorLimit)
            signals.record(result, stream: .stderr)
            return result
        }

        let event = await waitForEvent(process: process, signals: signals)
        let wasCancelled = Task.isCancelled || event == .cancelled || cancellationRequested
        let didTimeout = event == .timedOut
        let needsCleanup = wasCancelled || didTimeout || event == .outputTooLarge || event == .readFailed

        if needsCleanup {
            await stopProcess(process).value
            stdout.close()
            stderr.close()
        }

        let stdoutResult = await stdoutTask.value
        let stderrResult = await stderrTask.value

        let failure: SSHCommandRunnerFailure?
        if wasCancelled || Task.isCancelled {
            failure = .cancelled
        } else if didTimeout {
            failure = .timedOut
        } else if stdoutResult.exceeded {
            failure = .outputTooLarge(stream: .stdout)
        } else if stderrResult.exceeded {
            failure = .outputTooLarge(stream: .stderr)
        } else if stdoutResult.failed || stderrResult.failed {
            failure = .readFailed
        } else {
            failure = nil
        }

        return Self.result(
            stdout: stdoutResult.data,
            stderr: stderrResult.data,
            process: process,
            failure: failure,
            started: true,
            start: start
        )
    }

    private func waitForEvent(process: SSHProcessBox, signals: SSHRunnerSignals) async -> SSHRunnerEvent {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if Task.isCancelled || cancellationRequested { return .cancelled }
            if let event = signals.failureEvent { return event }
            if !process.isRunning, signals.allReadsComplete { return .exited }
            if ContinuousClock.now >= deadline { return .timedOut }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return .cancelled
            }
        }
    }

    private func stopProcess(_ process: SSHProcessBox) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            process.terminate()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if process.isRunning {
                process.forceKill()
            }
            process.waitUntilExit()
        }
    }

    nonisolated private static func immediateFailure(_ failure: SSHCommandRunnerFailure) -> SSHCommandExecutionResult {
        SSHCommandExecutionResult(
            stdout: Data(),
            stderr: Data(),
            terminationStatus: nil,
            terminationReason: nil,
            failure: failure,
            durationMilliseconds: 0
        )
    }

    nonisolated private static func result(
        stdout: Data,
        stderr: Data,
        process: SSHProcessBox,
        failure: SSHCommandRunnerFailure?,
        started: Bool,
        start: UInt64
    ) -> SSHCommandExecutionResult {
        let duration = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        let reason: SSHCommandTerminationReason? = if started, !process.isRunning {
            switch process.terminationReason {
            case .exit: .exit
            case .uncaughtSignal: .signal
            @unknown default: nil
            }
        } else {
            nil
        }
        return SSHCommandExecutionResult(
            stdout: stdout,
            stderr: stderr,
            terminationStatus: started && !process.isRunning ? process.terminationStatus : nil,
            terminationReason: reason,
            failure: failure,
            durationMilliseconds: duration
        )
    }
}

private enum SSHRunnerEvent: Sendable, Equatable {
    case exited
    case timedOut
    case cancelled
    case outputTooLarge
    case readFailed
}

private final class SSHRunnerSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutResult: SSHLimitedReadResult?
    private var stderrResult: SSHLimitedReadResult?

    var allReadsComplete: Bool {
        lock.withLock { stdoutResult != nil && stderrResult != nil }
    }

    var failureEvent: SSHRunnerEvent? {
        lock.withLock {
            if stdoutResult?.exceeded == true || stderrResult?.exceeded == true {
                return .outputTooLarge
            }
            if stdoutResult?.failed == true || stderrResult?.failed == true {
                return .readFailed
            }
            return nil
        }
    }

    func record(_ result: SSHLimitedReadResult, stream: SSHCommandOutputStream) {
        lock.withLock {
            switch stream {
            case .stdout: stdoutResult = result
            case .stderr: stderrResult = result
            }
        }
    }
}

private struct SSHLimitedReadResult: Sendable {
    let data: Data
    let exceeded: Bool
    let failed: Bool
}

private final class SSHProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }
    var terminationReason: Process.TerminationReason { process.terminationReason }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func forceKill() {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func waitUntilExit() {
        if process.isRunning { process.waitUntilExit() }
    }
}

private final class SSHFileHandleBox: @unchecked Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func close() {
        try? handle.close()
    }

    func readLimited(to limit: Int) -> SSHLimitedReadResult {
        var data = Data()
        do {
            while true {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
                guard chunk.count <= limit - data.count else {
                    close()
                    return SSHLimitedReadResult(data: data, exceeded: true, failed: false)
                }
                data.append(chunk)
            }
            close()
            return SSHLimitedReadResult(data: data, exceeded: false, failed: false)
        } catch {
            close()
            return SSHLimitedReadResult(data: data, exceeded: false, failed: true)
        }
    }
}
