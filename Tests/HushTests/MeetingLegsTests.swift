import XCTest
@testable import Hush

final class MeetingLegsTests: XCTestCase {

    private let micURL = URL(fileURLWithPath: "/tmp/mic.caf")
    private let sysURL = URL(fileURLWithPath: "/tmp/sys.caf")

    func testBothPresent() {
        XCTAssertEqual(MeetingLegs.from(mic: micURL, system: sysURL),
                       .both(mic: micURL, system: sysURL))
        XCTAssertNil(MeetingLegs.from(mic: micURL, system: sysURL).warningAfterSave)
    }

    func testMicOnlyStillSaves() {
        let legs = MeetingLegs.from(mic: micURL, system: nil)
        XCTAssertEqual(legs, .micOnly(micURL))
        XCTAssertEqual(legs.warningAfterSave, "saved — no system audio was captured")
    }

    func testSystemOnlyStillSaves() {
        let legs = MeetingLegs.from(mic: nil, system: sysURL)
        XCTAssertEqual(legs, .systemOnly(sysURL))
        XCTAssertEqual(legs.warningAfterSave, "saved — no mic audio was captured")
    }

    func testNothingCaptured() {
        XCTAssertEqual(MeetingLegs.from(mic: nil, system: nil), .neither)
    }
}
