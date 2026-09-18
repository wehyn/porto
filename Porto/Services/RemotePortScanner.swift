import Foundation

actor RemotePortScanner: PortSnapshotScanning {
    let profile: RemoteServerProfile
    private let runner: any SSHCommandRunning
    private let outputParser: RemotePortOutputParser
    private let visibilityPolicy: PortVisibilityPolicy
    private let dockerMetadataRefreshInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var cachedDockerPortCatalog: DockerPortCatalog?
    private var cachedDockerMetadataAt: ContinuousClock.Instant?

    init(
        profile: RemoteServerProfile,
        runner: any SSHCommandRunning = SSHCommandRunner(),
        parser: SsParser = SsParser(),
        visibilityPolicy: PortVisibilityPolicy = .remoteFocused,
        dockerMetadataRefreshInterval: Duration = .seconds(30),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.profile = profile
        self.runner = runner
        self.outputParser = RemotePortOutputParser(ssParser: parser)
        self.visibilityPolicy = visibilityPolicy
        self.dockerMetadataRefreshInterval = dockerMetadataRefreshInterval
        self.now = now
    }

    func scan(_ request: PortScanRequest) async -> PortScanOutcome {
        let expectedTargetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        guard request.targetID == expectedTargetID else {
            return failure(.readFailed, request: request, diagnostics: .empty)
        }

        let includeDockerMetadata = shouldRefreshDockerMetadata(for: request.trigger)
        let execution = await runner.run(
            profile: profile,
            operation: .scan(includeDockerMetadata: includeDockerMetadata)
        )
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
            if includeDockerMetadata && parsed.dockerMetadataSucceeded {
                cachedDockerPortCatalog = parsed.dockerPorts
                cachedDockerMetadataAt = now()
            }
            let diagnostics = ScanDiagnostics(
                stdoutBytes: execution.stdout.count,
                stderrBytes: execution.stderr.count,
                validRecords: parsed.validRecords,
                skippedRecords: parsed.skippedRecords,
                durationMilliseconds: execution.durationMilliseconds
            )
            let dockerPorts: DockerPortCatalog
            if includeDockerMetadata {
                dockerPorts = parsed.dockerMetadataSucceeded
                    ? parsed.dockerPorts
                    : (cachedDockerPortCatalog ?? .empty)
            } else {
                dockerPorts = cachedDockerPortCatalog ?? .empty
            }
            let dockerLabeledSnapshot = dockerPorts.applying(to: parsed.snapshot)
            return .success(TargetedPortSnapshot(
                targetID: request.targetID,
                sessionGeneration: request.sessionGeneration,
                snapshot: visibilityPolicy.filtering(dockerLabeledSnapshot),
                diagnostics: diagnostics,
                revalidationSnapshot: dockerLabeledSnapshot
            ))
        case .failure:
            return failure(.malformedOutput, request: request, diagnostics: base)
        }
    }

    private func shouldRefreshDockerMetadata(for trigger: ScanTrigger) -> Bool {
        guard trigger == .scheduled,
              let cachedDockerMetadataAt,
              now() < cachedDockerMetadataAt.advanced(by: dockerMetadataRefreshInterval) else {
            return true
        }
        return false
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
        case .invalidProfile: .launchFailed
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
