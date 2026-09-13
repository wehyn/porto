import AppKit
import Combine
import Foundation

@MainActor
final class PortMonitor: ObservableObject {
    typealias RemoteScannerFactory = @MainActor (RemoteServerProfile) -> any PortSnapshotScanning
    typealias RemoteTerminatorFactory = @MainActor (RemoteServerProfile) -> any ProcessTerminating

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
    @Published private(set) var selectedTarget: PortTarget = .local
    @Published var connectionsExpanded = false
    @Published private(set) var nextRetrySeconds: Int?
    @Published private(set) var profiles: [RemoteServerProfile] = []
    @Published private(set) var activeRemoteTerminationKey: String?
    @Published private(set) var remoteTerminationStates: [String: TerminationUIState] = [:]
    private var remoteTerminationRows: [String: PortProcess] = [:]

    private let localScanner: any PortSnapshotScanning
    private let terminator: any ProcessTerminating
    private let ownPID: Int32
    private let clock: any MonitorSleeping
    private let profileStore: (any RemoteServerProfileStoring)?
    private let remoteScannerFactory: RemoteScannerFactory?
    private let remoteTerminatorFactory: RemoteTerminatorFactory?
    private var activeScanner: (any PortSnapshotScanning)?
    private var targetStates: [PortTargetID: TargetMonitorState] = [:]
    private var scheduleTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var scanToken: UUID?
    private var terminationTask: Task<Void, Never>?
    private var terminationToken: UUID?
    private var activeTerminationIdentity: ProcessIdentity?
    @Published private(set) var connectionTestActive = false
    private var activeConnectionTestProfileID: UUID?
    private var activeConnectionTestScanner: (any PortSnapshotScanning)?
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
        remoteScannerFactory: @escaping RemoteScannerFactory,
        profileStore: any RemoteServerProfileStoring,
        remoteTerminatorFactory: @escaping RemoteTerminatorFactory,
        ownPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        clock: any MonitorSleeping = SystemMonitorClock()
    ) {
        self.localScanner = localScanner
        self.terminator = terminator
        self.profileStore = profileStore
        self.remoteScannerFactory = remoteScannerFactory
        self.remoteTerminatorFactory = remoteTerminatorFactory
        self.ownPID = ownPID
        self.clock = clock
        self.activeScanner = localScanner
        self.profiles = profileStore.profiles
    }

    init(
        scanner: any PortScanning,
        terminator: any ProcessTerminating,
        ownPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        clock: any MonitorSleeping = SystemMonitorClock()
    ) {
        self.localScanner = scanner
        self.terminator = terminator
        self.profileStore = nil
        self.remoteScannerFactory = nil
        self.remoteTerminatorFactory = nil
        self.ownPID = ownPID
        self.clock = clock
        self.activeScanner = scanner
    }

    var isPopoverPresented: Bool { isPresented }
    var allRows: [PortProcess] { PortProcessSort.sort(listenerRows + connectionRows) }
    var isRemoteTarget: Bool { selectedTarget.isRemote }
    var isTargetPickerDisabled: Bool {
        connectionTestActive || activeTerminationIdentity != nil || activeRemoteTerminationKey != nil || forceKillPrompt != nil
    }
    var availableTargets: [PortTarget] {
        [.local] + profiles.filter(\.isEnabled).sorted(by: profileSort).map(PortTarget.remote)
    }

    private func profileSort(_ lhs: RemoteServerProfile, _ rhs: RemoteServerProfile) -> Bool {
        let l = lhs.displayName.folding(options: .caseInsensitive, locale: nil)
        let r = rhs.displayName.folding(options: .caseInsensitive, locale: nil)
        return l == r ? lhs.id.uuidString < rhs.id.uuidString : l < r
    }

    var targetStatusText: String {
        if !isRemoteTarget {
            if isScanning && !hasSnapshot { return "Scanning This Mac…" }
            if isScanning { return "Refreshing…" }
            return "Local inspection"
        }
        if isScanning && !hasSnapshot { return "Connecting over SSH…" }
        if isScanning { return isStale ? "Reconnecting… · showing in-memory results" : "Refreshing…" }
        if let remoteFailure {
            var message = remoteFailure.userMessage + (hasSnapshot ? " Showing last results." : "")
            if let nextRetrySeconds { message += " Retrying in " + String(nextRetrySeconds) + "s." }
            return message
        }
        if hasSnapshot { return "Available over SSH · updated just now" }
        return "Ready to connect"
    }

    func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
        sessionGeneration &+= 1
        cancelRemoteWorkAndClearState()
        scheduleTask?.cancel()
        scheduleTask = nil
        nextRetrySeconds = nil
        if presented {
            connectionsExpanded = false
            refreshProfiles()
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
            cancelRemoteWorkAndClearState()
            if selectedTarget.isRemote {
                selectedTarget = .local
                activeScanner = localScanner
                publishSelectedTargetState()
            }
            scanTask?.cancel()
            let scanner = activeScanner
            Task { await scanner?.cancelActiveWork() }
        }
    }

    func selectTarget(_ target: PortTarget) {
        switchTarget(target)
    }

    func refreshProfiles() {
        guard let profileStore else { return }
        profiles = profileStore.profiles
        if case let .remote(current) = selectedTarget,
           let replacement = profiles.first(where: { $0.id == current.id && $0.isEnabled }) {
            guard replacement != current else { return }
            cancelRemoteWorkAndClearState()
            selectedTarget = .remote(replacement)
            sessionGeneration &+= 1
            activeScanner = scanner(for: selectedTarget)
            publishSelectedTargetState()
            if isPresented {
                // Editing a profile invalidates the old scan, but saving the
                // new details must not create an implicit SSH connection.
                // The existing scheduled refresh (or the next explicit
                // refresh) will use the replacement scanner.
                pendingRefresh = false
                pendingManualRefresh = false
                isManualRefreshing = false
                if scanToken == nil && scheduleTask == nil {
                    scheduleNext(after: .seconds(2))
                }
            }
        } else if selectedTarget.isRemote {
            switchTarget(.local, bypassPicker: true)
        }
    }

    func saveProfile(_ profile: RemoteServerProfile) throws {
        guard let profileStore else { return }
        try profileStore.save(profile)
        refreshProfiles()
    }

    func setProfileEnabled(id: UUID, enabled: Bool) throws {
        guard let existing = profiles.first(where: { $0.id == id }) else { return }
        if !enabled, activeConnectionTestProfileID == id { cancelActiveConnectionTest() }
        var updated = existing
        updated.isEnabled = enabled
        try saveProfile(updated)
    }

    func deleteProfile(id: UUID) {
        if activeConnectionTestProfileID == id { cancelActiveConnectionTest() }
        profileStore?.delete(id: id)
        refreshProfiles()
    }

    func testConnection(for profile: RemoteServerProfile) async -> RemoteConnectionTestResult {
        guard profile.isEnabled else { return .refusedDisabled }
        let requiresSavedAuthorization = profileStore?.profiles.contains(where: { $0.id == profile.id }) ?? false
        while !canStartConnectionTest(for: profile, requiresSavedAuthorization: requiresSavedAuthorization) {
            guard profileAuthorization(for: profile, requiresSavedAuthorization: requiresSavedAuthorization) else {
                return .refusedDisabled
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return profileAuthorization(for: profile, requiresSavedAuthorization: requiresSavedAuthorization)
                    ? .failed(.cancelled) : .refusedDisabled
            }
        }
        guard profileAuthorization(for: profile, requiresSavedAuthorization: requiresSavedAuthorization), !Task.isCancelled else {
            return profileAuthorization(for: profile, requiresSavedAuthorization: requiresSavedAuthorization)
                ? .failed(.cancelled) : .refusedDisabled
        }

        let scanner = remoteScannerFactory?(profile) ?? localScanner
        connectionTestActive = true
        activeConnectionTestProfileID = profile.id
        activeConnectionTestScanner = scanner
        defer {
            connectionTestActive = false
            activeConnectionTestProfileID = nil
            activeConnectionTestScanner = nil
            drainPendingRefreshIfPossible()
        }

        let request = PortScanRequest(targetID: .remote(profileID: profile.id), sessionGeneration: 0,
                                      scanGeneration: 0, trigger: .manual)
        let outcome = await withTaskCancellationHandler {
            await scanner.scan(request)
        } onCancel: {
            Task { await scanner.cancelActiveWork() }
        }
        guard profileAuthorization(for: profile, requiresSavedAuthorization: requiresSavedAuthorization) else {
            return .refusedDisabled
        }
        if Task.isCancelled { return .failed(.cancelled) }
        switch outcome {
        case .success: return .success
        case let .failure(_, _, error, _):
            if case let .remote(failure) = error { return .failed(failure) }
            return .failed(.readFailed)
        case .cancelled: return .failed(.cancelled)
        }
    }

    private func canStartConnectionTest(
        for profile: RemoteServerProfile,
        requiresSavedAuthorization: Bool
    ) -> Bool {
        !connectionTestActive
            && scanToken == nil
            && activeTerminationIdentity == nil
            && activeRemoteTerminationKey == nil
            && forceKillPrompt == nil
            && profileAuthorization(for: profile, requiresSavedAuthorization: requiresSavedAuthorization)
    }

    private func cancelActiveConnectionTest() {
        guard connectionTestActive, let scanner = activeConnectionTestScanner else { return }
        Task { await scanner.cancelActiveWork() }
    }

    private func profileAuthorization(
        for profile: RemoteServerProfile,
        requiresSavedAuthorization: Bool = false
    ) -> Bool {
        guard profile.isEnabled else { return false }
        guard let profileStore else { return true }
        guard let saved = profileStore.profiles.first(where: { $0.id == profile.id }) else {
            return !requiresSavedAuthorization
        }
        return saved.isEnabled
    }

    private func switchTarget(_ target: PortTarget, bypassPicker: Bool = false) {
        guard target != selectedTarget,
              (bypassPicker || !isTargetPickerDisabled),
              availableTargets.contains(target) else { return }
        sessionGeneration &+= 1
        cancelRemoteWorkAndClearState()
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
        if let identity = row.localIdentity { return terminationStates[identity] }
        guard row.isRemote, let key = remoteTerminationKey(for: row) else { return nil }
        return remoteTerminationState(for: row, key: key)
    }

    func isOwnProcess(_ row: PortProcess) -> Bool { row.localIdentity?.pid == ownPID }

    func isTerminationDisabled(for row: PortProcess) -> Bool {
        if row.isRemote {
            guard row.isActionable, isRemoteTarget, let key = remoteTerminationKey(for: row) else { return true }
            if case .inProgress? = remoteTerminationState(for: row, key: key) { return true }
            return connectionTestActive || activeRemoteTerminationKey != nil || activeTerminationIdentity != nil
        }
        guard let identity = row.localIdentity, identity.pid != ownPID else { return true }
        if case .inProgress? = terminationStates[identity] { return true }
        if let activeTerminationIdentity, activeTerminationIdentity != identity { return true }
        return connectionTestActive
    }

    func requestStop(for row: PortProcess) {
        if row.isRemote {
            guard row.isActionable else { return }
            requestRemoteStop(for: row)
            return
        }
        guard isPresented, let identity = row.localIdentity, identity.pid != ownPID,
              !connectionTestActive, activeTerminationIdentity == nil, activeRemoteTerminationKey == nil else { return }
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
        if row.isRemote {
            guard row.isActionable, isPresented, let key = remoteTerminationKey(for: row), remoteTerminationState(for: row, key: key) == .forceKillAvailable,
                  !connectionTestActive, activeRemoteTerminationKey == nil, activeTerminationIdentity == nil else { return }
            forceKillPrompt = row
            return
        }
        guard isPresented, let identity = row.localIdentity, terminationStates[identity] == .forceKillAvailable,
              !connectionTestActive, activeTerminationIdentity == nil, activeRemoteTerminationKey == nil else { return }
        forceKillPrompt = row
    }

    func cancelForceKillPrompt() { forceKillPrompt = nil }

    func confirmForceKill() {
        if let row = forceKillPrompt, row.isRemote { confirmRemoteForceKill(row); return }
        guard let row = forceKillPrompt, let identity = row.localIdentity,
              terminationStates[identity] == .forceKillAvailable,
              !connectionTestActive, activeTerminationIdentity == nil, activeRemoteTerminationKey == nil else {
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

    private func remoteTerminationKey(for row: PortProcess) -> String? {
        guard case let .remote(targetID, pid) = row.origin, pid ?? 0 > 0,
              targetID == selectedTarget.id else { return nil }
        return "\(targetID.rawValue)|\(row.id)"
    }

    private func selectedRemoteProfile() -> RemoteServerProfile? {
        guard case let .remote(profile) = selectedTarget,
              profile.isEnabled,
              profiles.contains(where: { $0.id == profile.id && $0.isEnabled }) else { return nil }
        return profile
    }

    private func requestRemoteStop(for row: PortProcess) {
        guard isPresented, let profile = selectedRemoteProfile(), let key = remoteTerminationKey(for: row),
              !connectionTestActive, activeRemoteTerminationKey == nil, activeTerminationIdentity == nil else { return }
        guard let terminator = remoteTerminatorFactory?(profile) else { return }
        pendingRefresh = true
        cancelActiveScan()
        activeRemoteTerminationKey = key
        let token = UUID()
        terminationToken = token
        setRemoteTerminationState(.inProgress, for: row, key: key)
        let targetID = selectedTarget.id
        terminationTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForScanToFinish()
            guard !Task.isCancelled else { self.finishRemoteTermination(.cancelled, key: key, token: token); return }
            self.finishRemoteTermination(await terminator.stop(row: row), key: key, token: token, targetID: targetID)
        }
    }

    private func confirmRemoteForceKill(_ row: PortProcess) {
        guard row.isActionable, let profile = selectedRemoteProfile(), let key = remoteTerminationKey(for: row),
              remoteTerminationState(for: row, key: key) == .forceKillAvailable, !connectionTestActive,
              activeRemoteTerminationKey == nil else { return }
        guard let terminator = remoteTerminatorFactory?(profile) else { return }
        forceKillPrompt = nil
        pendingRefresh = true
        cancelActiveScan()
        activeRemoteTerminationKey = key
        let token = UUID()
        terminationToken = token
        setRemoteTerminationState(.inProgress, for: row, key: key)
        let targetID = selectedTarget.id
        terminationTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForScanToFinish()
            guard !Task.isCancelled else { self.finishRemoteTermination(.cancelled, key: key, token: token); return }
            self.finishRemoteTermination(await terminator.forceKill(row: row), key: key, token: token, targetID: targetID)
        }
    }

    private func finishRemoteTermination(_ outcome: TerminationOutcome, key: String, token: UUID, targetID: PortTargetID? = nil) {
        guard terminationToken == token, activeRemoteTerminationKey == key,
              targetID == nil || targetID == selectedTarget.id else { return }
        terminationTask = nil; terminationToken = nil; activeRemoteTerminationKey = nil
        switch outcome {
        case .exited: removeRemoteTerminationState(forKey: key); if isPresented { pendingRefresh = true }
        case .forceKillAvailable:
            if let row = remoteTerminationRows[key] { setRemoteTerminationState(.forceKillAvailable, for: row, key: key) }
        case let .failed(error):
            if let row = remoteTerminationRows[key] { setRemoteTerminationState(.failed(error), for: row, key: key) }
            if isPresented { pendingRefresh = true }
        case .cancelled: removeRemoteTerminationState(forKey: key)
        }
        drainPendingRefreshIfPossible()
    }

    private func cancelRemoteWorkAndClearState() {
        cancelActiveConnectionTest()
        if selectedTarget.isRemote {
            cancelActiveScan()
            if activeRemoteTerminationKey != nil {
                terminationTask?.cancel()
                terminationTask = nil
                terminationToken = nil
                activeRemoteTerminationKey = nil
            }
        }
        remoteTerminationStates.removeAll()
        remoteTerminationRows.removeAll()
        forceKillPrompt = nil
    }

    func quitApplication() {
        guard !quitRequested else { return }
        quitRequested = true
        sessionGeneration &+= 1
        scheduleTask?.cancel()
        nextRetrySeconds = nil
        scanTask?.cancel()
        terminationTask?.cancel()
        cancelActiveConnectionTest()
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
        case let .remote(profile): remoteScannerFactory?(profile) ?? localScanner
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
              !connectionTestActive,
              activeTerminationIdentity == nil, activeRemoteTerminationKey == nil, scanToken == nil else { return }
        pendingRefresh = false
        let manual = pendingManualRefresh
        pendingManualRefresh = false
        startScan(isManual: manual, trigger: manual ? .manual : trigger)
    }

    private func startScan(isManual: Bool, trigger: ScanTrigger) {
        guard isPresented, !quitRequested, !connectionTestActive,
              activeTerminationIdentity == nil, activeRemoteTerminationKey == nil, scanToken == nil else { return }
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
                clearTerminationStatesForMissingRows(in: targeted.snapshot, targetID: request.targetID)
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

    private func clearTerminationStatesForMissingRows(in snapshot: PortSnapshot, targetID: PortTargetID) {
        guard targetID == .local else {
            let currentRows = snapshot.allRows.reduce(into: [String: PortProcess]()) { rows, row in
                guard row.isRemote, case let .remote(rowTargetID, pid) = row.origin,
                      pid ?? 0 > 0, rowTargetID == targetID else { return }
                rows["\(targetID.rawValue)|\(row.id)"] = row
            }
            for key in remoteTerminationStates.keys {
                guard let current = currentRows[key], let terminated = remoteTerminationRows[key],
                      equivalentRemoteTerminationIdentity(current, terminated) else {
                    removeRemoteTerminationState(forKey: key)
                    continue
                }
            }
            if let prompt = forceKillPrompt, prompt.isRemote {
                guard let promptKey = remoteTerminationKey(for: prompt),
                      let current = currentRows[promptKey],
                      let terminated = remoteTerminationRows[promptKey],
                      equivalentRemoteTerminationIdentity(prompt, terminated),
                      equivalentRemoteTerminationIdentity(current, terminated) else {
                    forceKillPrompt = nil
                    return
                }
            }
            return
        }
        let identities = Set(snapshot.allRows.compactMap(\.localIdentity))
        terminationStates = terminationStates.filter { identities.contains($0.key) }
        if let promptIdentity = forceKillPrompt?.localIdentity, !identities.contains(promptIdentity) { forceKillPrompt = nil }
    }

    private func remoteTerminationState(for row: PortProcess, key: String) -> TerminationUIState? {
        guard let terminated = remoteTerminationRows[key], equivalentRemoteTerminationIdentity(row, terminated) else {
            return nil
        }
        return remoteTerminationStates[key]
    }

    private func setRemoteTerminationState(_ state: TerminationUIState, for row: PortProcess, key: String) {
        remoteTerminationRows[key] = row
        remoteTerminationStates[key] = state
    }

    private func removeRemoteTerminationState(forKey key: String) {
        remoteTerminationStates.removeValue(forKey: key)
        remoteTerminationRows.removeValue(forKey: key)
    }

    /// Docker row IDs may survive a process/socket replacement. Ignore the
    /// stable row ID and compare the complete remote termination identity.
    private func equivalentRemoteTerminationIdentity(_ lhs: PortProcess, _ rhs: PortProcess) -> Bool {
        lhs.isRemote && rhs.isRemote && lhs.origin == rhs.origin
            && lhs.localPorts == rhs.localPorts && lhs.transports == rhs.transports
            && lhs.processName == rhs.processName && lhs.endpoints == rhs.endpoints
            && lhs.activityKind == rhs.activityKind
            && lhs.remoteSocketIdentity == rhs.remoteSocketIdentity
    }
}
