// Regression guard: BUG-12 (the native player's transcript lit each word at the player's position, which Bluetooth
// headphones play ~0.2 s later: the words ran ahead of the voice, owner 11-14 "its not exactly time synced").
import XCTest
@testable import ShowsKit

final class HeardTimeTests: XCTestCase {
    func testPlayingSubtractsTheRoutesLatency() {
        XCTAssertEqual(TranscriptLight.heard(10, latency: 0.2, playing: true), 9.8, accuracy: 1e-9)
    }
    func testNeverBeforeTheStart() {
        XCTAssertEqual(TranscriptLight.heard(0.1, latency: 0.2, playing: true), 0)
    }
    func testPausedIsThePosition() {
        XCTAssertEqual(TranscriptLight.heard(10, latency: 0.2, playing: false), 10)
    }
    func testLatencyIsClampedToOneSecond() {
        XCTAssertEqual(TranscriptLight.heard(10, latency: -0.5, playing: true), 10)
        XCTAssertEqual(TranscriptLight.heard(10, latency: 3, playing: true), 9)
    }
}
