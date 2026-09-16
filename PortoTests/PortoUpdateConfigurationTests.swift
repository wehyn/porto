import Foundation
import XCTest

final class PortoUpdateConfigurationTests: XCTestCase {
    func testSourceInfoPlistContainsSparkleUpdateContract() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Porto/Resources/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["SUFeedURL"] as? String, "https://github.com/wehyn/porto/releases/latest/download/appcast.xml")
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUScheduledCheckInterval"] as? Int, 86_400)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(plist["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(plist["SUVerifyUpdateBeforeExtraction"] as? Bool, true)

        let publicKey = try XCTUnwrap(plist["SUPublicEDKey"] as? String)
        XCTAssertFalse(publicKey.isEmpty)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)

        let feedURL = try XCTUnwrap(URL(string: try XCTUnwrap(plist["SUFeedURL"] as? String)))
        XCTAssertEqual(feedURL.scheme, "https")
        XCTAssertEqual(feedURL.host, "github.com")
        XCTAssertEqual(feedURL.path, "/wehyn/porto/releases/latest/download/appcast.xml")
    }
}
