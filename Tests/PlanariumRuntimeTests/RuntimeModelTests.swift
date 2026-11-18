import XCTest
import PlanariumDomain
import PlanariumRuntime

final class RuntimeModelTests: RuntimeTestCase {
    private struct Generator {
        var value: UInt64 = 0x5033_5255_4E54_494D
        mutating func index(_ count: Int) -> Int {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return Int((value >> 32) % UInt64(count))
        }
    }
    /// The model observes the physical fake boundaries, not PlayState's ledger.
    /// 4,000 seeded sequences, lengths 1...8, plus recovery from every outcome.
    func testSeededAllRuntimeInputsAndReturnGuarantee() throws {
        var generator = Generator()
        var coverage = Set<Int>()
        let recovery = try compiled(100)
        let normal = try compiled(), silent = try compiled(2, notes: false)
        let overlap = try compiled(3, transition: .overlap(milliseconds: 20))
        for sequence in 0..<4_000 {
            let clock = FakeClock(), midi = FakeBoundary(), au = FakeBoundary()
            let c = composition(clock: clock, midi: midi, au: au)
            var midiAttached = true, auAttached = true
            try start(c, instrument: normal)
            for step in 0..<(sequence % 8 + 1) {
                let action = generator.index(26)
                coverage.insert(action)
                var releases = false, retiresMIDI = false, retiresAU = false
                let oldCount = c.mailbox.read()?.processedProfiles
                let oldReceipts = (midi.receipts.count, au.receipts.count)
                switch action {
                case 0: c.runtime.frame(profile(UInt64(step + 2)))
                case 1: c.runtime.frame(profile(UInt64(step + 2), ring: 120))
                case 2: c.runtime.frame(profile(empty: true)); releases = true
                case 3: c.runtime.panic(); releases = true
                case 4: c.runtime.stop(); releases = true
                case 5: c.runtime.sleep(); releases = true
                case 6: c.runtime.wake(); releases = true
                case 7: c.runtime.sessionEnded(session); releases = true
                case 8: c.runtime.sessionBegan(session); releases = true
                case 9: c.runtime.install(silent); releases = c.mailbox.read()?.revision != silent.revision
                case 10: c.runtime.install(normal)
                case 11: c.runtime.install(overlap)
                case 12: c.runtime.detectionChanged(silent); releases = c.mailbox.read()?.revision != silent.revision
                case 13: c.runtime.roomContour(nil)
                case 14:
                    let done = expectation(description: "terminate model")
                    c.runtime.terminate { done.fulfill() }; wait(for: [done], timeout: 10)
                    releases = true
                case 15:
                    midi.result = .sent
                    let done = expectation(description: "retire MIDI model")
                    c.runtime.retire(midiID) {
                        XCTAssertTrue(midi.sounding.isEmpty, "Off must precede ack")
                        done.fulfill()
                    }
                    wait(for: [done], timeout: 10)
                    midiAttached = false; retiresMIDI = true
                case 16:
                    c.runtime.attach(RuntimePorts.midi(id: midiID, boundary: midi)); midiAttached = true
                case 17:
                    let done = expectation(description: "retire AU model")
                    c.runtime.retire(auID) { XCTAssertTrue(au.sounding.isEmpty); done.fulfill() }
                    wait(for: [done], timeout: 10)
                    auAttached = false; retiresAU = true
                case 18:
                    c.runtime.attach(RuntimePorts.audioUnit(id: auID, boundary: au)); auAttached = true
                case 19: midi.result = .faulted
                case 20: midi.result = .unbound
                case 21:
                    clock.advance(20); flush(c.runtime); flush(c.runtime); releases = true
                case 22:
                    // Consecutive queued profiles force coalescing opportunities;
                    // end is a real command between them, never a discarded item.
                    for i in 0..<20 { c.runtime.frame(profile(UInt64(100 + i))) }
                    c.runtime.sessionEnded(session)
                    c.runtime.frame(profile(200))
                    releases = true
                case 23: c.runtime.sessionBegan(other); releases = true
                case 24: c.runtime.sessionEnded(other)
                case 25:
                    c.runtime.roomContour(.init(geometry: .init(pointCount: 361,
                        angleResolutionDegrees: 0.5, startAngleDegrees: 0,
                        sourceIdentifier: "scanner:default"),
                        nearestDistancesCentimeters: Array(repeating: 200, count: 361),
                        spreadCentimeters: Array(repeating: 0, count: 361)))
                default: XCTFail("Generator outside alphabet")
                }
                flush(c.runtime)
                if releases {
                    XCTAssertTrue(au.sounding.isEmpty, "sequence \(sequence), action \(action)")
                    if midi.result == .sent { XCTAssertTrue(midi.sounding.isEmpty, "sequence \(sequence), action \(action)") }
                }
                if retiresMIDI { XCTAssertTrue(midi.sounding.isEmpty) }
                if retiresAU { XCTAssertTrue(au.sounding.isEmpty) }
                XCTAssertEqual(midi.duplicateOns, 0)
                XCTAssertEqual(au.duplicateOns, 0)
                // With no real frame input, recovery must never manufacture Ons.
                if ![0, 1, 2, 22].contains(action) {
                    XCTAssertEqual(c.mailbox.read()?.processedProfiles, oldCount)
                    XCTAssertFalse(midi.receipts.dropFirst(oldReceipts.0).contains { $0.bytes[0] & 0xF0 == 0x90 })
                    XCTAssertFalse(au.receipts.dropFirst(oldReceipts.1).contains { $0.bytes[0] & 0xF0 == 0x90 })
                }
                // Old/foreign-session frames cannot produce sound, even after
                // panic, stop, terminate, or a stale callback.
                let before = (midi.receipts.count, au.receipts.count)
                c.runtime.frame(profile(999, session: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!)); flush(c.runtime)
                XCTAssertEqual(midi.receipts.count, before.0)
                XCTAssertEqual(au.receipts.count, before.1)
            }
            midi.result = .sent
            if !midiAttached { c.runtime.attach(RuntimePorts.midi(id: midiID, boundary: midi)) }
            if !auAttached { c.runtime.attach(RuntimePorts.audioUnit(id: auID, boundary: au)) }
            c.runtime.install(recovery)
            c.runtime.wake() // A session change cannot end system suspension.
            c.runtime.sessionBegan(session)
            c.runtime.frame(profile(time: 21)); flush(c.runtime)
            XCTAssertEqual(midi.sounding.count, 1, "return guarantee \(sequence)")
            XCTAssertEqual(au.sounding.count, 1, "local fault isolation \(sequence)")
            c.runtime.panic(); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
            c.runtime.frame(profile(time: 21)); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
            c.runtime.frame(profile(empty: true, time: 21)); flush(c.runtime)
            c.runtime.frame(profile(time: 22)); flush(c.runtime)
            XCTAssertEqual(midi.sounding.count, 1); XCTAssertEqual(au.sounding.count, 1)
            let done = expectation(description: "final release")
            c.runtime.terminate {
                XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
        }
        XCTAssertEqual(coverage, Set(0..<26))
    }

    private func release(_ action: (PerformanceComposition, FakeClock) throws -> Void) throws {
        let midi = FakeBoundary(), au = FakeBoundary(), clock = FakeClock()
        let c = composition(clock: clock, midi: midi, au: au)
        try start(c)
        XCTAssertEqual(midi.sounding.count, 1); XCTAssertEqual(au.sounding.count, 1)
        try action(c, clock); flush(c.runtime); flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
    }
    func testReleasePanic() throws { try release { c, _ in c.runtime.panic() } }
    func testReleaseStop() throws { try release { c, _ in c.runtime.stop() } }
    func testReleaseSleep() throws { try release { c, _ in c.runtime.sleep() } }
    func testReleaseWake() throws { try release { c, _ in c.runtime.wake() } }
    func testReleaseSessionBegin() throws { try release { c, _ in c.runtime.sessionBegan(self.other) } }
    func testReleaseSessionEnd() throws { try release { c, _ in c.runtime.sessionEnded(self.session) } }
    func testReleaseEmptyProfile() throws { try release { c, _ in c.runtime.frame(self.profile(empty: true)) } }
    func testReleaseInvalidProfile() throws { try release { c, _ in c.runtime.frame(self.profile(time: .nan)) } }
    func testReleaseInstall() throws { try release { c, _ in c.runtime.install(try self.compiled(2, notes: false)) } }
    func testReleaseDetectionChanged() throws { try release { c, _ in c.runtime.detectionChanged(try self.compiled(2, notes: false)) } }
    func testReleaseStale() throws { try release { c, clock in clock.advance(20) } }
    func testReleaseTerminate() throws {
        try release { c, _ in
            let done = self.expectation(description: "terminate")
            c.runtime.terminate { done.fulfill() }; self.wait(for: [done], timeout: 10)
        }
    }
}
