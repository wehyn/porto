import Foundation

/// Terminates a process on one explicitly configured remote profile. Every
/// signal is preceded by a complete, target-scoped snapshot revalidation.
actor RemoteProcessTerminator: ProcessTerminating {
    private let profile: RemoteServerProfile
    private let runner: any SSHCommandRunning
    private let clock: any MonitorSleeping
    private let now: @Sendable () -> ContinuousClock.Instant
    private var generation: UInt64 = 0

    private static let waitBound = Duration.seconds(2)

    init(
        profile: RemoteServerProfile,
        runner: any SSHCommandRunning,
        clock: any MonitorSleeping = SystemMonitorClock(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.profile = profile
        self.runner = runner
        self.clock = clock
        self.now = now
    }

    func stop(row: PortProcess) async -> TerminationOutcome {
        guard validRemoteRow(row), !Task.isCancelled else {
            return Task.isCancelled ? .cancelled : .failed(.staleTarget)
        }
        switch await revalidate(row) {
        case .exited: return .exited
        case .failed(let failure): return .failed(failure)
        case .matched: break
        }
        guard !Task.isCancelled else { return .cancelled }
        switch await signal(.term, pid: row.pid!) {
        case .exited: return .exited
        case .failed(let failure): return .failed(failure)
        case .sent: break
        }
        return await waitAfterTerm(row: row)
    }

    func forceKill(row: PortProcess) async -> TerminationOutcome {
        guard validRemoteRow(row), !Task.isCancelled else {
            return Task.isCancelled ? .cancelled : .failed(.staleTarget)
        }
        switch await revalidate(row) {
        case .exited: return .exited
        case .failed(let failure): return .failed(failure)
        case .matched: break
        }
        guard !Task.isCancelled else { return .cancelled }
        switch await signal(.kill, pid: row.pid!) {
        case .exited: return .exited
        case .failed(let failure): return .failed(failure)
        case .sent: break
        }
        return await waitForExit(row: row, checks: 20, forceKill: true)
    }

    private enum Revalidation { case matched, exited, failed(TerminationFailure) }
    private enum SignalResult { case sent, exited, failed(TerminationFailure) }

    private var targetID: PortTargetID { PortTargetID(rawValue: "remote:\(profile.id.uuidString)") }

    private func validRemoteRow(_ row: PortProcess) -> Bool {
        guard row.pid ?? 0 > 0 else { return false }
        // Owner-backed rows without ss -e identity are intentionally
        // non-destructive: PID and name can both be reused.
        guard let socketIdentity = row.remoteSocketIdentity, !socketIdentity.isEmpty else { return false }
        guard case let .remote(targetID, pid) = row.origin,
              targetID == self.targetID, pid == row.pid else { return false }
        return true
    }

    private func revalidate(_ row: PortProcess) async -> Revalidation {
        guard !Task.isCancelled else { return .failed(.revalidationFailed) }
        generation &+= 1
        let request = PortScanRequest(targetID: targetID, sessionGeneration: generation,
                                      scanGeneration: generation, trigger: .manual)
        let outcome = await withTaskCancellationHandler(operation: {
            await RemotePortScanner(profile: profile, runner: runner).scan(request)
        }, onCancel: {
            Task { await runner.cancelActive() }
        })
        guard !Task.isCancelled else { return .failed(.revalidationFailed) }
        switch outcome {
        case .cancelled: return .failed(.revalidationFailed)
        case .failure(_, _, let error, _):
            if case let .remote(remoteFailure) = error { return .failed(map(remoteFailure)) }
            return .failed(.revalidationFailed)
        case .success(let targeted):
            guard let current = targeted.snapshot.allRows.first(where: { $0.id == row.id }) else {
                return .failed(.staleTarget)
            }
            return equivalent(current, row) ? .matched : .failed(.staleTarget)
        }
    }

    private func equivalent(_ lhs: PortProcess, _ rhs: PortProcess) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid && lhs.processName == rhs.processName
            && lhs.activityKind == rhs.activityKind && lhs.transports == rhs.transports
            && lhs.localPorts == rhs.localPorts && lhs.endpoints == rhs.endpoints
            && lhs.remoteSocketIdentity == rhs.remoteSocketIdentity
    }

    private func signal(_ signal: RemoteSSHSignal, pid: Int32) async -> SignalResult {
        let result = await withTaskCancellationHandler(operation: {
            await runner.run(profile: profile, operation: .signal(signal, pid: pid))
        }, onCancel: {
            Task { await runner.cancelActive() }
        })
        if result.failure == .cancelled { return .failed(.revalidationFailed) }
        if Task.isCancelled { return .failed(.revalidationFailed) }
        if let failure = result.failure { return .failed(map(failure)) }
        guard result.terminationStatus == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self).lowercased()
            if stderr.contains("permission denied") || stderr.contains("operation not permitted") {
                return .failed(.permissionDenied)
            }
            if stderr.contains("no such process") { return .exited }
            return .failed(.revalidationFailed)
        }
        return .sent
    }

    private func waitAfterTerm(row: PortProcess) async -> TerminationOutcome {
        await waitForExit(row: row, checks: 20, forceKill: false)
    }

    private func waitForExit(row: PortProcess, checks: Int, forceKill: Bool) async -> TerminationOutcome {
        let deadline = now() + Self.waitBound
        for _ in 0..<checks {
            guard !Task.isCancelled else { return .cancelled }
            let remaining = deadline - now()
            guard remaining > .zero else { break }
            do { try await clock.sleep(for: min(.milliseconds(100), remaining)) }
            catch { return .cancelled }
            guard !Task.isCancelled else { return .cancelled }
            switch await snapshotContains(row, before: deadline) {
            case .exited: return .exited
            case .failed: return .failed(.revalidationFailed)
            case .present: continue
            case .timedOut: break
            case .cancelled: return .cancelled
            }
            break
        }
        return forceKill ? .failed(.stillAlive) : .forceKillAvailable
    }

    private enum Presence { case present, exited, failed, timedOut, cancelled }
    private func snapshotContains(_ row: PortProcess, before deadline: ContinuousClock.Instant) async -> Presence {
        let remaining = deadline - now()
        guard remaining > .zero else { return .timedOut }

        return await withTaskGroup(of: Presence?.self) { group in
            group.addTask { await self.snapshotContains(row) }
            group.addTask {
                do {
                    try await Task.sleep(for: remaining)
                    return nil
                } catch {
                    return .some(.cancelled)
                }
            }
            guard let result = await group.next() else { return .cancelled }
            group.cancelAll()
            if Task.isCancelled { return .cancelled }
            return result ?? .timedOut
        }
    }

    private func snapshotContains(_ row: PortProcess) async -> Presence {
        generation &+= 1
        let request = PortScanRequest(targetID: targetID, sessionGeneration: generation,
                                      scanGeneration: generation, trigger: .scheduled)
        let outcome = await withTaskCancellationHandler(operation: {
            await RemotePortScanner(profile: profile, runner: runner).scan(request)
        }, onCancel: {
            Task { await runner.cancelActive() }
        })
        switch outcome {
        case .success(let snapshot):
            guard let current = snapshot.snapshot.allRows.first(where: { $0.id == row.id }) else { return .exited }
            return equivalent(current, row) ? .present : .failed
        case .failure: return .failed
        case .cancelled: return .failed
        }
    }

    private func map(_ failure: SSHCommandRunnerFailure) -> TerminationFailure {
        failure == .cancelled ? .revalidationFailed : .revalidationFailed
    }

    private func map(_ failure: RemoteScanFailure) -> TerminationFailure {
        failure == .cancelled ? .revalidationFailed : .revalidationFailed
    }
}
