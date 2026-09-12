import AppKit
import Combine
import Foundation

@MainActor
final class PortMonitor: ObservableObject {
    typealias RemoteScannerFactory = @MainActor (SSHHost) -> any PortSnapshotScanning

    @Published private(set) var listenerRows: [PortProcess] = []
    @Published private(set) var connectionRows: [PortProcess] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isManualRefreshing = false
    @Published private(set) var hasSnapshot = false
    @Published private(set) var isStale = false
    @Published private(set) var scanError: ScanFailure?
    @Published private(set) var remoteFailure: RemoteScanFailure?
    @Published private(set) var lastDiagnostics: ScanDiagnostics?
    @Published private(set) var terminationStates: [ProcessIdentity: TerminationUIState] = [:]
    @Published private(set) var forceKillPrompt: PortProcess?
    @Published private(set) var sshHosts: [SSHHost] = []
    @Published private(set) var catalogDiagnostics: [SSHHostCatalogDiagnostic] = []
    @Published private(set) var selectedTarget: PortTarget = .local
    @Published var connectionsExpanded = false
    @Published private(set) var nextRetrySeconds: Int?

    private let localScanner: any PortSnapshotScanning
    private let terminator: any ProcessTerminating
    private let ownPID: Int32
    private let clock: any MonitorSleeping
    private let hostCatalog: SSHHostCatalog?
    private let remoteScannerFactory: RemoteScannerFactory?
    private var activeScanner: (any PortSnapshotScanning)?
    private var targetStates: [PortTargetID: TargetMonitorState] = [:]
    private var scheduleTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var scanToken: UUID?
    private var terminationTask: Task<Void, Never>?
    private var terminationToken: UUID?
    private var activeTerminationIdentity: ProcessIdentity?
    private var pendingRefresh = false
    private var pendingManualRefresh = false
    private var activeScanIsManual = false
    private var sessionGeneration: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    private var isPresented = false
    private var quitRequested = false

    init(
        localScanner: any PortSnapshotScanning,
        terminator: any ProcessTerminating,
        hostCatalog: SSHHostCatalog,
        remoteScannerFactory: @escaping RemoteScannerFactory,
        ownPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        clock: any MonitorSleeping = SystemMonitorClock()
    ) {
        self.localScanner = localScanner
        self.terminator = terminator
        self.hostCatalog = hostCatalog
        self.remoteScannerFactory = remoteScannerFactory
        self.ownPID = ownPID
        self.clock = clock
        self.activeScanner = localScanner
        reloadHostCatalog()
    }

    init(
        scanner: any PortScanning,
        terminator: any ProcessTerminating,
        ownPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        clock: any MonitorSleeping = SystemMonitorClock()
    ) {
        self.localScanner = scanner
        self.terminator = terminator
        self.hostCatalog = nil
        self.remoteScannerFactory = nil
        self.ownPID = ownPID
        self.clock = clock
        self.activeScanner = scanner
    }

    var isPopoverPresented: Bool { isPresented }
    var allRows: [PortProcess] { PortProcessSort.sort(listenerRows + connectionRows) }
    var isRemoteTarget: Bool { selectedTarget.isRemote }
    var isTargetPickerDisabled: Bool { activeTerminationIdentity != nil || forceKillPrompt != nil }
    var availableTargets: [PortTarget] { [.local] + sshHosts.map(PortTarget.ssh) }

    var targetStatusText: String {
        if !isRemoteTarget {
            if isScanning && !hasSnapshot { return "Scanning This Mac…" }
            if isScanning { return "Refreshing…" }
            return "Local inspection"
        }
        if isScanning && !hasSnapshot { return "Connecting over SSH… · read-only" }
        if isScanning { return isStale ? "Reconnecting… · showing in-memory results" : "Refreshing… · read-only" }
        if let remoteFailure {
            var message = remoteFailure.userMessage + (hasSnapshot ? " Showing last results." : "")
            if let nextRetrySeconds { message += " Retrying in " + String(nextRetrySeconds) + "s." }
            return message
        }
        if hasSnapshot { return "Available over SSH · updated just now · read-only" }
        return "Ready to connect · read-only"
    }

    func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
        sessionGeneration &+= 1
        scheduleTask?.cancel()
        scheduleTask = nil
        nextRetrySeconds = nil
        if presented {
            connectionsExpanded = false
            reloadHostCatalog()
            pendingRefresh = false
            pendingManualRefresh = false
            isManualRefreshing = false
            publishSelectedTargetState()
            requestRefresh(trigger: .presentation)
        } else {
            pendingRefresh = false
            pendingManualRefresh = false
            isManualRefreshing = false
            forceKillPrompt = nil
            scanTask?.cancel()
            let scanner = activeScanner
            Task { await scanner?.cancelActiveWork() }
        }
    }

    func selectTarget(_ target: PortTarget) {
        switchTarget(target)
    }

    private func switchTarget(_ target: PortTarget, bypassPicker: Bool = false) {
        guard target != selectedTarget,
              (bypassPicker || !isTargetPickerDisabled),
              availableTargets.contains(target) else { return }
        sessionGeneration &+= 1
        selectedTarget = target
        scheduleTask?.cancel()
        scheduleTask = nil
        nextRetrySeconds = nil
        pendingRefresh = true
        pendingManualRefresh = false
        isManualRefreshing = false
        let previousScanner = activeScanner
        activeScanner = scanner(for: target)
        publishSelectedTargetState()
        scanTask?.cancel()
        Task { [weak self] in
            await previousScanner?.cancelActiveWork()
            guard let self, self.isPresented else { return }
            self.drainPendingRefreshIfPossible(trigger: .targetChange)
        }
    }

    func refresh() { requestRefresh(isManual: true, trigger: .manual) }
    func retry() { requestRefresh(isManual: true, trigger: .manual) }

    func terminationState(for row: PortProcess) -> TerminationUIState? {
        guard let identity = row.localIdentity else { return nil }
        return terminationStates[identity]
    }

    func isOwnProcess(_ row: PortProcess) -> Bool { row.localIdentity?.pid == ownPID }

    func isTerminationDisabled(for row: PortProcess) -> Bool {
        guard let identity = row.localIdentity, identity.pid != ownPID else { return true }
        if case .inProgress? = terminationStates[identity] { return true }
        if let activeTerminationIdentity, activeTerminationIdentity != identity { return true }
        return false
    }

    func requestStop(for row: PortProcess) {
        guard isPresented, let identity = row.localIdentity, identity.pid != ownPID, activeTerminationIdentity == nil else { return }
        pendingRefresh = true
        cancelActiveScan()
        activeTerminationIdentity = identity
        let token = UUID()
        terminationToken = token
        terminationStates[identity] = .inProgress
        let terminator = self.terminator
        terminationTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForScanToFinish()
            guard !Task.isCancelled else {
                self.finishTermination(.cancelled, identity: identity, token: token)
                return
            }
            self.finishTermination(await terminator.stop(row: row), identity: identity, token: token)
        }
    }

    func requestForceKill(for row: PortProcess) {
        guard isPresented, let identity = row.localIdentity,
              terminationStates[identity] == .forceKillAvailable,
              activeTerminationIdentity == nil else { return }
        forceKillPrompt = row
    }

    func cancelForceKillPrompt() { forceKillPrompt = nil }

    func confirmForceKill() {
        guard let row = forceKillPrompt, let identity = row.localIdentity,
              terminationStates[identity] == .forceKillAvailable,
              activeTerminationIdentity == nil else {
            forceKillPrompt = nil
            return
        }
        forceKillPrompt = nil
        pendingRefresh = true
        cancelActiveScan()
        activeTerminationIdentity = identity
        let token = UUID()
        terminationToken = token
        terminationStates[identity] = .inProgress
        let terminator = self.terminator
        terminationTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForScanToFinish()
            guard !Task.isCancelled else {
                self.finishTermination(.cancelled, identity: identity, token: token)
                return
            }
            self.finishTermination(await terminator.forceKill(row: row), identity: identity, token: token)
        }
    }

    func quitApplication() {
        guard !quitRequested else { return }
        quitRequested = true
        sessionGeneration &+= 1
        scheduleTask?.cancel()
        nextRetrySeconds = nil
        scanTask?.cancel()
        terminationTask?.cancel()
        pendingManualRefresh = false
        isManualRefreshing = false
        let scanner = activeScanner
        Task {
            await scanner?.cancelActiveWork()
            try? await Task.sleep(for: .milliseconds(600))
            NSApplication.shared.terminate(nil)
        }
    }

    private func scanner(for target: PortTarget) -> any PortSnapshotScanning {
        switch target {
        case .local: localScanner
        case let .ssh(host): remoteScannerFactory?(host) ?? localScanner
        }
    }

    private func reloadHostCatalog() {
        guard let hostCatalog else { return }
        let result = hostCatalog.load(previous: sshHosts)
        sshHosts = result.hosts
        catalogDiagnostics = result.diagnostics
        if case let .ssh(selectedHost) = selectedTarget, !sshHosts.contains(selectedHost) {
            switchTarget(.local, bypassPicker: true)
        }
    }

    private func publishSelectedTargetState() {
        let state = targetStates[selectedTarget.id] ?? .empty
        listenerRows = state.snapshot?.listeners ?? []
        connectionRows = state.snapshot?.connections ?? []
        hasSnapshot = state.snapshot != nil
        isStale = state.snapshot != nil && selectedTarget.isRemote
        lastDiagnostics = state.diagnostics
        if case let .local(error)? = state.failure { scanError = error } else { scanError = nil }
        if case let .remote(error)? = state.failure { remoteFailure = error } else { remoteFailure = nil }
    }

    private func requestRefresh(isManual: Bool = false, trigger: ScanTrigger = .scheduled) {
        guard isPresented, !quitRequested else { return }
        scheduleTask?.cancel()
        scheduleTask = nil
        nextRetrySeconds = nil
        pendingRefresh = true
        if isManual {
            pendingManualRefresh = true
            isManualRefreshing = true
        }
        drainPendingRefreshIfPossible(trigger: trigger)
    }

    private func drainPendingRefreshIfPossible(trigger: ScanTrigger = .scheduled) {
        guard isPresented, !quitRequested, pendingRefresh,
              activeTerminationIdentity == nil, scanToken == nil else { return }
        pendingRefresh = false
        let manual = pendingManualRefresh
        pendingManualRefresh = false
        startScan(isManual: manual, trigger: manual ? .manual : trigger)
    }

    private func startScan(isManual: Bool, trigger: ScanTrigger) {
        guard isPresented, !quitRequested, activeTerminationIdentity == nil, scanToken == nil else { return }
        scanGeneration &+= 1
        let request = PortScanRequest(
            targetID: selectedTarget.id,
            sessionGeneration: sessionGeneration,
            scanGeneration: scanGeneration,
            trigger: trigger
        )
        let token = UUID()
        let scanner = activeScanner ?? scanner(for: selectedTarget)
        activeScanner = scanner
        scanToken = token
        activeScanIsManual = isManual
        isScanning = true
        if selectedTarget.isRemote, hasSnapshot { isStale = true }
        scanTask = Task { [weak self] in
            let outcome = await scanner.scan(request)
            guard let self else { return }
            self.finishScan(outcome, request: request, token: token)
        }
    }

    private func finishScan(_ outcome: PortScanOutcome, request: PortScanRequest, token: UUID) {
        guard scanToken == token else { return }
        let finishedManual = activeScanIsManual
        activeScanIsManual = false
        scanToken = nil
        scanTask = nil
        isScanning = false
        if finishedManual && !pendingManualRefresh { isManualRefreshing = false }
        let matches = request.targetID == selectedTarget.id
            && request.sessionGeneration == sessionGeneration && isPresented && !quitRequested
        var retryDelay: Duration = .seconds(2)
        if matches {
            switch outcome {
            case let .success(targeted)
                where targeted.targetID == request.targetID && targeted.sessionGeneration == request.sessionGeneration:
                var state = targetStates[request.targetID] ?? .empty
                state.snapshot = targeted.snapshot
                state.lastSuccess = .now
                state.diagnostics = targeted.diagnostics
                state.failure = nil
                state.consecutiveFailures = 0
                targetStates[request.targetID] = state
                publishSelectedTargetState()
                isStale = false
                clearTerminationStatesForMissingIdentities(in: targeted.snapshot)
            case let .failure(targetID, session, error, diagnostics)
                where targetID == request.targetID && session == request.sessionGeneration:
                if !error.isCancellation {
                    var state = targetStates[request.targetID] ?? .empty
                    state.diagnostics = diagnostics
                    state.failure = error
                    state.consecutiveFailures += 1
                    targetStates[request.targetID] = state
                    publishSelectedTargetState()
                    isStale = hasSnapshot
                    if selectedTarget.isRemote { retryDelay = Self.backoffDelay(for: state.consecutiveFailures) }
                }
            case .success, .failure, .cancelled:
                break
            }
        }
        if !isPresented {
            pendingRefresh = false
            pendingManualRefresh = false
            isManualRefreshing = false
        } else if pendingRefresh {
            drainPendingRefreshIfPossible()
        } else {
            scheduleNext(after: retryDelay)
        }
    }

    static func backoffDelay(for failures: Int) -> Duration {
        .seconds([2, 4, 8, 16, 30][min(max(failures - 1, 0), 4)])
    }

    private func scheduleNext(after duration: Duration) {
        scheduleTask?.cancel()
        let clock = self.clock
        nextRetrySeconds = Int(duration.components.seconds)
        scheduleTask = Task { [weak self] in
            do { try await clock.sleep(for: duration) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.nextRetrySeconds = nil
            self.requestRefresh()
        }
    }

    private func waitForScanToFinish() async {
        while scanToken != nil, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
    }

    private func cancelActiveScan() {
        scanTask?.cancel()
        let scanner = activeScanner
        Task { await scanner?.cancelActiveWork() }
    }

    private func finishTermination(_ outcome: TerminationOutcome, identity: ProcessIdentity, token: UUID) {
        guard terminationToken == token, activeTerminationIdentity == identity else { return }
        terminationTask = nil
        terminationToken = nil
        activeTerminationIdentity = nil
        switch outcome {
        case .exited:
            terminationStates.removeValue(forKey: identity)
            removeRows(for: identity)
            if isPresented { pendingRefresh = true }
        case .forceKillAvailable: terminationStates[identity] = .forceKillAvailable
        case let .failed(failure):
            terminationStates[identity] = .failed(failure)
            if isPresented { pendingRefresh = true }
        case .cancelled: terminationStates.removeValue(forKey: identity)
        }
        drainPendingRefreshIfPossible()
    }

    private func removeRows(for identity: ProcessIdentity) {
        listenerRows.removeAll { $0.localIdentity == identity }
        connectionRows.removeAll { $0.localIdentity == identity }
        if var state = targetStates[.local], let snapshot = state.snapshot {
            state.snapshot = PortSnapshot(
                listeners: snapshot.listeners.filter { $0.localIdentity != identity },
                connections: snapshot.connections.filter { $0.localIdentity != identity }
            )
            targetStates[.local] = state
        }
    }

    private func clearTerminationStatesForMissingIdentities(in snapshot: PortSnapshot) {
        let identities = Set(snapshot.allRows.compactMap(\.localIdentity))
        terminationStates = terminationStates.filter { identities.contains($0.key) }
        if let promptIdentity = forceKillPrompt?.localIdentity, !identities.contains(promptIdentity) { forceKillPrompt = nil }
    }
}
