import XCTest
import PlanariumDomain
@testable import PlanariumRuntime

final class HostMusicalClockTests: XCTestCase {
    func testExternalStartAgainMarksPositionResetWhileTicksDoNotReplayTransportChange() {
        let clock = HostMusicalClock()
        clock.configure(.receive, documentTempo: 120, at: 10)
        clock.updateExternal(tempo: 120, beat: 0, at: 10, playing: true, resetPosition: true)
        let first = clock.snapshot.transport
        clock.updateExternal(tempo: 120, beat: 1, at: 10.5, playing: true)
        XCTAssertEqual(clock.snapshot.transport, first)
        clock.updateExternal(tempo: 120, beat: 0, at: 10.6, playing: true, resetPosition: true)
        XCTAssertEqual(clock.snapshot.transport, first + 1)
        XCTAssertEqual(clock.snapshot.beat, 0)
        clock.updateExternal(tempo: 120, beat: 1.0 / 24, at: 10.6 + 1.0 / 48, playing: true)
        XCTAssertEqual(clock.snapshot.transport, first + 1)
    }
    func testFutureTempoBoundaryKeepsPreviousTempoAndPositionAcrossRepeatedReplanning() {
        let clock = HostMusicalClock()
        clock.configure(.send, documentTempo: 120, at: 10)
        clock.updateInternal(tempo: 120, at: 10, playing: true, reset: true)
        clock.updateInternal(tempo: 90, at: 10.5, observedAt: 10.49)
        XCTAssertEqual(clock.snapshot.beat, 1, accuracy: 1e-10)
        XCTAssertEqual(clock.snapshot.previousTempo, 120)
        clock.updateInternal(tempo: 150, at: 10.5, observedAt: 10.49)
        XCTAssertEqual(clock.snapshot.beat, 1, accuracy: 1e-10)
        XCTAssertEqual(clock.snapshot.previousTempo, 120)
        clock.updateInternal(tempo: 150, at: 11, playing: false)
        XCTAssertEqual(clock.snapshot.beat, 2.25, accuracy: 1e-10)
        XCTAssertEqual(clock.snapshot.moving, 0)
    }
    func testDirectionRejectsOldSourceAndOffDeliversDocumentTempoWithStoppedTransport() {
        let clock = HostMusicalClock()
        clock.configure(.receive, documentTempo: 100, at: 10)
        clock.updateExternal(tempo: 140, beat: 4, at: 10, playing: true)
        clock.updateInternal(tempo: 50, at: 11, playing: false)
        XCTAssertEqual(clock.snapshot.tempo, 140); XCTAssertEqual(clock.snapshot.moving, 1)
        clock.configure(.off, documentTempo: 100, at: 11)
        let generation = clock.snapshot.generation
        XCTAssertEqual(clock.snapshot.tempo, 100); XCTAssertEqual(clock.snapshot.moving, 0)
        clock.updateExternal(tempo: 75, beat: 1, at: 12, playing: true)
        XCTAssertEqual(clock.snapshot.generation, generation)
        clock.updateInternal(tempo: 80, at: 12, playing: true, reset: true)
        XCTAssertEqual(clock.snapshot.tempo, 80); XCTAssertEqual(clock.snapshot.moving, 0)
        clock.configure(.send, documentTempo: 80, at: 13)
        clock.updateInternal(tempo: 80, at: 13, playing: true, reset: true)
        XCTAssertEqual(clock.snapshot.moving, 1); XCTAssertEqual(clock.snapshot.beat, 0)
    }
}
