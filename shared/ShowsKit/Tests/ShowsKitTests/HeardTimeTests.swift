// Regression guard: BUG-12 (the native player's transcript lit each word at the player's position, which Bluetooth
// headphones play ~0.2 s later: the words ran ahead of the voice, owner 11-14 "its not exactly time synced").
// Regression guard: BUG-24 (three heard-time formulas, and the iOS one ignored the player's speed: at 1.5× a 0.2 s
// route holds back 0.3 s of the file, so the light ran 0.1 s ahead of the voice).
import XCTest
@testable import ShowsKit

final class HeardTimeTests: XCTestCase {
    func testPlayingSubtractsTheRoutesLatency() {
        XCTAssertEqual(TranscriptLight.heard(position: 10, latency: 0.2, playing: true), 9.8, accuracy: 1e-9)
    }
    func testNeverBeforeTheStart() {
        XCTAssertEqual(TranscriptLight.heard(position: 0.1, latency: 0.2, playing: true), 0)
    }
    func testPausedIsThePosition() {
        XCTAssertEqual(TranscriptLight.heard(position: 10, latency: 0.2, playing: false), 10)
        XCTAssertEqual(TranscriptLight.heard(position: 10, rate: 0, latency: 0.2, playing: false), 10)
    }
    func testLatencyIsClampedToOneSecond() {
        XCTAssertEqual(TranscriptLight.heard(position: 10, latency: -0.5, playing: true), 10)
        XCTAssertEqual(TranscriptLight.heard(position: 10, latency: 3, playing: true), 9)
    }
    func testTheLatencyIsScaledByThePlayersSpeed() {
        XCTAssertEqual(TranscriptLight.heard(position: 10, rate: 1.5, latency: 0.2, playing: true), 9.7, accuracy: 1e-9)
        XCTAssertEqual(TranscriptLight.heard(position: 10, rate: 0.5, latency: 0.2, playing: true), 9.9, accuracy: 1e-9)
    }
    func testTheFramesLeadIsScaledByThePlayersSpeedToo() {
        // the transcript view's FrameClock lead (one refresh, 16.7 ms) at 2×: 33.3 ms of the file
        XCTAssertEqual(TranscriptLight.heard(position: 10, rate: 2, latency: 0, ahead: 1.0 / 60, playing: true), 10 + 2.0 / 60, accuracy: 1e-9)
        // paused: the lead still reads ahead (the view passes 0 when it isn't ticking), at speed 1
        XCTAssertEqual(TranscriptLight.heard(position: 10, rate: 0, latency: 0.2, ahead: 0.05, playing: false), 10.05, accuracy: 1e-9)
    }
    func testTheMacsOverlayIsTheSameRule() {
        // strip/recense.swift: smoothTime() + (syncOffset − chain latency + frame lead) × rate, before `shift`
        let pos = 42.0, rate = 1.25, chain = 0.03, offset = -0.1, lead = 0.012
        XCTAssertEqual(TranscriptLight.heard(position: pos, rate: rate, latency: chain, ahead: offset + lead, playing: true),
                       pos + (offset - chain + lead) * rate, accuracy: 1e-9)
    }
    func testTheMacsOverlayPausedKeepsItsOffsetButNotTheChainsLatency() {
        // BUG-24 review 8: paused (expectPaused or pos.paused), nothing is in flight through EQ/Key/Space, so the chain's
        // latency is not subtracted; the sync offset and frame lead still read ahead, at speed 1 (the rate reads 0)
        let pos = 42.0, chain = 0.03, offset = -0.1, lead = 0.012
        XCTAssertEqual(TranscriptLight.heard(position: pos, rate: 0, latency: chain, ahead: offset + lead, playing: false),
                       pos + offset + lead, accuracy: 1e-9)
    }
}
