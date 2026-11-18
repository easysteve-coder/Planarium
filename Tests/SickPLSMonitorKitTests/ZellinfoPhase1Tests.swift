import XCTest
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// ZELLINFO-1, Schnitt Teil 1. Phase 1 ruft die freigegebene künftige
/// Produktionsnaht direkt auf; Compile-Rot ist bis zur Produktimplementierung
/// der erwartete Nachweis.
final class ZellinfoPhase1Tests: XCTestCase {
    private let layerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let routingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let cell = PolarMetricGridCell(ring: 2, angularIndex: 4)

    private func workspace(
        program: SpatialValueProgram,
        target: SpatialRoutingTarget = .midiNote(channel: 0),
        cells: Set<PolarMetricGridCell> = [PolarMetricGridCell(ring: 2, angularIndex: 4)],
        overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
    ) -> SpatialInstrumentWorkspace {
        SpatialInstrumentWorkspace(
            grid: .halfMeter,
            layers: [SpatialInstrumentLayer(
                id: layerID, name: "Zellinfo", color: .orange,
                polarCells: cells,
                routings: [SpatialRouting(id: routingID, target: target, program: program)],
                polarCellOverrides: overrides
            )]
        )
    }

    func testZ1ChordCellTextUsesRootAndKnownOrUnknownChordName() throws {
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let cases: [(SpatialValueProgram, String)] = [
            (.chord(notes: [60], velocity: 100, transition: .retrigger), "C4"),
            (.chord(notes: [60, 64, 67], velocity: 100, transition: .retrigger), "C"),
            (.chord(notes: [60, 61], velocity: 100, transition: .retrigger), "C4 +1")
        ]
        for (program, expected) in cases {
            let document = workspace(program: program, target: target)
            let values = SpatialInstrumentEvaluator().cellValues(
                layerID: layerID, cells: [cell], workspace: document
            )
            XCTAssertEqual(
                SpatialCellLabel.text(for: try XCTUnwrap(values[cell]), target: target),
                expected
            )
        }
    }

    func testZ2ScaleCellTextUsesIndependentHandCalculatedEndpoints() throws {
        let cells: [PolarMetricGridCell] = [
            .init(ring: 2, angularIndex: 2), .init(ring: 2, angularIndex: 3),
            .init(ring: 2, angularIndex: 4)
        ]
        // Bei directionDegrees 0 steigt die Projektion dieser drei Zellen mit
        // angularIndex; die Handwerte an den Endpunkten sind deshalb C4 und C5.
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let document = workspace(
            program: .scale(rootMIDINote: 60, lowestMIDINote: 60, highestMIDINote: 72,
                             scale: .major, directionDegrees: 0, ascending: true, transition: .retrigger),
            target: target, cells: Set(cells)
        )
        let values = SpatialInstrumentEvaluator().cellValues(
            layerID: layerID, cells: cells, workspace: document
        )
        XCTAssertEqual(SpatialCellLabel.text(for: try XCTUnwrap(values[cells[0]]), target: target), "C4")
        XCTAssertEqual(SpatialCellLabel.text(for: try XCTUnwrap(values[cells[2]]), target: target), "C5")
    }

    func testZ3CellOverrideShowsTheDeviationNote() throws {
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let override = SpatialCellAction(target: target, value: .note(number: 64, velocity: 100))
        let document = workspace(
            program: .chord(notes: [60], velocity: 100, transition: .retrigger),
            target: target, overrides: [cell: [override]]
        )
        let values = SpatialInstrumentEvaluator().cellValues(
            layerID: layerID, cells: [cell], workspace: document
        )
        XCTAssertEqual(SpatialCellLabel.text(for: try XCTUnwrap(values[cell]), target: target), "E4")
    }

    func testZ4ScalarCellTextUsesCCAndPitchBendUnits() throws {
        let cc = SpatialRoutingTarget.midiCC(channel: 0, controller: 74)
        let ccDocument = workspace(program: .constant(0.5), target: cc)
        let ccValues = SpatialInstrumentEvaluator().cellValues(
            layerID: layerID, cells: [cell], workspace: ccDocument
        )
        XCTAssertEqual(SpatialCellLabel.text(for: try XCTUnwrap(ccValues[cell]), target: cc), "64")

        let bend = SpatialRoutingTarget.midiPitchBend(channel: 0)
        let bendDocument = workspace(program: .constant(0.25), target: bend)
        let bendValues = SpatialInstrumentEvaluator().cellValues(
            layerID: layerID, cells: [cell], workspace: bendDocument
        )
        XCTAssertEqual(SpatialCellLabel.text(for: try XCTUnwrap(bendValues[cell]), target: bend), "25 %")
    }

    func testZ5CellTextVisibilityUsesScreenPointsAcrossZoomRoundTrip() throws {
        let segment = PolarMetricCellSegment(cell: cell, grid: .halfMeter)
        XCTAssertFalse(SpatialCellLabel.isVisible(segment: segment, metersPerPoint: 0.05))
        XCTAssertTrue(SpatialCellLabel.isVisible(segment: segment, metersPerPoint: 0.05 / 8))
        XCTAssertFalse(SpatialCellLabel.isVisible(segment: segment, metersPerPoint: 0.05))
        // Bei 0.05 m/pt ist die radiale Kante 10 pt; bei 0.00625 m/pt sind
        // es 80 pt. Beide Kanten müssen die 14-pt-Schwelle erfüllen.
    }

    func testZ6BatchCellValuesMatchSingleEvaluationForAllPrograms() throws {
        let cells = (0..<50).map { PolarMetricGridCell(ring: 2, angularIndex: $0) }
        let evaluator = SpatialInstrumentEvaluator()
        let programs: [SpatialValueProgram] = [
            .scale(rootMIDINote: 60, lowestMIDINote: 60, highestMIDINote: 72,
                   scale: .major, directionDegrees: 0, ascending: true, transition: .retrigger),
            .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear),
            .constant(0.6),
            .chord(notes: [60,64,67], velocity: 100, transition: .legato),
            .singleNote(note: 61, velocity: 99, transition: .holdUntilNext),
            .randomScale(rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84,
                         scale: .major, seed: 42, transition: .retrigger),
            .programChange(.init(program: 12))
        ]
        for program in programs {
            let document = workspace(program: program, cells: Set(cells))
            let batch = evaluator.cellValues(layerID: layerID, cells: cells, workspace: document)
            for cell in cells {
                let expected = evaluator.evaluate(
                    activeCells: [layerID: cell], workspace: document
                ).first?.value
                XCTAssertEqual(batch[cell], expected)
            }
        }
    }
}
