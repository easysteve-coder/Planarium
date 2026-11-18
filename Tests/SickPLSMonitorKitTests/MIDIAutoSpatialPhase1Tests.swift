import XCTest
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// MIDI-AUTO M1: Lautsprecher-Aus wird im räumlichen Notenweg je Ebene
/// verrechnet; der globale Ausgangsabgleicher ist daran nicht beteiligt.
final class MIDIAutoSpatialPhase1Tests: XCTestCase {
    private let firstLayerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondLayerID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let firstRoutingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let secondRoutingID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func workspace(firstActive: Bool) -> SpatialInstrumentWorkspace {
        SpatialInstrumentWorkspace(layers: [
            SpatialInstrumentLayer(
                id: firstLayerID, name: "Ebene 1", color: .orange,
                isActive: firstActive,
                polarCells: [.init(ring: 2, angularIndex: 3)],
                routings: [SpatialRouting(
                    id: firstRoutingID,
                    target: .midiNote(channel: 0),
                    program: .chord(notes: [60], velocity: 100, transition: .retrigger)
                )]
            ),
            SpatialInstrumentLayer(
                id: secondLayerID, name: "Ebene 2", color: .blue,
                polarCells: [.init(ring: 3, angularIndex: 4)],
                routings: [SpatialRouting(
                    id: secondRoutingID,
                    target: .midiNote(channel: 0),
                    program: .chord(notes: [64], velocity: 100, transition: .retrigger)
                )]
            )
        ])
    }

    func testA4SpeakerOffReleasesOnlyThatSpatialLayer() {
        let active = workspace(firstActive: true)
        let muted = workspace(firstActive: false)
        let activeCells: [UUID: PolarMetricGridCell] = [
            firstLayerID: .init(ring: 2, angularIndex: 3),
            secondLayerID: .init(ring: 3, angularIndex: 4)
        ]
        let evaluator = SpatialInstrumentEvaluator()
        var ledger = SpatialNoteLedger()

        let initial = ledger.apply(evaluator.evaluate(activeCells: activeCells, workspace: active))
        XCTAssertEqual(initial.filter { if case .noteOn = $0 { return true }; return false }.count, 2)

        let afterMute = ledger.apply(evaluator.evaluate(activeCells: activeCells, workspace: muted))
        XCTAssertEqual(afterMute, [
            .noteOff(destination: .midi, channel: 0, note: .init(number: 60, velocity: 100))
        ])
        XCTAssertEqual(ledger.heldNoteCount, 1)
    }
}
