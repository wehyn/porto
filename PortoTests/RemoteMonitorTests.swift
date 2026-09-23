import Foundation
import XCTest
@testable import Porto

@MainActor
final class RemoteMonitorTests: XCTestCase {
    func testStartsOnThisMacAndListsOnlyEnabledProfilesAlphabetically() async throws {
        let disabled = profile(name: "Disabled", enabled: false)
        let zulu = profile(name: "Zulu", enabled: true)
        let alpha = profile(name: "alpha", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(disabled)
        try store.save(zulu)
        try store.save(alpha)

        let local = MonitorTestScanner(plans: [.success(.empty)])
        let remote = MonitorTestScanner(plans: [])
        let monitor = makeMonitor(
            store: store,
            local: local,
            remote: remote
        )
        defer { monitor.setPresented(false) }

        XCTAssertEqual(monitor.selectedTarget, .local)
        XCTAssertEqual(monitor.availableTargets.map(\.displayName), ["This Mac", "alpha", "Zulu"])

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }

        XCTAssertEqual(monitor.selectedTarget, .local)
        let remoteCount = await remote.count()
        XCTAssertEqual(remoteCount, 0)
    }

    func testSavingAndEnablingDoesNotSelectOrConnect() async throws {
        let store = InMemoryRemoteServerProfileStore()
        let local = MonitorTestScanner(plans: [.success(.empty)])
        let remote = MonitorTestScanner(plans: [])
        let monitor = makeMonitor(store: store, local: local, remote: remote)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }

        var newProfile = profile(name: "New server", enabled: false)
        try monitor.saveProfile(newProfile)
        XCTAssertEqual(monitor.selectedTarget, .local)
        var remoteCount = await remote.count()
        XCTAssertEqual(remoteCount, 0)

        newProfile.isEnabled = true
        try monitor.saveProfile(newProfile)
        XCTAssertEqual(monitor.selectedTarget, .local)
        remoteCount = await remote.count()
        XCTAssertEqual(remoteCount, 0)
    }

    func testSelectingEnabledProfileStartsOnlyThatRemoteScan() async throws {
        let alpha = profile(name: "Alpha", enabled: true)
        let beta = profile(name: "Beta", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(alpha)
        try store.save(beta)

        let local = MonitorTestScanner(plans: [.success(.empty)])
        let alphaScanner = MonitorTestScanner(plans: [.success(makeRemoteSnapshot(profile: alpha, name: "alpha-process", port: 8001, pid: 42))])
        let betaScanner = MonitorTestScanner(plans: [.success(makeRemoteSnapshot(profile: beta, name: "beta-process", port: 8002, pid: 43))])
        let monitor = makeMonitor(store: store, local: local) { profile in
            profile.id == alpha.id ? alphaScanner : betaScanner
        }
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }
        monitor.selectTarget(.remote(alpha))

        await waitUntil { await alphaScanner.count() == 1 && !monitor.isScanning }
        let betaCount = await betaScanner.count()
        XCTAssertEqual(betaCount, 0)
        XCTAssertEqual(monitor.selectedTarget, .remote(alpha))
        XCTAssertEqual(monitor.listenerRows.first?.processName, "alpha-process")
    }

    func testDisablingSelectedProfileReturnsToThisMacAndStopsTargetAvailability() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let local = MonitorTestScanner(plans: [.success(.empty), .success(.empty)])
        let remote = MonitorTestScanner(plans: [.success(makeRemoteSnapshot(profile: profile, name: "server", port: 8080, pid: 55))])
        let monitor = makeMonitor(store: store, local: local, remote: remote)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }

        try monitor.setProfileEnabled(id: profile.id, enabled: false)

        XCTAssertEqual(monitor.selectedTarget, .local)
        XCTAssertEqual(monitor.availableTargets.map(\.displayName), ["This Mac"])
        await Task.yield()
        let remoteCount = await remote.count()
        XCTAssertEqual(remoteCount, 1)
    }

    func testDeletingSelectedProfileReturnsToThisMac() async throws {
        let profile = profile(name: "Disposable", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let local = MonitorTestScanner(plans: [.success(.empty)])
        let remote = MonitorTestScanner(plans: [.success(makeRemoteSnapshot(profile: profile, name: "server", port: 8081, pid: 56))])
        let monitor = makeMonitor(store: store, local: local, remote: remote)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }

        monitor.deleteProfile(id: profile.id)

        XCTAssertEqual(monitor.selectedTarget, .local)
        XCTAssertTrue(monitor.profiles.isEmpty)
        XCTAssertEqual(monitor.availableTargets, [.local])
    }

    func testEditingSelectedProfileKeepsStableIDAndUsesNewDetails() async throws {
        let original = profile(name: "Production", host: "old.example", enabled: true)
        let updated = RemoteServerProfile(
            id: original.id,
            displayName: original.displayName,
            host: "new.example",
            username: original.username,
            port: 2200,
            identityFilePath: original.identityFilePath,
            isEnabled: true
        )
        let store = InMemoryRemoteServerProfileStore()
        try store.save(original)
        let local = MonitorTestScanner(plans: [.success(.empty)])
        let oldScanner = MonitorTestScanner(plans: [.success(makeRemoteSnapshot(profile: original, name: "old", port: 8100, pid: 60))])
        let newScanner = MonitorTestScanner(plans: [.success(makeRemoteSnapshot(profile: updated, name: "new", port: 8101, pid: 61))])
        let monitor = makeMonitor(store: store, local: local) { profile in
            profile.host == "old.example" ? oldScanner : newScanner
        }
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }
        monitor.selectTarget(.remote(original))
        await waitUntil { await oldScanner.count() == 1 && !monitor.isScanning }

        try monitor.saveProfile(updated)

        let newCountBeforeRefresh = await newScanner.count()
        XCTAssertEqual(newCountBeforeRefresh, 0)
        monitor.refresh()
        await waitUntil {
            await newScanner.count() == 1 && !monitor.isScanning
        }
        guard case let .remote(selected) = monitor.selectedTarget else {
            return XCTFail("expected the edited profile to remain selected")
        }
        XCTAssertEqual(selected.id, original.id)
        XCTAssertEqual(selected.host, "new.example")
        XCTAssertEqual(selected.port, 2200)
        XCTAssertEqual(monitor.listenerRows.first?.processName, "new")
    }

    func testDisabledTestConnectionRefusesBeforeLaunchingScanner() async throws {
        let disabled = profile(name: "Disabled", enabled: false)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(disabled)
        let scanner = MonitorTestScanner(plans: [.success(.empty)])
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: []), remote: scanner)

        let result = await monitor.testConnection(for: disabled)

        XCTAssertEqual(result, .refusedDisabled)
        let scanCount = await scanner.count()
        XCTAssertEqual(scanCount, 0)
        XCTAssertEqual(store.profiles.first?.id, disabled.id)
        XCTAssertFalse(store.profiles.first?.isEnabled ?? true)
    }

    func testDisabledTestConnectionRefusesWithoutAProfileStore() async throws {
        let scanner = NoStoreMonitorScanner()
        let monitor = PortMonitor(
            scanner: scanner,
            terminator: RecordingTerminator(),
            ownPID: 99,
            clock: NeverMonitorClock()
        )

        let result = await monitor.testConnection(for: profile(name: "Disabled", enabled: false))

        XCTAssertEqual(result, .refusedDisabled)
        let scanCount = await scanner.scanCount()
        XCTAssertEqual(scanCount, 0)
    }

    func testDraftTestConnectionInvokesScannerWithoutSavingOrEnablingDraft() async throws {
        let draft = profile(name: "New server", enabled: false)
        let store = InMemoryRemoteServerProfileStore()
        let scanner = MonitorTestScanner(plans: [.success(.empty)])
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: []), remote: scanner)

        let result = await monitor.testDraftConnection(for: draft)

        XCTAssertEqual(result, .success)
        let scanCount = await scanner.count()
        XCTAssertEqual(scanCount, 1)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertFalse(draft.isEnabled)
    }

    func testSavedDisabledDraftCanBeTestedWithoutChangingStoredEnablement() async throws {
        let draft = profile(name: "Disabled server", enabled: false)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(draft)
        let scanner = MonitorTestScanner(plans: [.success(.empty)])
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: []), remote: scanner)

        let result = await monitor.testDraftConnection(for: draft)

        XCTAssertEqual(result, .success)
        let scanCount = await scanner.count()
        XCTAssertEqual(scanCount, 1)
        XCTAssertFalse(store.profiles.first?.isEnabled ?? true)
    }

    func testTestConnectionWaitsForActiveScanBeforeStarting() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let local = DelayedMonitorScanner(snapshot: .empty)
        let remote = CancellationRecordingScanner()
        let monitor = makeMonitor(store: store, local: local, remote: remote)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.started() }
        let testTask = Task { await monitor.testConnection(for: profile) }
        try? await Task.sleep(for: .milliseconds(30))
        let startedBeforeScanFinished = await remote.started()
        XCTAssertFalse(startedBeforeScanFinished)

        await local.release()
        await waitUntil { await remote.started() }
        testTask.cancel()
        let result = await testTask.value
        XCTAssertEqual(result, .failed(.cancelled))
        let cancellationCount = await remote.cancellationCount()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testTestConnectionWaitsForActiveTerminationAndForceKillPrompt() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let rowSnapshot = makeRemoteSnapshot(profile: profile, name: "server", port: 8080, pid: 55)
        let remote = MonitorTestScanner(plans: [.success(rowSnapshot), .success(.empty)])
        let terminator = DelayedRecordingTerminator(outcome: .forceKillAvailable)
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: [.success(.empty)]), remote: remote,
                                   remoteTerminator: terminator)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await remote.count() == 0 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }
        guard let row = monitor.listenerRows.first else { return XCTFail("expected a remote row") }
        monitor.requestStop(for: row)
        await waitUntil { await terminator.started() }

        let testTask = Task { await monitor.testConnection(for: profile) }
        try? await Task.sleep(for: .milliseconds(30))
        let countWhileTerminating = await remote.count()
        XCTAssertEqual(countWhileTerminating, 1)

        await terminator.release()
        await waitUntil { monitor.terminationState(for: row) == .forceKillAvailable }
        let testResult = await testTask.value
        XCTAssertEqual(testResult, RemoteConnectionTestResult.success)
    }

    func testActiveTestConnectionCannotStartRemoteTermination() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let rowSnapshot = makeRemoteSnapshot(profile: profile, name: "server", port: 8080, pid: 55)
        let remote = DelayedMonitorScanner(snapshot: rowSnapshot)
        let remoteTerminator = RecordingTerminator()
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: [.success(.empty)]),
                                   remote: remote, remoteTerminator: remoteTerminator)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.scanCount() == 1 }
        await remote.release()
        await waitUntil { monitor.listenerRows.count == 1 && !monitor.isScanning }
        let row = try XCTUnwrap(monitor.listenerRows.first)

        let testTask = Task { await monitor.testConnection(for: profile) }
        await waitUntil { await remote.scanCount() == 2 }

        XCTAssertTrue(monitor.isTerminationDisabled(for: row))
        monitor.requestStop(for: row)
        XCTAssertNil(monitor.activeRemoteTerminationKey)
        let stopCount = await remoteTerminator.stopCount()
        XCTAssertEqual(stopCount, 0)

        await remote.release()
        let testResult = await testTask.value
        XCTAssertEqual(testResult, .success)
    }

    func testTestConnectionRechecksSavedAuthorizationWhileWaiting() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let local = DelayedMonitorScanner(snapshot: .empty)
        let remote = MonitorTestScanner(plans: [])
        let monitor = makeMonitor(store: store, local: local, remote: remote)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.started() }
        let testTask = Task { await monitor.testConnection(for: profile) }
        try? await Task.sleep(for: .milliseconds(30))
        try monitor.setProfileEnabled(id: profile.id, enabled: false)
        await local.release()

        let result = await testTask.value
        let remoteCount = await remote.count()
        XCTAssertEqual(result, .refusedDisabled)
        XCTAssertEqual(remoteCount, 0)
    }

    func testRefreshWaitsForActiveTestConnection() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let local = MonitorTestScanner(plans: [.success(.empty), .success(.empty)])
        let remote = CancellationRecordingScanner()
        let monitor = makeMonitor(store: store, local: local, remote: remote)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }
        let testTask = Task { await monitor.testConnection(for: profile) }
        await waitUntil { await remote.started() }
        monitor.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        let localCountWhileTesting = await local.count()
        XCTAssertEqual(localCountWhileTesting, 1)

        testTask.cancel()
        let result = await testTask.value
        XCTAssertEqual(result, .failed(.cancelled))
        await waitUntil { await local.count() == 2 && !monitor.isScanning }
    }

    func testTargetSwitchIsBlockedUntilActiveTestConnectionFinishes() async throws {
        let alpha = profile(name: "Alpha", enabled: true)
        let beta = profile(name: "Beta", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(alpha)
        try store.save(beta)
        let local = MonitorTestScanner(plans: [.success(.empty), .success(.empty)])
        let alphaScanner = CancellationRecordingScanner()
        let betaScanner = MonitorTestScanner(plans: [.success(.empty)])
        let monitor = makeMonitor(store: store, local: local) { profile in
            if profile.id == alpha.id {
                return alphaScanner as any PortSnapshotScanning
            }
            return betaScanner as any PortSnapshotScanning
        }
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }
        let testTask = Task { await monitor.testConnection(for: alpha) }
        await waitUntil { await alphaScanner.started() }

        monitor.selectTarget(.remote(beta))
        XCTAssertEqual(monitor.selectedTarget, .local)
        let betaCountWhileTesting = await betaScanner.count()
        XCTAssertEqual(betaCountWhileTesting, 0)

        testTask.cancel()
        let cancelledResult = await testTask.value
        XCTAssertEqual(cancelledResult, .failed(.cancelled))
        monitor.selectTarget(.remote(beta))
        await waitUntil { await betaScanner.count() == 1 && !monitor.isScanning }
    }

    func testDisablingProfileCancelsActiveTestConnection() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let scanner = CancellationRecordingScanner()
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: []), remote: scanner)

        let testTask = Task { await monitor.testConnection(for: profile) }
        await waitUntil { await scanner.started() }
        try monitor.setProfileEnabled(id: profile.id, enabled: false)

        let result = await testTask.value
        let cancellationCount = await scanner.cancellationCount()
        XCTAssertEqual(result, .refusedDisabled)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testDeletingProfileCancelsActiveTestConnection() async throws {
        let profile = profile(name: "Disposable", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let scanner = CancellationRecordingScanner()
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: []), remote: scanner)

        let testTask = Task { await monitor.testConnection(for: profile) }
        await waitUntil { await scanner.started() }
        monitor.deleteProfile(id: profile.id)

        let result = await testTask.value
        let cancellationCount = await scanner.cancellationCount()
        XCTAssertEqual(result, .refusedDisabled)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testRemoteRowsWithPIDsUseRemoteTerminatorAndMissingPIDIsDisabled() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let local = MonitorTestScanner(plans: [.success(.empty)])
        let remote = MonitorTestScanner(plans: [
            .success(makeRemoteSnapshot(profile: profile, name: "owned", port: 8200, pid: 77)),
            .success(makeRemoteSnapshot(profile: profile, name: "owned", port: 8200, pid: 77))
        ])
        let localTerminator = RecordingTerminator()
        let remoteTerminator = RecordingTerminator()
        let monitor = makeMonitor(
            store: store,
            local: local,
            remote: remote,
            localTerminator: localTerminator,
            remoteTerminator: remoteTerminator
        )
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }

        let owned = try XCTUnwrap(monitor.listenerRows.first)
        XCTAssertTrue(owned.isActionable)
        monitor.requestStop(for: owned)
        await waitUntil { await remoteTerminator.stopCount() == 1 }
        let localStopCount = await localTerminator.stopCount()
        XCTAssertEqual(localStopCount, 0)

        let missingPID = makeRemoteRow(profile: profile, name: "unknown", port: 8201, pid: nil)
        XCTAssertFalse(missingPID.isActionable)
        XCTAssertTrue(monitor.isTerminationDisabled(for: missingPID))
    }

    func testRemoteTerminationStatePublishesImmediatelyWhenNoScanIsActive() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let remote = MonitorTestScanner(plans: [
            .success(makeRemoteSnapshot(profile: profile, name: "owned", port: 8200, pid: 77)),
            .success(makeRemoteSnapshot(profile: profile, name: "owned", port: 8200, pid: 77))
        ])
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: [.success(.empty)]), remote: remote,
                                   remoteTerminator: RecordingTerminator(outcome: .forceKillAvailable))
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await remote.count() == 0 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }
        let row = try XCTUnwrap(monitor.listenerRows.first)

        monitor.requestStop(for: row)

        XCTAssertEqual(monitor.terminationState(for: row), .inProgress)
        await waitUntil { monitor.terminationState(for: row) == .forceKillAvailable }
        XCTAssertNil(monitor.activeRemoteTerminationKey)
    }

    func testRemoteTerminationStateIsSharedAcrossRowsWithTheSameProcessOwner() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let first = makeRemoteRow(profile: profile, name: "owned", port: 8200, pid: 77)
        let second = makeRemoteRow(profile: profile, name: "owned", port: 8201, pid: 77)
        let sharedSnapshot = PortSnapshot(listeners: [first, second], connections: [])
        let remote = MonitorTestScanner(plans: [.success(sharedSnapshot), .success(sharedSnapshot)])
        let terminator = RecordingTerminator(outcome: .forceKillAvailable)
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: [.success(.empty)]), remote: remote,
                                   remoteTerminator: terminator)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await remote.count() == 0 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }
        monitor.requestStop(for: first)

        await waitUntil { await terminator.stopCount() == 1 }
        XCTAssertEqual(monitor.terminationState(for: first), .forceKillAvailable)
        XCTAssertEqual(monitor.terminationState(for: second), .forceKillAvailable)
    }

    func testPIDLessDockerRowsAreActionableAndAllOwnerRowsDisappearOnExit() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let targetID = PortTargetID.remote(profileID: profile.id)
        let containerID = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let first = PortProcess(
            id: "docker-first", origin: .remote(targetID: targetID, pid: nil), localPort: 8200,
            transport: .tcp, processName: "web", endpoints: [], activityKind: .listener,
            source: .dockerContainer(containerID: containerID),
            controlTarget: .remoteDocker(targetID: targetID, containerID: containerID), isDockerPublished: true
        )
        let second = PortProcess(
            id: "docker-second", origin: .remote(targetID: targetID, pid: nil), localPort: 8201,
            transport: .tcp, processName: "web", endpoints: [], activityKind: .connection,
            source: .dockerContainer(containerID: containerID),
            controlTarget: .remoteDocker(targetID: targetID, containerID: containerID), isDockerPublished: true
        )
        let remote = MonitorTestScanner(plans: [
            .success(PortSnapshot(listeners: [first], connections: [second])),
            .success(.empty)
        ])
        let terminator = RecordingTerminator(outcome: .exited)
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: [.success(.empty)]), remote: remote,
                                   remoteTerminator: terminator)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await remote.count() == 0 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }
        XCTAssertFalse(monitor.isTerminationDisabled(for: first))
        monitor.requestStop(for: first)

        await waitUntil { await remote.count() == 2 && monitor.listenerRows.isEmpty && monitor.connectionRows.isEmpty }
        let stopCount = await terminator.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testRemoteExitRemovesLockedSiblingsButPreservesAnotherOwner() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let targetID = PortTargetID.remote(profileID: profile.id)
        let actionable = makeRemoteRow(profile: profile, name: "owned", port: 8200, pid: 77)
        let locked = PortProcess(
            id: "remote-locked", origin: .remote(targetID: targetID, pid: 77), localPort: 8201,
            transport: .tcp, processName: "owned", endpoints: [], activityKind: .connection,
            remoteSocketIdentity: nil, source: .remoteProcess,
            controlTarget: .remoteProcess(targetID: targetID, pid: 77)
        )
        let unrelated = makeRemoteRow(profile: profile, name: "other", port: 8202, pid: 78)
        let snapshot = PortSnapshot(listeners: [actionable, unrelated], connections: [locked])
        let remote = MonitorTestScanner(plans: [
            .success(snapshot),
            .success(PortSnapshot(listeners: [unrelated], connections: []))
        ])
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: [.success(.empty)]), remote: remote,
                                   remoteTerminator: RecordingTerminator(outcome: .exited))
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await remote.count() == 0 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }
        monitor.requestStop(for: actionable)

        await waitUntil { await remote.count() == 2 && !monitor.isScanning }
        XCTAssertEqual(monitor.listenerRows.map(\.id), [unrelated.id])
        XCTAssertTrue(monitor.connectionRows.isEmpty)
    }

    func testCanceledRemoteTerminationAfterStartClearsBarrierAcrossCloseAndFreshScan() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let row = makeRemoteRow(profile: profile, name: "owned", port: 8200, pid: 77)
        let remote = MonitorTestScanner(plans: [.success(PortSnapshot(listeners: [row], connections: [])), .success(.empty)])
        let terminator = DelayedRecordingTerminator(outcome: .forceKillAvailable)
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: [.success(.empty)]), remote: remote,
                                   remoteTerminator: terminator)

        monitor.setPresented(true)
        await waitUntil { await remote.count() == 0 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }
        let selectedRow = try XCTUnwrap(monitor.listenerRows.first)
        monitor.requestStop(for: selectedRow)
        await waitUntil { await terminator.started() }

        monitor.setPresented(false)
        await terminator.release()
        await waitUntil { monitor.activeRemoteTerminationKey == nil && monitor.terminationState(for: selectedRow) == nil }
        XCTAssertNil(monitor.activeRemoteTerminationKey)

        monitor.setPresented(true)
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 2 && !monitor.isScanning }
        XCTAssertEqual(monitor.selectedTarget, .remote(profile))
    }

    func testStableDockerRowIDDoesNotRetainForceKillForReplacementIdentity() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let original = makeRemoteRow(profile: profile, name: "docker-proxy", port: 8200, pid: 77,
                                     id: "docker|container-1|listener", socketIdentity: "socket-old")
        let replacement = makeRemoteRow(profile: profile, name: "docker-proxy", port: 8200, pid: 78,
                                        id: "docker|container-1|listener", socketIdentity: "socket-new")
        let remote = MonitorTestScanner(plans: [
            .success(PortSnapshot(listeners: [original], connections: [])),
            .success(PortSnapshot(listeners: [original], connections: [])),
            .success(PortSnapshot(listeners: [replacement], connections: []))
        ])
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: [.success(.empty)]),
                                   remote: remote, remoteTerminator: RecordingTerminator(outcome: .forceKillAvailable))
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await remote.count() == 0 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }
        monitor.requestStop(for: try XCTUnwrap(monitor.listenerRows.first))
        await waitUntil { await remote.count() == 2 && !monitor.isScanning }

        let originalRow = try XCTUnwrap(monitor.listenerRows.first)
        monitor.requestForceKill(for: originalRow)
        XCTAssertNotNil(monitor.forceKillPrompt)
        monitor.refresh()
        await waitUntil { await remote.count() == 3 && !monitor.isScanning }

        let current = try XCTUnwrap(monitor.listenerRows.first)
        XCTAssertNil(monitor.terminationState(for: current))
        XCTAssertNil(monitor.forceKillPrompt)
    }

    func testMissingRemoteIdentityDoesNotRetainForceKillEligibilityWhenItReappears() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let rowSnapshot = makeRemoteSnapshot(profile: profile, name: "owned", port: 8200, pid: 77)
        let remote = MonitorTestScanner(plans: [
            .success(rowSnapshot),
            .success(rowSnapshot),
            .success(.empty),
            .success(rowSnapshot)
        ])
        let monitor = makeMonitor(store: store, local: MonitorTestScanner(plans: [.success(.empty)]), remote: remote,
                                   remoteTerminator: RecordingTerminator(outcome: .forceKillAvailable))
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await remote.count() == 0 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }
        let row = try XCTUnwrap(monitor.listenerRows.first)
        monitor.requestStop(for: row)
        await waitUntil { monitor.terminationState(for: row) == .forceKillAvailable }
        await waitUntil { await remote.count() == 2 && !monitor.isScanning }
        monitor.requestForceKill(for: row)
        XCTAssertNotNil(monitor.forceKillPrompt)

        monitor.refresh()
        await waitUntil { await remote.count() == 3 && !monitor.isScanning }
        XCTAssertNil(monitor.forceKillPrompt)
        XCTAssertNil(monitor.terminationState(for: row))

        monitor.refresh()
        await waitUntil { await remote.count() == 4 && !monitor.isScanning }
        let reappeared = try XCTUnwrap(monitor.listenerRows.first)
        XCTAssertNil(monitor.terminationState(for: reappeared))
    }

    func testLateOldTargetResultCannotPublishAfterSwitch() async throws {
        let alpha = profile(name: "Alpha", enabled: true)
        let beta = profile(name: "Beta", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(alpha)
        try store.save(beta)
        let local = MonitorTestScanner(plans: [.success(.empty)])
        let delayed = DelayedMonitorScanner(snapshot: makeRemoteSnapshot(profile: alpha, name: "old", port: 8300, pid: 80))
        let betaScanner = MonitorTestScanner(plans: [.success(makeRemoteSnapshot(profile: beta, name: "new", port: 8301, pid: 81))])
        let monitor = makeMonitor(store: store, local: local) { profile in
            if profile.id == alpha.id {
                return delayed as any PortSnapshotScanning
            }
            return betaScanner as any PortSnapshotScanning
        }
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }
        monitor.selectTarget(PortTarget.remote(alpha))
        await waitUntil { await delayed.started() }
        monitor.selectTarget(PortTarget.remote(beta))
        await delayed.release()

        await waitUntil { await betaScanner.count() == 1 && !monitor.isScanning }
        XCTAssertEqual(monitor.listenerRows.first?.processName, "new")
    }

    func testClosingPopoverPreservesSelectedTargetAndCancelsRemoteWork() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let local = MonitorTestScanner(plans: [.success(.empty)])
        let remote = CancellationRecordingScanner()
        let monitor = makeMonitor(store: store, local: local, remote: remote)

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.started() }

        monitor.setPresented(false)

        XCTAssertEqual(monitor.selectedTarget, .remote(profile))
        await waitUntil { await remote.cancellationCount() == 1 }
    }

    func testReopeningDuringRemoteCancellationPreservesPresentationTrigger() async throws {
        let profile = profile(name: "Production", enabled: true)
        let store = InMemoryRemoteServerProfileStore()
        try store.save(profile)
        let local = MonitorTestScanner(plans: [.success(.empty), .success(.empty)])
        let remote = ReopenDuringCancellationScanner(plans: [
            .success(makeRemoteSnapshot(profile: profile, name: "server", port: 8080, pid: 55)),
            .failure(.remote(.hostUnreachable))
        ])
        let monitor = makeMonitor(store: store, local: local, remote: remote)

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 && !monitor.isScanning }
        monitor.selectTarget(.remote(profile))
        await waitUntil { await remote.count() == 1 }

        monitor.setPresented(false)
        monitor.setPresented(true)
        await remote.releaseFirstScan()

        await waitUntil {
            let localCount = await local.count()
            let remoteCount = await remote.count()
            return !monitor.isScanning
                && monitor.selectedTarget == .remote(profile)
                && (localCount == 2 || remoteCount == 2)
        }
        let localFollowUpTriggers = Array((await local.triggers()).dropFirst())
        let remoteFollowUpTriggers = Array((await remote.triggers()).dropFirst())
        let followUpTriggers = localFollowUpTriggers + remoteFollowUpTriggers
        XCTAssertTrue(
            followUpTriggers.contains(.presentation),
            "The refresh queued during cancellation must retain the presentation trigger."
        )
        XCTAssertEqual(monitor.selectedTarget, .remote(profile))
        monitor.setPresented(false)
    }

    private func makeMonitor(
        store: InMemoryRemoteServerProfileStore,
        local: any PortSnapshotScanning,
        remote: (any PortSnapshotScanning)? = nil,
        localTerminator: RecordingTerminator = RecordingTerminator(),
        remoteTerminator: any ProcessTerminating = RecordingTerminator(),
        factory: (@MainActor (RemoteServerProfile) -> any PortSnapshotScanning)? = nil
    ) -> PortMonitor {
        let remoteFactory: @MainActor (RemoteServerProfile) -> any PortSnapshotScanning
        if let factory {
            remoteFactory = factory
        } else {
            remoteFactory = { _ in remote ?? MonitorTestScanner(plans: []) }
        }
        return PortMonitor(
            localScanner: local,
            terminator: localTerminator,
            remoteScannerFactory: remoteFactory,
            profileStore: store,
            remoteTerminatorFactory: { _ in remoteTerminator },
            ownPID: 99,
            clock: NeverMonitorClock()
        )
    }

    private func profile(
        name: String,
        host: String = "server.example",
        enabled: Bool
    ) -> RemoteServerProfile {
        RemoteServerProfile(
            id: UUID(),
            displayName: name,
            host: host,
            username: "tester",
            isEnabled: enabled
        )
    }

    private func makeRemoteSnapshot(
        profile: RemoteServerProfile,
        name: String,
        port: Int,
        pid: Int32?
    ) -> PortSnapshot {
        PortSnapshot(listeners: [makeRemoteRow(profile: profile, name: name, port: port, pid: pid)], connections: [])
    }

    private func makeRemoteRow(
        profile: RemoteServerProfile,
        name: String,
        port: Int,
        pid: Int32?,
        id: String? = nil,
        socketIdentity: String? = nil
    ) -> PortProcess {
        PortProcess(
            id: id ?? "remote|\(profile.id.uuidString)|\(name)|\(port)|\(pid ?? 0)",
            origin: .remote(targetID: .remote(profileID: profile.id), pid: pid),
            localPort: port,
            transport: .tcp,
            processName: name,
            endpoints: [Endpoint(rawValue: "*:\(port)->*:*", localPort: port, hasRemoteEndpoint: false, socketState: "LISTEN")],
            activityKind: .listener,
            remoteSocketIdentity: socketIdentity ?? "socket-\(port)"
        )
    }

    private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct NeverMonitorClock: MonitorSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

private actor MonitorTestScanner: PortSnapshotScanning {
    enum Plan: Sendable {
        case success(PortSnapshot)
        case failure(PortScanFailure)
    }

    private var plans: [Plan]
    private var calls = 0
    private var requests: [PortScanRequest] = []

    init(plans: [Plan]) { self.plans = plans }

    func scan(_ request: PortScanRequest) async -> PortScanOutcome {
        calls += 1
        requests.append(request)
        let plan = plans.isEmpty ? .success(.empty) : plans.removeFirst()
        switch plan {
        case let .success(snapshot):
            return .success(TargetedPortSnapshot(
                targetID: request.targetID,
                sessionGeneration: request.sessionGeneration,
                snapshot: snapshot,
                diagnostics: .zero
            ))
        case let .failure(error):
            return .failure(
                targetID: request.targetID,
                sessionGeneration: request.sessionGeneration,
                error: error,
                diagnostics: .zero
            )
        }
    }

    func cancelActiveWork() async {}
    func count() -> Int { calls }
    func triggers() -> [ScanTrigger] { requests.map(\.trigger) }
}

private actor NoStoreMonitorScanner: PortScanning {
    private var calls = 0

    func scan(generation: UInt64) async -> ScanOutcome {
        calls += 1
        return .success(snapshot: .empty, diagnostics: .zero)
    }

    func validateSocket(for row: PortProcess) async -> SocketValidationResult {
        .socketMissing
    }

    func cancelActiveWork() async {}
    func scanCount() -> Int { calls }
}

private actor DelayedMonitorScanner: PortSnapshotScanning {
    private let snapshot: PortSnapshot
    private var scans = 0
    private var didStart = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(snapshot: PortSnapshot) { self.snapshot = snapshot }

    func scan(_ request: PortScanRequest) async -> PortScanOutcome {
        scans += 1
        didStart = true
        await withCheckedContinuation { continuation in self.continuation = continuation }
        return .success(TargetedPortSnapshot(
            targetID: request.targetID,
            sessionGeneration: request.sessionGeneration,
            snapshot: snapshot,
            diagnostics: .zero
        ))
    }

    func cancelActiveWork() async {}
    func scanCount() -> Int { scans }
    func started() -> Bool { didStart }
    func release() { continuation?.resume(); continuation = nil }
}

private actor CancellationRecordingScanner: PortSnapshotScanning {
    private var didStart = false
    private var cancellations = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func scan(_ request: PortScanRequest) async -> PortScanOutcome {
        didStart = true
        await withCheckedContinuation { continuation in self.continuation = continuation }
        return .cancelled
    }

    func cancelActiveWork() async {
        cancellations += 1
        continuation?.resume()
        continuation = nil
    }

    func started() -> Bool { didStart }
    func cancellationCount() -> Int { cancellations }
}

private actor ReopenDuringCancellationScanner: PortSnapshotScanning {
    enum Plan: Sendable {
        case success(PortSnapshot)
        case failure(PortScanFailure)
    }

    private var plans: [Plan]
    private var requests: [PortScanRequest] = []
    private var firstScanOutcome: PortScanOutcome?
    private var firstScanContinuation: CheckedContinuation<PortScanOutcome, Never>?

    init(plans: [Plan]) { self.plans = plans }

    func scan(_ request: PortScanRequest) async -> PortScanOutcome {
        requests.append(request)
        let plan = plans.isEmpty ? .success(.empty) : plans.removeFirst()
        let outcome = outcome(for: plan, request: request)
        guard requests.count == 1 else { return outcome }
        firstScanOutcome = outcome
        return await withCheckedContinuation { continuation in
            firstScanContinuation = continuation
        }
    }

    func cancelActiveWork() async {}

    func releaseFirstScan() {
        guard let continuation = firstScanContinuation else { return }
        firstScanContinuation = nil
        continuation.resume(returning: firstScanOutcome ?? .cancelled)
    }

    func count() -> Int { requests.count }

    func triggers() -> [ScanTrigger] { requests.map(\.trigger) }

    private func outcome(for plan: Plan, request: PortScanRequest) -> PortScanOutcome {
        switch plan {
        case let .success(snapshot):
            return .success(TargetedPortSnapshot(
                targetID: request.targetID,
                sessionGeneration: request.sessionGeneration,
                snapshot: snapshot,
                diagnostics: .zero
            ))
        case let .failure(error):
            return .failure(
                targetID: request.targetID,
                sessionGeneration: request.sessionGeneration,
                error: error,
                diagnostics: .zero
            )
        }
    }
}

private actor RecordingTerminator: ProcessTerminating {
    private var stops = 0
    private let outcome: TerminationOutcome

    init(outcome: TerminationOutcome = .cancelled) {
        self.outcome = outcome
    }

    func stop(row: PortProcess) async -> TerminationOutcome {
        stops += 1
        return outcome
    }

    func forceKill(row: PortProcess) async -> TerminationOutcome { outcome }
    func stopCount() -> Int { stops }
}

private actor DelayedRecordingTerminator: ProcessTerminating {
    private let outcome: TerminationOutcome
    private var didStart = false
    private var continuation: CheckedContinuation<TerminationOutcome, Never>?

    init(outcome: TerminationOutcome) { self.outcome = outcome }

    func stop(row: PortProcess) async -> TerminationOutcome {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func forceKill(row: PortProcess) async -> TerminationOutcome { outcome }
    func started() -> Bool { didStart }
    func release() { continuation?.resume(returning: outcome); continuation = nil }
}

private extension ScanDiagnostics {
    static let zero = ScanDiagnostics(
        stdoutBytes: 0,
        stderrBytes: 0,
        validRecords: 0,
        skippedRecords: 0,
        durationMilliseconds: 0
    )
}
