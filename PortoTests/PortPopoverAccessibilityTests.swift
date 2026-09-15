import XCTest
@testable import Porto

final class PortPopoverAccessibilityTests: XCTestCase {
    func testPopoverUsesApprovedCompactWidth() {
        XCTAssertEqual(PortPopoverView.popoverWidth, 300)
    }

    func testTargetPickerLeavesTrailingActionsTogether() {
        XCTAssertEqual(PortPopoverView.targetSelectorWidth, 180)
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
}
