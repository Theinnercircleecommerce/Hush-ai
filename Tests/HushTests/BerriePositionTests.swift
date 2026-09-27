import XCTest
@testable import Hush

final class BerriePositionTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let size = CGSize(width: 96, height: 96)

    func testNoSavedPositionGoesBottomRight() {
        let p = BerriePosition.resolve(saved: nil, size: size, screens: [main])
        XCTAssertEqual(p, CGPoint(x: 1512 - 96 - 24, y: 24))
    }

    func testSavedPositionOnScreenIsKept() {
        let p = BerriePosition.resolve(saved: CGPoint(x: 300, y: 400), size: size, screens: [main])
        XCTAssertEqual(p, CGPoint(x: 300, y: 400))
    }

    func testSavedPositionOffEveryScreenFallsBack() {
        let p = BerriePosition.resolve(saved: CGPoint(x: 5000, y: 5000), size: size, screens: [main])
        XCTAssertEqual(p, CGPoint(x: 1512 - 96 - 24, y: 24))
    }

    func testSavedPositionOnSecondScreenIsKept() {
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let p = BerriePosition.resolve(saved: CGPoint(x: 2000, y: 100), size: size, screens: [main, second])
        XCTAssertEqual(p, CGPoint(x: 2000, y: 100))
    }

    func testRoundTripsThroughString() {
        let s = BerriePosition.string(from: CGPoint(x: 12.5, y: 7))
        XCTAssertEqual(BerriePosition.point(from: s), CGPoint(x: 12.5, y: 7))
        XCTAssertNil(BerriePosition.point(from: "garbage"))
    }
}
