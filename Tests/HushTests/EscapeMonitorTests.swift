import XCTest
@testable import Hush

final class EscapeMonitorTests: XCTestCase {
    func testOnlyKeyCode53IsEscape() {
        XCTAssertTrue(EscapeMonitor.isEscape(keyCode: 53))
        XCTAssertFalse(EscapeMonitor.isEscape(keyCode: 6))   // z
        XCTAssertFalse(EscapeMonitor.isEscape(keyCode: 36))  // return
    }
}
