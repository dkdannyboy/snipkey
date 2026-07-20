import XCTest
@testable import SnipKeyKit

final class RunningAppCheckTests: XCTestCase {
    func testDetectsByBundleID() {
        XCTAssertTrue(RunningAppCheck.isTextExpander(bundleID: "com.smileonmymac.textexpander", name: nil))
        XCTAssertTrue(RunningAppCheck.isTextExpander(bundleID: "com.textexpander.TextExpanderApp", name: nil))
        XCTAssertTrue(RunningAppCheck.isTextExpander(bundleID: "com.SmileOnMyMac.TextExpander", name: nil))
    }
    func testDetectsByName() {
        XCTAssertTrue(RunningAppCheck.isTextExpander(bundleID: "com.unknown.x", name: "TextExpander"))
    }
    func testIgnoresUnrelatedApps() {
        XCTAssertFalse(RunningAppCheck.isTextExpander(bundleID: "io.snipkey.mac", name: "SnipKey"))
        XCTAssertFalse(RunningAppCheck.isTextExpander(bundleID: "com.apple.TextEdit", name: "TextEdit"))
        XCTAssertFalse(RunningAppCheck.isTextExpander(bundleID: nil, name: nil))
    }
}
