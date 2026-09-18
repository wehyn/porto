import XCTest
@testable import Porto

final class DebugPopoverLaunchConfigurationTests: XCTestCase {
    func testDebugPopoverRequiresTheExplicitLaunchFlag() {
        XCTAssertTrue(
            DebugPopoverLaunchConfiguration.isEnabled(
                environment: [DebugPopoverLaunchConfiguration.environmentKey: "1"]
            )
        )
        XCTAssertFalse(
            DebugPopoverLaunchConfiguration.isEnabled(
                environment: [DebugPopoverLaunchConfiguration.environmentKey: "true"]
            )
        )
        XCTAssertFalse(DebugPopoverLaunchConfiguration.isEnabled(environment: [:]))
    }
}
