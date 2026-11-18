import XCTest
import SickPLSControlCore
@testable import SickPLSMonitorKit

final class ZellinfoTeil2Tests: XCTestCase {
    private let layerID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let routingID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let cell = PolarMetricGridCell(ring: 2, angularIndex: 4)

    private func workspace(
        program: SpatialValueProgram,
        target: SpatialRoutingTarget = .midiNote(channel: 0),
        cells: Set<PolarMetricGridCell> = [PolarMetricGridCell(ring: 2, angularIndex: 4)],
        overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
    ) -> SpatialInstrumentWorkspace {
        SpatialInstrumentWorkspace(
            grid: .halfMeter,
            layers: [
                SpatialInstrumentLayer(
                    id: layerID,
                    name: "Zellinfo",
                    color: .orange,
                    polarCells: cells,
                    routings: [
                        SpatialRouting(id: routingID, target: target, program: program)
                    ],
                    polarCellOverrides: overrides
                )
            ]
        )
    }

    func testC1ScaleShowsEndCellValueAndLayerOrigin() throws {
        let cells = [
            PolarMetricGridCell(ring: 2, angularIndex: 2),
            PolarMetricGridCell(ring: 2, angularIndex: 3),
            cell
        ]
        let document = workspace(
            program: .scale(
                rootMIDINote: 60,
                lowestMIDINote: 60,
                highestMIDINote: 72,
                scale: .major,
                directionDegrees: 0,
                ascending: true,
                transition: .retrigger
            ),
            cells: Set(cells)
        )
        let expectedValue = try XCTUnwrap(
            SpatialInstrumentEvaluator().cellValues(
                layerID: layerID,
                cells: [cell],
                workspace: document
            )[cell]
        )

        let info = try XCTUnwrap(
            SpatialCellInfo.make(cell: cell, layerID: layerID, workspace: document)
        )

        XCTAssertEqual(info.valueText, "C5")
        XCTAssertEqual(info.origin, .layerAssignment)
        XCTAssertEqual(info.value, expectedValue)
    }

    func testC2MatchingCellOverrideWinsButOtherTargetDoesNot() throws {
        let matchingOverride = SpatialCellAction(
            target: .midiNote(channel: 0),
            value: .note(number: 64, velocity: 100)
        )
        let matchingDocument = workspace(
            program: .constant(0.25),
            overrides: [cell: [matchingOverride]]
        )
        let matchingInfo = try XCTUnwrap(
            SpatialCellInfo.make(cell: cell, layerID: layerID, workspace: matchingDocument)
        )

        XCTAssertEqual(matchingInfo.valueText, "E4")
        XCTAssertEqual(matchingInfo.origin, .cellOverride)

        let otherTargetOverride = SpatialCellAction(
            target: .midiCC(channel: 0, controller: 74),
            value: .scalar(1)
        )
        let otherTargetDocument = workspace(
            program: .constant(0.25),
            overrides: [cell: [otherTargetOverride]]
        )
        let otherTargetInfo = try XCTUnwrap(
            SpatialCellInfo.make(cell: cell, layerID: layerID, workspace: otherTargetDocument)
        )

        XCTAssertEqual(otherTargetInfo.origin, .layerAssignment)
    }

    func testC3ReportsHandCalculatedRadiusAndAngleBoundaries() throws {
        let document = workspace(program: .constant(0.5))
        let info = try XCTUnwrap(
            SpatialCellInfo.make(cell: cell, layerID: layerID, workspace: document)
        )

        // Bei .halfMeter und Ring 2 gilt: 1,0 m innen, 1,5 m außen.
        // Die Produktionsregel halbiert 90° zweimal (90 → 45 → 22,5),
        // bis die äußere Bogenbreite höchstens 0,75 m beträgt. Index 4
        // beginnt daher bei -90,0° und endet bei -67,5°.
        let expectedInnerRadiusMeters = 1.0
        let expectedOuterRadiusMeters = 1.5
        let expectedStartBearingDegrees = -90.0
        let expectedEndBearingDegrees = -67.5

        XCTAssertEqual(info.segment.innerRadiusMeters, expectedInnerRadiusMeters, accuracy: 0.000_000_001)
        XCTAssertEqual(info.segment.outerRadiusMeters, expectedOuterRadiusMeters, accuracy: 0.000_000_001)
        XCTAssertEqual(info.segment.startBearingDegrees, expectedStartBearingDegrees, accuracy: 0.000_000_001)
        XCTAssertEqual(info.segment.endBearingDegrees, expectedEndBearingDegrees, accuracy: 0.000_000_001)
        XCTAssertEqual(info.ringText, "Ring 1.00–1.50 m")
        XCTAssertEqual(info.angleText, "Angle −90.0…−67.5°")
    }

    func testC4NoRoutingHasNoTargetOrDisplayValueAndUnknownCellIsAbsent() throws {
        let document = SpatialInstrumentWorkspace(
            grid: .halfMeter,
            layers: [
                SpatialInstrumentLayer(
                    id: layerID,
                    name: "Ohne Routing",
                    color: .orange,
                    polarCells: [cell],
                    routings: []
                )
            ]
        )

        let info = try XCTUnwrap(
            SpatialCellInfo.make(cell: cell, layerID: layerID, workspace: document)
        )
        XCTAssertNil(info.target)
        XCTAssertNil(info.origin)
        XCTAssertNil(info.valueText)

        let unknownCell = PolarMetricGridCell(ring: 3, angularIndex: 4)
        XCTAssertNil(
            SpatialCellInfo.make(cell: unknownCell, layerID: layerID, workspace: document)
        )
    }

    func testC5AppliedAssignmentIsReflectedWithoutViewState() throws {
        var state = MetricCanvasInteractionState()
        state.replaceWorkspace(
            workspace(
                program: .chord(notes: [60], velocity: 100, transition: .retrigger)
            )
        )

        var draft = SpatialAssignmentDraft.current(in: state)
        draft.setRootMIDINote(67)
        XCTAssertTrue(state.applyAssignment(draft))

        let info = try XCTUnwrap(
            SpatialCellInfo.make(cell: cell, layerID: layerID, workspace: state.workspace)
        )

        XCTAssertEqual(info.valueText, "G4")
        XCTAssertEqual(info.origin, .layerAssignment)
    }
}
