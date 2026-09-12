import AppKit
import Combine
import Foundation

@MainActor
final class PortMonitor: ObservableObject {
    @Published private(set) var listenerRows: [PortProcess] = []
    @Published private(set) var connectionRows: [PortProcess] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isManualRefreshing = false
    @Published private(set) var hasSnapshot = false
    @Published private(set) var isStale = false
    @Published private(set) var scanError: ScanFailure?
    @Published private(set) var lastDiagnostics: ScanDiagnostics?
    @Published private(set) var terminationStates: [ProcessIdentity: TerminationUIState] = [:]
    @Published private(set) var forceKillPrompt: PortProcess?

    private let scanner: any PortScanning
    private let terminator: any ProcessTerminating
    private let ownPID: Int32
    private let clock: any MonitorSleeping
    private var refreshTask: Task<Void, Never>?
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
        scanner: any PortScanning,
        terminator: any ProcessTerminating,
        ownPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        clock: any MonitorSleeping = SystemMonitorClock()
    ) {
        self.scanner = scanner
        self.terminator = terminator
        self.ownPID = ownPID
        self.clock = clock
    }

    var isPopoverPresented: Bool { isPresented }

    var allRows: [PortProcess] {
        PortProcessSort.sort(listenerRows + connectionRows)
    }

    func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
        sessionGeneration &+= 1

        if presented {
            pendingRefresh = false
            pendingManualRefresh = false
            isManualRefreshing = false
            startRefreshLoop()
            requestRefresh()
        } else {
            refreshTask?.cancel()
            refreshTask = nil
            pendingRefresh = false
            pendingManualRefresh = false
            isManualRefreshing = false
            forceKillPrompt = nil
            scanTask?.cancel()
            // Keep scanToken until its cancellation cleanup completes. A new
            // presentation must not start a second lsof child beside the old one.
        }
    }

    func refresh() {
        requestRefresh(isManual: true)
    }

    func retry() {
        requestRefresh(isManual: true)
    }

    func terminationState(for row: PortProcess) -> TerminationUIState? {
        guard let identity = row.identity else { return nil }
        return terminationStates[identity]
    }

    func isOwnProcess(_ row: PortProcess) -> Bool {
        row.pid == ownPID
    }

    func isTerminationDisabled(for row: PortProcess) -> Bool {
        guard row.isActionable, !isOwnProcess(row) else { return true }
        guard let identity = row.identity else { return true }
        if case .inProgress? = terminationStates[identity] { return true }
        if let activeTerminationIdentity, activeTerminationIdentity != identity { return true }
        return false
    }

    func requestStop(for row: PortProcess) {
        guard isPresented,
              row.isActionable,
              !isOwnProcess(row),
              let identity = row.identity,
              activeTerminationIdentity == nil else { return }

        pendingRefresh = true
        scanTask?.cancel()
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
            let outcome = await terminator.stop(row: row)
            self.finishTermination(outcome, identity: identity, token: token)
        }
    }

    func requestForceKill(for row: PortProcess) {
        guard isPresented,
              let identity = row.identity,
              terminationStates[identity] == .forceKillAvailable,
              activeTerminationIdentity == nil else { return }
        forceKillPrompt = row
    }

    func cancelForceKillPrompt() {
        forceKillPrompt = nil
    }

    func confirmForceKill() {
        guard let row = forceKillPrompt,
              let identity = row.identity,
              terminationStates[identity] == .forceKillAvailable,
              activeTerminationIdentity == nil else {
            forceKillPrompt = nil
            return
        }
        forceKillPrompt = nil
        pendingRefresh = true
        scanTask?.cancel()
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
            let outcome = await terminator.forceKill(row: row)
            self.finishTermination(outcome, identity: identity, token: token)
        }
    }

    func quitApplication() {
        guard !quitRequested else { return }
        quitRequested = true
        refreshTask?.cancel()
        refreshTask = nil
        scanTask?.cancel()
        terminationTask?.cancel()
        pendingManualRefresh = false
        isManualRefreshing = false
        let scanner = self.scanner
        Task { [weak self] in
            await scanner.cancelActiveWork()
            // LsofRunner's cancellation contract gives a child 500 ms to exit
            // before it is force-killed. Keep the app alive for that cleanup.
            try? await Task.sleep(for: .milliseconds(600))
            guard self != nil else { return }
            NSApplication.shared.terminate(nil)
        }
    }

    private func requestRefresh(isManual: Bool = false) {
        guard isPresented, !quitRequested else { return }
        pendingRefresh = true
        if isManual {
            pendingManualRefresh = true
            isManualRefreshing = true
        }
        guard activeTerminationIdentity == nil, scanToken == nil else { return }
        pendingRefresh = false
        let shouldStartManualRefresh = pendingManualRefresh
        pendingManualRefresh = false
        startScan(isManual: shouldStartManualRefresh)
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        guard !quitRequested else { return }
        let clock = self.clock
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.requestRefresh()
            }
        }
    }

    private func startScan(isManual: Bool) {
        guard isPresented,
              !quitRequested,
              activeTerminationIdentity == nil,
              scanToken == nil else { return }
        scanGeneration &+= 1
        let generation = scanGeneration
        let session = sessionGeneration
        let token = UUID()
        scanToken = token
        activeScanIsManual = isManual
        isScanning = true
        let scanner = self.scanner
        scanTask = Task { [weak self] in
            let outcome = await scanner.scan(generation: generation)
            guard let self else { return }
            self.finishScan(outcome, session: session, token: token)
        }
    }

    private func finishScan(_ outcome: ScanOutcome, session: UInt64, token: UUID) {
        guard scanToken == token else { return }
        let finishedManualRefresh = activeScanIsManual
        activeScanIsManual = false
        scanToken = nil
        scanTask = nil
        isScanning = false

        if finishedManualRefresh && !pendingManualRefresh {
            isManualRefreshing = false
        }

        if session == sessionGeneration, isPresented, !quitRequested {
            switch outcome {
            case let .success(snapshot, diagnostics):
                hasSnapshot = true
                isStale = false
                if listenerRows != snapshot.listeners { listenerRows = snapshot.listeners }
                if connectionRows != snapshot.connections { connectionRows = snapshot.connections }
                lastDiagnostics = diagnostics
                scanError = nil
                clearTerminationStatesForMissingIdentities(in: snapshot)
            case let .failure(error, diagnostics):
                if error != .cancelled {
                    scanError = error
                    isStale = hasSnapshot
                    lastDiagnostics = diagnostics
                }
            case .cancelled:
                break
            }
        }

        if !isPresented {
            pendingRefresh = false
            pendingManualRefresh = false
            isManualRefreshing = false
        } else {
            drainPendingRefreshIfPossible()
        }
    }

    private func waitForScanToFinish() async {
        while scanToken != nil, !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return
            }
        }
    }

    private func finishTermination(
        _ outcome: TerminationOutcome,
        identity: ProcessIdentity,
        token: UUID
    ) {
        guard terminationToken == token, activeTerminationIdentity == identity else { return }
        terminationTask = nil
        terminationToken = nil
        activeTerminationIdentity = nil

        switch outcome {
        case .exited:
            terminationStates.removeValue(forKey: identity)
            removeRows(for: identity)
            if isPresented { pendingRefresh = true }
        case .forceKillAvailable:
            terminationStates[identity] = .forceKillAvailable
        case let .failed(failure):
            terminationStates[identity] = .failed(failure)
            if isPresented { pendingRefresh = true }
        case .cancelled:
            terminationStates.removeValue(forKey: identity)
        }
        drainPendingRefreshIfPossible()
    }

    private func drainPendingRefreshIfPossible() {
        guard isPresented,
              !quitRequested,
              pendingRefresh,
              activeTerminationIdentity == nil,
              scanToken == nil else { return }
        pendingRefresh = false
        let shouldStartManualRefresh = pendingManualRefresh
        pendingManualRefresh = false
        startScan(isManual: shouldStartManualRefresh)
    }

    private func removeRows(for identity: ProcessIdentity) {
        let newListeners = listenerRows.filter { $0.identity != identity }
        let newConnections = connectionRows.filter { $0.identity != identity }
        if listenerRows != newListeners { listenerRows = newListeners }
        if connectionRows != newConnections { connectionRows = newConnections }
    }

    private func clearTerminationStatesForMissingIdentities(in snapshot: PortSnapshot) {
        let identities = Set(snapshot.allRows.compactMap(\.identity))
        let retainedStates = terminationStates.filter { identities.contains($0.key) }
        if retainedStates != terminationStates {
            terminationStates = retainedStates
        }
        if let promptIdentity = forceKillPrompt?.identity, !identities.contains(promptIdentity) {
            forceKillPrompt = nil
        }
    }
}
