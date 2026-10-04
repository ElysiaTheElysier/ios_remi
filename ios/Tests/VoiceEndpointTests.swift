import XCTest
@testable import Remi

final class VoiceEndpointTests: XCTestCase {
    func testSilenceWithoutCommandDoesNotUpload() {
        var gate = VoiceEndpoint()
        XCTAssertEqual(gate.evaluate(elapsed: 1, db: -80), .wait)
        XCTAssertEqual(gate.evaluate(elapsed: 8, db: -80), .empty)
    }
    func testSpeechFollowedByPauseSubmitsOnce() {
        var gate = VoiceEndpoint()
        XCTAssertEqual(gate.evaluate(elapsed: 1, db: -20), .wait)
        XCTAssertEqual(gate.evaluate(elapsed: 2, db: -80), .wait)
        XCTAssertEqual(gate.evaluate(elapsed: 2.5, db: -80), .submit)
    }
    func testContinuousSoundHasThirtySecondLimit() {
        var gate = VoiceEndpoint()
        XCTAssertEqual(gate.evaluate(elapsed: 1, db: -20), .wait)
        XCTAssertEqual(gate.evaluate(elapsed: 30, db: -20), .submit)
    }
    func testInitialWakeTransitionNoiseIsIgnored() {
        var gate = VoiceEndpoint()
        XCTAssertEqual(gate.evaluate(elapsed: 0.2, db: -10), .wait)
        XCTAssertEqual(gate.evaluate(elapsed: 8, db: -80), .empty)
    }
}
