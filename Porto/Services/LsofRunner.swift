import Darwin
import Foundation

enum LsofTerminationReason: Sendable, Equatable {
    case exit
    case signal
}

enum LsofRunnerFailure: Sendable, Equatable {
    case launchFailed
    case timedOut
    case outputTooLarge(stream: ScanFailure.OutputStream)
    case readFailed
    case busy
    case cancelled
}

struct LsofExecutionResult: Sendable, Equatable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32?
    let terminationReason: LsofTerminationReason?
    let failure: LsofRunnerFailure?
    let durationMilliseconds: Int

    var wasCancelled: Bool { failure == .cancelled }
}

protocol LsofRunning: Sendable {
    func run(arguments: [String]) async -> LsofExecutionResult
    func cancelActive() async
}

actor LsofRunner: LsofRunning {
    static let executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    static let stdoutLimit = 16 * 1024 * 1024
    static let stderrLimit = 64 * 1024
    static let timeout: Duration = .seconds(3)

    private let executableURL: URL
    private let stdoutLimit: Int
    private let stderrLimit: Int
    private let timeout: Duration
    private var activeProcess: ProcessBox?
    private var cancellationRequested = false

    init(
        executableURL: URL = LsofRunner.executableURL,
        stdoutLimit: Int = LsofRunner.stdoutLimit,
        stderrLimit: Int = LsofRunner.stderrLimit,
        timeout: Duration = LsofRunner.timeout
    ) {
        self.executableURL = executableURL
        self.stdoutLimit = stdoutLimit
        self.stderrLimit = stderrLimit
        self.timeout = timeout
    }

    func run(arguments: [String]) async -> LsofExecutionResult {
        guard activeProcess == nil else {
            return LsofExecutionResult(
                stdout: Data(),
                stderr: Data(),
                terminationStatus: nil,
                terminationReason: nil,
                failure: .busy,
                durationMilliseconds: 0
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let processBox = ProcessBox(process: process)
        activeProcess = processBox
        cancellationRequested = false
        let start = DispatchTime.now().uptimeNanoseconds

        if Task.isCancelled {
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

        let result = await withTaskCancellationHandler(operation: {
            await execute(
                process: processBox,
                stdout: FileHandleBox(stdoutPipe.fileHandleForReading),
                stderr: FileHandleBox(stderrPipe.fileHandleForReading),
                start: start
            )
        }, onCancel: {
            Task { await self.cancelActive() }
        })
        activeProcess = nil
        cancellationRequested = false
        return result
    }

    nonisolated private static func result(
        stdout: Data,
        stderr: Data,
        process: ProcessBox,
        failure: LsofRunnerFailure?,
        started: Bool,
        start: UInt64
    ) -> LsofExecutionResult {
        let duration = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        let reason: LsofTerminationReason? = if started {
            switch process.process.terminationReason {
            case .exit: .exit
            case .uncaughtSignal: .signal
            @unknown default: nil
            }
        } else {
            nil
        }
        return LsofExecutionResult(
            stdout: stdout,
            stderr: stderr,
            terminationStatus: started && !process.process.isRunning ? process.process.terminationStatus : nil,
            terminationReason: reason,
            failure: failure,
            durationMilliseconds: duration
        )
    }

    private func execute(
        process: ProcessBox,
        stdout: FileHandleBox,
        stderr: FileHandleBox,
        start: UInt64
    ) async -> LsofExecutionResult {
        let signals = RunnerSignals()
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
        let processEvent = await waitForEvent(process: process, signals: signals)

        var stopTask: Task<Void, Never>?
        let wasCancelled = Task.isCancelled || processEvent == .cancelled || cancellationRequested
        let didTimeout = processEvent == .timedOut
        if wasCancelled || didTimeout || processEvent == .outputTooLarge || processEvent == .readFailed {
            stopTask = stopProcess(process)
        }

        let stdoutResult = await stdoutTask.value
        let stderrResult = await stderrTask.value
        if (stdoutResult.exceeded || stderrResult.exceeded || stdoutResult.failed || stderrResult.failed), stopTask == nil {
            stopTask = stopProcess(process)
        }
        if let stopTask {
            await stopTask.value
        }

        let collected = CollectedOutput(
            stdout: stdoutResult,
            stderr: stderrResult,
            didTimeout: didTimeout,
            wasCancelled: wasCancelled
        )

        let failure: LsofRunnerFailure?
        if collected.wasCancelled || Task.isCancelled {
            failure = .cancelled
        } else if collected.didTimeout {
            failure = .timedOut
        } else if collected.stdout.exceeded {
            failure = .outputTooLarge(stream: .stdout)
        } else if collected.stderr.exceeded {
            failure = .outputTooLarge(stream: .stderr)
        } else if collected.stdout.failed || collected.stderr.failed {
            failure = .readFailed
        } else {
            failure = nil
        }

        let result = Self.result(
            stdout: collected.stdout.data,
            stderr: collected.stderr.data,
            process: process,
            failure: failure,
            started: true,
            start: start
        )
        return result
    }

    private func waitForEvent(process: ProcessBox, signals: RunnerSignals) async -> RunnerEvent {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning {
            if Task.isCancelled { return .cancelled }
            if let event = signals.event {
                switch event {
                case .outputTooLarge:
                    return .outputTooLarge
                case .readFailed:
                    return .readFailed
                default:
                    break
                }
            }
            if ContinuousClock.now >= deadline { return .timedOut }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return .cancelled
            }
        }
        return .exited
    }

    private func stopProcess(_ process: ProcessBox) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            process.terminate()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            while process.isRunning, ContinuousClock.now < deadline {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    // A detached cleanup task is intentionally not cancelled by the caller.
                }
            }
            if process.isRunning {
                process.forceKill()
            }
        }
    }

    func cancelActive() async {
        guard let activeProcess else { return }
        cancellationRequested = true
        activeProcess.terminate()
    }
}

private enum RunnerEvent: Sendable, Equatable {
    case exited
    case timedOut
    case cancelled
    case outputTooLarge
    case readFailed
}

private final class RunnerSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutResult: LimitedReadResult?
    private var stderrResult: LimitedReadResult?

    var event: RunnerEvent? {
        lock.lock()
        defer { lock.unlock() }
        if stdoutResult?.exceeded == true || stderrResult?.exceeded == true {
            return .outputTooLarge
        }
        if stdoutResult?.failed == true || stderrResult?.failed == true {
            return .readFailed
        }
        return nil
    }

    func record(_ result: LimitedReadResult, stream: ScanFailure.OutputStream) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .stdout: stdoutResult = result
        case .stderr: stderrResult = result
        }
    }
}

private struct CollectedOutput: Sendable {
    let stdout: LimitedReadResult
    let stderr: LimitedReadResult
    let didTimeout: Bool
    let wasCancelled: Bool
}

private struct LimitedReadResult: Sendable {
    let data: Data
    let exceeded: Bool
    let failed: Bool
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func forceKill() {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }

}

private final class FileHandleBox: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func readLimited(to limit: Int) -> LimitedReadResult {
        var data = Data()
        do {
            while true {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
                if data.count + chunk.count > limit {
                    try? handle.close()
                    return LimitedReadResult(data: data, exceeded: true, failed: false)
                }
                data.append(chunk)
            }
            try? handle.close()
            return LimitedReadResult(data: data, exceeded: false, failed: false)
        } catch {
            try? handle.close()
            return LimitedReadResult(data: data, exceeded: false, failed: true)
        }
    }
}
