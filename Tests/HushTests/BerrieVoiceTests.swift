import XCTest
@testable import Hush

final class BerrieVoiceTests: XCTestCase {
    func testSpeakRequestShape() throws {
        let c = BerriesConnection(port: 4321, token: "tok", chatTitle: "Berrie", projectPath: "", appName: "Berrie")
        let req = try XCTUnwrap(SpeechOutputService.berrieSpeakRequest(text: "hi there", connection: c))
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:4321/speak")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["text": "hi there"])
        XCTAssertEqual(req.timeoutInterval, 20)
    }

    func testOpenAIRequestCarriesStyle() throws {
        let req = SpeechOutputService.openAISpeechRequest(text: "hello", voice: "onyx", style: " Russian accent ", apiKey: "k")
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: String]
        XCTAssertEqual(body?["voice"], "onyx")
        XCTAssertEqual(body?["input"], "hello")
        XCTAssertEqual(body?["instructions"], "Russian accent")
    }

    func testOpenAIRequestOmitsEmptyStyle() throws {
        let req = SpeechOutputService.openAISpeechRequest(text: "hello", voice: "onyx", style: "  ", apiKey: "k")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: String]
        XCTAssertNil(body?["instructions"])
    }
}
