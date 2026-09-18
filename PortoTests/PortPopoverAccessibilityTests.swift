import XCTest
@testable import Porto

@MainActor
final class PortPopoverAccessibilityTests: XCTestCase {
    func testPopoverUsesApprovedCompactWidth() {
        XCTAssertEqual(PortPopoverView.popoverWidth, 300)
    }

    func testTargetPickerLeavesTrailingActionsTogether() {
        XCTAssertEqual(PortPopoverView.targetSelectorWidth, 180)
    }

    func testRefreshingUsesAStableNativeProgressPresentation() {
        XCTAssertEqual(
            refreshIndicatorPresentation(isManualRefreshing: true, reduceMotion: false),
            .progress
        )
    }

    func testRefreshIndicatorUsesTheArrowWhenIdleOrMotionIsReduced() {
        XCTAssertEqual(
            refreshIndicatorPresentation(isManualRefreshing: false, reduceMotion: false),
            .arrow
        )
        XCTAssertEqual(
            refreshIndicatorPresentation(isManualRefreshing: true, reduceMotion: true),
            .arrow
        )
    }

    func testConnectionsAccessibilityLabelForCollapsedSection() {
        XCTAssertEqual(
            connectionsAccessibilityLabel(connectionCount: 3, isExpanded: false),
            "Connections, 3, collapsed"
        )
    }

    func testConnectionsAccessibilityLabelForExpandedSection() {
        XCTAssertEqual(
            connectionsAccessibilityLabel(connectionCount: 3, isExpanded: true),
            "Connections, 3, expanded"
        )
    }

    func testProcessRowCanBeConstructedFromExplicitRenderingAndActionInputs() {
        let row = PortProcess(
            id: "listener",
            origin: .localUnverified(pid: 42),
            localPort: 8080,
            transport: .tcp,
            processName: "Example",
            endpoints: [],
            activityKind: .listener
        )
        var stopCalled = false
        var forceKillCalled = false

        let processRow = PortProcessRow(
            row: row,
            targetDisplayName: "This Mac",
            terminationState: .forceKillAvailable,
            isOwnProcess: false,
            isTerminationDisabled: false,
            onStop: { stopCalled = true },
            onForceKill: { forceKillCalled = true }
        )

        XCTAssertEqual(processRow.row, row)
        XCTAssertEqual(processRow.targetDisplayName, "This Mac")
        XCTAssertEqual(processRow.terminationState, .forceKillAvailable)
        XCTAssertFalse(processRow.isOwnProcess)
        XCTAssertFalse(processRow.isTerminationDisabled)
        processRow.onStop()
        processRow.onForceKill()
        XCTAssertTrue(stopCalled)
        XCTAssertTrue(forceKillCalled)
    }
}
