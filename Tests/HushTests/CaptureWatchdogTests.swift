import XCTest
@testable import Hush

final class CaptureWatchdogTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testNoBuffersInsideGraceIsWaiting() {
        let health = CaptureHealth(buffersDelivered: 0, lastBufferAt: nil, streamDied: false)
        XCTAssertEqual(CaptureWatchdog.verdict(health: health, startedAt: t0, now: t0.addingTimeInterval(3)),
                       .waitingForFirstBuffer)
    }

    func testNoBuffersPastGraceIsDead() {
        let health = CaptureHealth(buffersDelivered: 0, lastBufferAt: nil, streamDied: false)
        XCTAssertEqual(CaptureWatchdog.verdict(health: health, startedAt: t0, now: t0.addingTimeInterval(6)),
                       .dead("no system audio arriving — check screen recording permission"))
    }

    func testFlowingBuffersAreAlive() {
        let health = CaptureHealth(buffersDelivered: 500, lastBufferAt: t0.addingTimeInterval(59), streamDied: false)
        XCTAssertEqual(CaptureWatchdog.verdict(health: health, startedAt: t0, now: t0.addingTimeInterval(60)),
                       .alive)
    }

    func testStalledBuffersAreDead() {
        let health = CaptureHealth(buffersDelivered: 500, lastBufferAt: t0.addingTimeInterval(60), streamDied: false)
        XCTAssertEqual(CaptureWatchdog.verdict(health: health, startedAt: t0, now: t0.addingTimeInterval(71)),
                       .dead("system audio stopped mid-call"))
    }

    func testStreamDeathBeatsEverything() {
        let health = CaptureHealth(buffersDelivered: 500, lastBufferAt: t0.addingTimeInterval(60), streamDied: true)
        XCTAssertEqual(CaptureWatchdog.verdict(health: health, startedAt: t0, now: t0.addingTimeInterval(61)),
                       .dead("system audio stopped mid-call"))
    }
}
