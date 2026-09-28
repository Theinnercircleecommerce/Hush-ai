import XCTest
@testable import Hush

final class BrainShellTests: XCTestCase {
    func testRequestShape() throws {
        let c = BerriesConnection(port: 4321, token: "tok", chatTitle: "Berrie", projectPath: "", appName: "Berrie")
        let req = try XCTUnwrap(BrainShell.request(path: "/shell", body: ["quit": true], connection: c))
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:4321/shell")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Bool]
        XCTAssertEqual(body, ["quit": true])
    }
}
