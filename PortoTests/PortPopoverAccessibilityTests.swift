import XCTest
@testable import Porto

final class PortPopoverAccessibilityTests: XCTestCase {
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
