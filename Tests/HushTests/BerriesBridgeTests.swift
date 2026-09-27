import XCTest
@testable import Hush

final class BerriesBridgeTests: XCTestCase {

    private func json(_ obj: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: obj)
    }

    func testBerrieBrainHandshakeParses() {
        let c = BerriesBridge.parseHandshake(
            json(["connected": true, "port": 51234, "token": "abc", "app": "Mira", "version": "1.26.0"]),
            appName: "Berrie")
        XCTAssertEqual(c?.port, 51234)
        XCTAssertEqual(c?.token, "abc")
        XCTAssertEqual(c?.appName, "Berrie")
        XCTAssertEqual(c?.chatTitle, "Berrie")
    }

    func testBerriesCodeHandshakeKeepsChatTitle() {
        let c = BerriesBridge.parseHandshake(
            json(["connected": true, "port": 1, "token": "t", "chat": "Fix login", "project": "/p"]),
            appName: "Berries Code")
        XCTAssertEqual(c?.chatTitle, "Fix login")
        XCTAssertEqual(c?.projectPath, "/p")
    }

    func testDisconnectedHandshakeIsNil() {
        XCTAssertNil(BerriesBridge.parseHandshake(json(["connected": false]), appName: "Berrie"))
    }

    func testMissingTokenIsNil() {
        XCTAssertNil(BerriesBridge.parseHandshake(json(["connected": true, "port": 5]), appName: "Berrie"))
    }

    func testGarbageIsNil() {
        XCTAssertNil(BerriesBridge.parseHandshake(Data("nope".utf8), appName: "Berrie"))
    }
}
