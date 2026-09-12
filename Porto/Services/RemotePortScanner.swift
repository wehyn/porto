import Foundation

actor RemotePortScanner: PortSnapshotScanning {
    private let host: SSHHost
    private let runner: any SSHCommandRunning
    private let outputParser: RemotePortOutputParser
    private let visibilityPolicy: PortVisibilityPolicy

    init(
        host: SSHHost,
        runner: any SSHCommandRunning = SSHCommandRunner(),
        parser: SsParser = SsParser(),
        visibilityPolicy: PortVisibilityPolicy = .remoteFocused
    ) {
        self.host = host
        self.runner = runner
        self.outputParser = RemotePortOutputParser(ssParser: parser)
        self.visibilityPolicy = visibilityPolicy
    }

    func scan(_ request: PortScanRequest) async -> PortScanOutcome {
        guard request.targetID == PortTarget.ssh(host).id else {
            return failure(.readFailed, request: request, diagnostics: .empty)
        }

        let execution = await runner.run(alias: host.alias)
        let base = ScanDiagnostics(
            stdoutBytes: execution.stdout.count,
            stderrBytes: execution.stderr.count,
            validRecords: 0,
            skippedRecords: 0,
            durationMilliseconds: execution.durationMilliseconds
        )

        if let runnerFailure = execution.failure {
            let mapped = mapRunnerFailure(runnerFailure)
            if mapped == .cancelled { return .cancelled }
            return failure(mapped, request: request, diagnostics: base)
        }
        guard let status = execution.terminationStatus else { return .cancelled }
        guard status == 0 else {
            return failure(
                mapExit(status: status, stderr: execution.stderr),
                request: request,
                diagnostics: base
            )
        }
        guard !Task.isCancelled else { return .cancelled }

        switch outputParser.parse(execution.stdout, targetID: request.targetID) {
        case let .success(parsed):
            let diagnostics = ScanDiagnostics(
                stdoutBytes: execution.stdout.count,
                stderrBytes: execution.stderr.count,
                validRecords: parsed.validRecords,
                skippedRecords: parsed.skippedRecords,
                durationMilliseconds: execution.durationMilliseconds
            )
            let dockerLabeledSnapshot = parsed.dockerPorts.applying(to: parsed.snapshot)
            return .success(TargetedPortSnapshot(
                targetID: request.targetID,
                sessionGeneration: request.sessionGeneration,
                snapshot: visibilityPolicy.filtering(dockerLabeledSnapshot),
                diagnostics: diagnostics
            ))
        case .failure:
            return failure(.malformedOutput, request: request, diagnostics: base)
        }
    }

    func cancelActiveWork() async {
        await runner.cancelActive()
    }

    private func failure(
        _ error: RemoteScanFailure,
        request: PortScanRequest,
        diagnostics: ScanDiagnostics
    ) -> PortScanOutcome {
        .failure(
            targetID: request.targetID,
            sessionGeneration: request.sessionGeneration,
            error: .remote(error),
            diagnostics: diagnostics
        )
    }

    private func mapRunnerFailure(_ failure: SSHCommandRunnerFailure) -> RemoteScanFailure {
        switch failure {
        case .invalidAlias: .launchFailed
        case .launchFailed:
            FileManager.default.isExecutableFile(atPath: SSHCommandRunner.executableURL.path)
                ? .launchFailed : .sshNotFound
        case .timedOut: .commandTimedOut
        case let .outputTooLarge(stream):
            .outputTooLarge(stream: stream == .stdout ? .stdout : .stderr)
        case .readFailed, .busy: .readFailed
        case .cancelled: .cancelled
        }
    }

    private func mapExit(status: Int32, stderr: Data) -> RemoteScanFailure {
        let diagnostic = String(decoding: stderr, as: UTF8.self).lowercased()
        if status == 126 || status == 127
            || diagnostic.contains("ss: command not found")
            || diagnostic.contains("ss: not found")
            || diagnostic.contains("unknown option")
            || diagnostic.contains("invalid option") {
            return .ssUnavailableOrIncompatible
        }
        if diagnostic.contains("permission denied")
            || diagnostic.contains("too many authentication failures")
            || diagnostic.contains("no supported authentication methods") {
            return .authenticationFailed
        }
        if diagnostic.contains("host key verification failed")
            || diagnostic.contains("remote host identification has changed") {
            return .hostKeyVerificationFailed
        }
        if diagnostic.contains("connection timed out") || diagnostic.contains("operation timed out") {
            return .connectionTimedOut
        }
        if diagnostic.contains("could not resolve hostname")
            || diagnostic.contains("name or service not known")
            || diagnostic.contains("no route to host")
            || diagnostic.contains("connection refused")
            || diagnostic.contains("network is unreachable") {
            return .hostUnreachable
        }
        return .nonZeroExit(status: status)
    }
}

private extension ScanDiagnostics {
    static let empty = ScanDiagnostics(
        stdoutBytes: 0,
        stderrBytes: 0,
        validRecords: 0,
        skippedRecords: 0,
        durationMilliseconds: 0
    )
}
