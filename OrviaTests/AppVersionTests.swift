import XCTest
@testable import Orvia

final class AppVersionTests: XCTestCase {
    func testIsNewerComparesSemanticVersions() {
        XCTAssertTrue(AppVersion.isNewer("2.0.1", than: "2.0.0"))
        XCTAssertTrue(AppVersion.isNewer("v2.1.0", than: "2.0.9"))
        XCTAssertTrue(AppVersion.isNewer("3.0.0", than: "2.9.9"))
        XCTAssertFalse(AppVersion.isNewer("2.0.0", than: "2.0.0"))
        XCTAssertFalse(AppVersion.isNewer("1.9.9", than: "2.0.0"))
        XCTAssertFalse(AppVersion.isNewer("2.0.0-beta", than: "2.0.0"))
    }
}
