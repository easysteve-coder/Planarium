import XCTest
import PlanariumDomain
@testable import PlanariumRuntime

final class ChordRuntimeTests: RuntimeTestCase {
    func testAllModesThroughAUFakeAndUnchangedMIDIFakeReleaseMatrixAt90And361() throws {
        for count in [90, 361] { for mode in ChordEffect.Mode.allCases {
            for transition in [SpatialNoteTransition.legato, .holdUntilNext, .toggle] {
                for branch in 0..<9 {
                    let clock = FakeClock(), runtime = PerformanceRuntime(clock: clock, mailbox: .init())
                    let au = FakeBoundary(), midi = FakeBoundary()
                    au.setHook { _ in XCTAssertFalse(Thread.isMainThread) }
                    runtime.attach(RuntimePorts.audioUnit(stripID: InstrumentChannel.legacyID, boundary: au))
                    runtime.attach(RuntimePorts.midi(boundary: midi))
                    let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
                    let sector = geometry.tickSpan(at: 45)!.lower
                    let layer = SpatialDocumentLayer(id: session, name: "Chord", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                        cells: [PolarDeviceLattice(ring: 100, sector: sector)!], routings: [
                            .init(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), program: .singleNote(note: 60, velocity: 99, transition: transition)),
                            .init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 99, transition: transition))], cellOverrides: [:])
                    var document = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: session), detection: .allStagesOff, revision: .newSession())
                    var chord = ChordEffect(); chord.mode = mode; chord.multiNotes = [60: [60, 64, 67]]
                    document.channel.midiEffects = [.init(chord: chord)]
                    runtime.install(try InstrumentCompiler.compile(document)); runtime.sessionBegan(session)
                    func frame(_ sequence: UInt64, active: Bool) -> ProfileFrame {
                        .init(sessionID: session, sequence: sequence, time: clock.now,
                            measurements: (0..<count).map { DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: $0 == 45 && active ? 100 : 500)! }, geometry: geometry)
                    }
                    runtime.frame(frame(1, active: true)); flush(runtime)
                    XCTAssertEqual(Set(au.receipts.map(\.bytes)), Set([[0x90, 60, 99], [0x90, 64, 99], [0x90, 67, 99]]))
                    XCTAssertEqual(midi.receipts.map(\.bytes), [[0x90, 60, 99]])
                    switch branch {
                    case 0: runtime.panic()
                    case 1: runtime.stop()
                    case 2: runtime.sleep()
                    case 3: runtime.terminate(ack: {})
                    case 4: runtime.sessionEnded(session, reason: .failure)
                    case 5: runtime.frame(frame(2, active: false))
                    case 6:
                        document.channel.midiEffects[0].bypassed = true
                        document.revision = try document.revision.advanced()
                        runtime.install(try InstrumentCompiler.compile(document))
                    case 7: runtime.sessionBegan(other)
                    case 8:
                        document.revision = .newSession()
                        runtime.install(try InstrumentCompiler.compile(document))
                    default: XCTFail("Uncovered release branch")
                    }
                    flush(runtime)
                    let off = Set(au.receipts.filter { $0.bytes.first == 0x80 }.map { $0.bytes[1] })
                    let preserved = [4, 5].contains(branch) && transition != .legato
                    XCTAssertEqual(off, preserved ? [] : [60, 64, 67], "\(count) \(mode) \(transition) branch \(branch)")
                    runtime.stop(); flush(runtime)
                    XCTAssertEqual(Set(au.receipts.filter { $0.bytes.first == 0x80 }.map { $0.bytes[1] }), [60, 64, 67])
                    runtime.terminate(ack: {}); flush(runtime)
                }
            }
        } }
    }
}
