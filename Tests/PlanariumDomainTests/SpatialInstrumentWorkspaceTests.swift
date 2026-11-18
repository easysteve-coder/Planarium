@testable import SickPLSMonitorKit
import XCTest
@testable import PlanariumDomain
import SickPLSControlCore

final class SpatialInstrumentWorkspaceTests: XCTestCase {
    func testNewWorkspaceUsesTwentyFiveCentimeterGridAndOffersOnlyProductSizes() {
        XCTAssertEqual(SpatialInstrumentWorkspace().grid, .quarterMeter)
        XCTAssertEqual(MetricSquareGrid.CellSize.allCases.map(\.meters), [0.01, 0.02, 0.03, 0.04, 0.05, 0.10, 0.25, 0.50])
        XCTAssertEqual(MetricSquareGrid.CellSize.allCases.map(\.displayName), ["1 cm", "2 cm", "3 cm", "4 cm", "5 cm", "10 cm", "25 cm", "50 cm"])
    }

    func testFineCellSizesCodableRoundTripAndLegacyTenCentimeterValue() throws {
        for size in MetricSquareGrid.CellSize.allCases {
            let data = try JSONEncoder().encode(size)
            XCTAssertEqual(try JSONDecoder().decode(MetricSquareGrid.CellSize.self, from: data), size)
        }
        let legacy = try JSONEncoder().encode(MetricSquareGrid.CellSize.tenCentimeter)
        XCTAssertEqual(try JSONDecoder().decode(MetricSquareGrid.CellSize.self, from: legacy), .tenCentimeter)
    }

    func testOneCentimeterRingSeparates101Point4And102Point6Centimeters() throws {
        let grid = MetricSquareGrid.CellSize.oneCentimeter.grid
        let near = PolarMetricGridCell(point: .init(xMeters: 0, yMeters: 1.014), grid: grid)
        let far = PolarMetricGridCell(point: .init(xMeters: 0, yMeters: 1.026), grid: grid)
        XCTAssertEqual(near.ring, 101)
        XCTAssertEqual(far.ring, 102)
        XCTAssertNotEqual(near.ring, far.ring)
    }

    func testMissingGridInOldWorkspaceDefaultsToFiftyCentimeters() throws {
        let encoded = try JSONEncoder().encode(SpatialInstrumentWorkspace())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "grid")
        let oldDocument = try JSONSerialization.data(withJSONObject: object)

        XCTAssertEqual(try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: oldDocument).grid, .halfMeter)
    }

    func testTenCentimeterGridSurvivesPresetWorkspaceRoundTrip() throws {
        let workspace = SpatialInstrumentWorkspace(grid: .tenCentimeter)
        let restored = try JSONDecoder().decode(
            SpatialInstrumentWorkspace.self, from: JSONEncoder().encode(workspace)
        )
        XCTAssertEqual(restored.grid, .tenCentimeter)
    }

    func testGridChangeIsImmediateAndReprojectsContentWithoutClearingValues() {
        var empty = SpatialInstrumentWorkspace()
        XCTAssertEqual(empty.requestGridChange(to: .tenCentimeter), .changed)
        XCTAssertEqual(empty.grid, .tenCentimeter)

        let cell = PolarMetricGridCell(point: .init(xMeters: 0, yMeters: 0.625), grid: .quarterMeter)
        let action = SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 60, velocity: 100))
        var populated = SpatialInstrumentWorkspace(layers: [
            .init(name: "Ebene", color: .orange, polarCells: [cell], polarCellOverrides: [cell: [action]])
        ])
        XCTAssertEqual(populated.requestGridChange(to: .tenCentimeter), .changed)
        XCTAssertEqual(populated.grid, .tenCentimeter)
        XCTAssertEqual(populated.confirmGridChange(to: .tenCentimeter), .unchanged)
        XCTAssertEqual(populated.grid, .tenCentimeter)
        XCTAssertFalse(populated.selectedLayer.polarCells.isEmpty)
        XCTAssertFalse(populated.selectedLayer.polarCellOverrides.isEmpty)
    }

    func testFiveMeterTenCentimeterAreaFitsDocumentAndBulkAddressBudgets() {
        let sideCount = Int(5.0 / MetricSquareGrid.tenCentimeter.cellSizeMeters)
        let addresses = sideCount * sideCount
        XCTAssertEqual(addresses, 2_500)
        XCTAssertLessThanOrEqual(addresses, SpatialDocumentBudget.production.addressesPerLayer)

        var workspace = SpatialInstrumentWorkspace(grid: .tenCentimeter)
        let selection = Set((0..<sideCount).flatMap { ring in
            (0..<sideCount).map { angularIndex in PolarMetricGridCell(ring: ring, angularIndex: angularIndex) }
        })
        let result = workspace.applyBulk(.paint, to: selection, addressBudget: SpatialDocumentBudget.production.addressesPerLayer)
        XCTAssertEqual(result, .success(.applied(changedCells: addresses)))
    }

    func testLayerDecoderAcceptsPresetsFromBeforePolarCells() throws {
        let layer = SpatialInstrumentLayer(name: "Alt", color: .blue)
        let encoded = try JSONEncoder().encode(layer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "polarCells")
        object.removeValue(forKey: "polarCellOverrides")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SpatialInstrumentLayer.self, from: legacy)

        XCTAssertTrue(decoded.polarCells.isEmpty)
        XCTAssertTrue(decoded.polarCellOverrides.isEmpty)
    }
    func testMIDINoteNamesUseMusicalNamesInsteadOfRawNumbers() {
        let names = (0..<12).map { MIDINoteName.pitchClassName(for: 60 + $0) }
        XCTAssertEqual(names, ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"])
        XCTAssertEqual(MIDINoteName.displayName(for: 60), "C4")
        XCTAssertEqual(MIDINoteName.displayName(for: 61), "C♯4")
        XCTAssertEqual(MIDINoteName.displayName(for: 70), "B♭4")
        XCTAssertEqual(MIDINoteName.displayName(for: 71), "B4")
    }

    func testExistingPresetRoundTripPreservesMIDIChordNotes() throws {
        let routing = SpatialRouting(
            target: .midiNote(channel: 0),
            program: .chord(notes: [58, 70, 71], velocity: 96, transition: .retrigger)
        )
        var workspace = SpatialInstrumentWorkspace()
        workspace.updateSelectedLayer { $0.routings = [routing] }

        let restored = try JSONDecoder().decode(
            SpatialInstrumentWorkspace.self,
            from: JSONEncoder().encode(workspace)
        )
        guard case .chord(let notes, _, _) = restored.selectedLayer.routings[0].program else {
            return XCTFail("Expected chord program")
        }
        XCTAssertEqual(notes, [58, 70, 71])
    }

    func testChordPresetsProduceSelectableConcreteNotes() {
        XCTAssertEqual(SpatialChordPreset.major.notes(root: 60), [60, 64, 67])
        XCTAssertEqual(SpatialChordPreset.minor7.notes(root: 57), [57, 60, 64, 67])
        XCTAssertEqual(SpatialChordPreset.major7.notes(root: 125), [125, 127, 127, 127])
    }

    func testVisibilityAndActivityAreIndependent() {
        var workspace = SpatialInstrumentWorkspace()
        workspace.updateSelectedLayer {
            $0.isVisible = false
            $0.isActive = true
        }
        XCTAssertFalse(workspace.selectedLayer.isVisible)
        XCTAssertTrue(workspace.selectedLayer.isActive)
    }

    func testMusicalSnapshotKeyIgnoresInspectorCosmeticsButTracksSoundChanges() {
        let base = SpatialInstrumentWorkspace()
        var cosmetic = base
        cosmetic.updateSelectedLayer {
            $0.name = "Neue Beschriftung"
            $0.color = .purple
            $0.isVisible = false
            $0.isLocked = true
        }
        XCTAssertTrue(base.isMusicallyEquivalent(to: cosmetic))

        var musical = base
        musical.updateSelectedLayer { $0.isActive = false }
        XCTAssertFalse(base.isMusicallyEquivalent(to: musical))
    }

    func testCartesianCellsBecomeRealPolarCellsAndLoseTheirOldTopology() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.5)
        let source = MetricGridCell(column: 1, row: 3)
        let action = SpatialCellAction(
            target: .midiNote(channel: 0),
            value: .note(number: 60, velocity: 100)
        )
        let legacy = LegacyLayerDocument(
            name: "Noten", color: .orange,
            cells: [source], cellOverrides: [source: [action]]
        )
        let workspace = try LegacyWorkspaceDocument.decoded(layer: legacy, grid: grid)

        XCTAssertEqual(workspace.coordinateMode, .polar)
        let target = try XCTUnwrap(workspace.selectedLayer.polarCells.first)
        XCTAssertEqual(workspace.selectedLayer.polarCellOverrides[target], [action])
        let segment = PolarMetricCellSegment(cell: target, grid: grid)
        XCTAssertGreaterThan(segment.outerRadiusMeters, segment.innerRadiusMeters)
        XCTAssertGreaterThan(segment.endBearingDegrees, segment.startBearingDegrees)
    }

    func testWorkspacePersistsItsActiveTopologyAndLegacyPresetInfersIt() throws {
        let polar = PolarMetricGridCell(ring: 4, angularIndex: 9)
        let workspace = SpatialInstrumentWorkspace(
            layers: [.init(name: "Polar", color: .orange, polarCells: [polar])]
        )
        let encoded = try JSONEncoder().encode(workspace)
        XCTAssertEqual(
            try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: encoded).coordinateMode,
            .polar
        )

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "coordinateMode")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decodedLegacy = try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: legacy)
        XCTAssertEqual(decodedLegacy.coordinateMode, .polar)
        XCTAssertEqual(decodedLegacy.selectedLayer.polarCells, [polar])
    }

    func testTwoLegacyCellsSharingOnePolarCellKeepBothActions() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.5)
        // Die Übernahme ist nicht eineindeutig: nahe am Scanner ist ein Sektor
        // breiter als ein altes Rasterquadrat. Das Paar wird deshalb gesucht
        // und nicht geraten — der Test prüft die Regel, nicht eine Zahlenwahl.
        let candidates = (0..<6).flatMap { column in
            (0..<6).map { MetricGridCell(column: column, row: $0) }
        }
        var pair: (MetricGridCell, MetricGridCell)?
        search: for (index, first) in candidates.enumerated() {
            let address = SpatialInstrumentWorkspace.polarCell(atCenterOf: first, grid: grid)
            for second in candidates[(index + 1)...] {
                if SpatialInstrumentWorkspace.polarCell(atCenterOf: second, grid: grid) == address {
                    pair = (first, second)
                    break search
                }
            }
        }
        let (first, second) = try XCTUnwrap(pair, "Keine zwei Altzellen teilen einen Sektor")

        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let lower = SpatialCellAction(target: target, value: .note(number: 60, velocity: 100))
        let upper = SpatialCellAction(target: target, value: .note(number: 62, velocity: 100))
        let legacy = LegacyLayerDocument(
            name: "Noten", color: .orange,
            cells: [first, second], cellOverrides: [first: [lower], second: [upper]]
        )

        let workspace = try LegacyWorkspaceDocument.decoded(layer: legacy, grid: grid)

        // Die Zellen sind wirklich zusammengefallen …
        XCTAssertEqual(workspace.selectedLayer.polarCells.count, 1)
        // … und keine der beiden Noten ist dabei verschwunden oder zu einem
        // Mittelwert verrechnet worden.
        let actions = workspace.selectedLayer.polarCellOverrides.values.flatMap { $0 }
        XCTAssertTrue(actions.contains(lower))
        XCTAssertTrue(actions.contains(upper))
    }

    func testDeletingTheOnlyLayerIsRefused() {
        var workspace = SpatialInstrumentWorkspace()
        let id = workspace.selectedLayerID
        workspace.deleteSelectedLayer()
        XCTAssertEqual(workspace.layers.count, 1)
        XCTAssertEqual(workspace.selectedLayerID, id)
    }

    // MARK: - AR-1a: Polar als einzige Topologie

    func testDefaultWorkspaceIsPolar() {
        let workspace = SpatialInstrumentWorkspace()
        XCTAssertEqual(workspace.coordinateMode, .polar)
    }

    func testCartesianModeParameterIsIgnored() {
        let workspace = SpatialInstrumentWorkspace(coordinateMode: .cartesian)
        XCTAssertEqual(workspace.coordinateMode, .polar)
    }

    func testLegacyCartesianJSONDecodesToPolar() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.5)
        let cellA = MetricGridCell(column: 0, row: 0)
        let cellB = MetricGridCell(column: 1, row: 0)
        let legacy = LegacyLayerDocument(
            name: "Alt", color: .blue,
            cells: [cellA, cellB],
            cellOverrides: [
                cellA: [SpatialCellAction(target: .midiCC(channel: 0, controller: 7), value: .scalar(0.5))],
                cellB: [SpatialCellAction(target: .midiCC(channel: 0, controller: 7), value: .scalar(0.8))]
            ]
        )
        let decoded = try LegacyWorkspaceDocument.decoded(layer: legacy, grid: grid)

        XCTAssertEqual(decoded.coordinateMode, .polar)
        // Zwei kartesische Zellen → mindestens eine Polarzelle.
        XCTAssertFalse(decoded.selectedLayer.polarCells.isEmpty)
        XCTAssertFalse(decoded.selectedLayer.polarCellOverrides.isEmpty)
    }

    func testJSONWithoutCoordinateModeDecodesToPolar() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.5)
        let cell = MetricGridCell(column: 2, row: 1)
        let legacy = LegacyLayerDocument(
            name: "Legacy", color: .green,
            cells: [cell],
            cellOverrides: [cell: [SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 64, velocity: 90))]]
        )
        let decoded = try LegacyWorkspaceDocument.decoded(layer: legacy, grid: grid, coordinateMode: nil)

        XCTAssertEqual(decoded.coordinateMode, .polar)
        XCTAssertFalse(decoded.selectedLayer.polarCells.isEmpty)
    }

    func testPolarRoundTripContainsPolarCoordinateMode() throws {
        let polar = PolarMetricGridCell(ring: 3, angularIndex: 7)
        var layer = SpatialInstrumentLayer(name: "Rund", color: .purple, polarCells: [polar])
        layer.polarCellOverrides[polar] = [SpatialCellAction(target: .midiCC(channel: 1, controller: 10), value: .scalar(0.6))]
        let workspace = SpatialInstrumentWorkspace(layers: [layer])

        let encoded = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: encoded)
        XCTAssertEqual(decoded, workspace)

        // Das kodierte JSON enthält explizit "polar".
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["coordinateMode"] as? String, "polar")

        // Und es enthält die kartesischen Altschlüssel nicht mehr. Ein heutiges
        // Dokument trägt keine zweite Topologie; die Schlüssel existieren nur
        // noch lesend, für Dokumente von vor dem Cutover.
        let layerObjects = try XCTUnwrap(object["layers"] as? [[String: Any]])
        XCTAssertEqual(layerObjects.count, 1)
        XCTAssertNil(layerObjects[0]["cells"])
        XCTAssertNil(layerObjects[0]["cellOverrides"])
        XCTAssertNotNil(layerObjects[0]["polarCells"])
        XCTAssertNotNil(layerObjects[0]["polarCellOverrides"])
    }

    func testCartesianCellActionSurvivesImportIntoPolarOverrides() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.5)
        let source = MetricGridCell(column: 3, row: 2)
        let action = SpatialCellAction(
            target: .midiNote(channel: 2),
            value: .note(number: 72, velocity: 110)
        )
        let legacy = LegacyLayerDocument(
            name: "Gegenprobe", color: .orange,
            cells: [source], cellOverrides: [source: [action]]
        )
        let workspace = try LegacyWorkspaceDocument.decoded(layer: legacy, grid: grid)

        // Die Aktion muss in polarCellOverrides an der umgewandelten Adresse liegen.
        let polarTarget = try XCTUnwrap(workspace.selectedLayer.polarCells.first)
        XCTAssertEqual(workspace.selectedLayer.polarCellOverrides[polarTarget], [action])
    }

    func testProgramsRoundTripWithStableRandomSeedAndOverlap() throws {
        let routing = SpatialRouting(
            target: .midiNote(channel: 2),
            program: .randomScale(
                rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84,
                scale: .minorPentatonic, seed: 0xCAFE, transition: .overlap(milliseconds: 35)
            )
        )
        var workspace = SpatialInstrumentWorkspace()
        workspace.updateSelectedLayer { $0.routings = [routing] }
        let data = try JSONEncoder().encode(workspace)
        XCTAssertEqual(try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: data), workspace)
    }

    func testLatchAndAllNotesOffRoundTripInPresetWorkspace() throws {
        let latch = SpatialRouting(
            target: .midiNote(channel: 4),
            program: .chord(notes: [36, 48, 55], velocity: 96, transition: .holdUntilNext)
        )
        let stop = SpatialRouting(
            target: .midiAllNotesOff(channel: 4),
            program: .constant(1)
        )
        var workspace = SpatialInstrumentWorkspace()
        workspace.updateSelectedLayer { $0.routings = [latch, stop] }

        let data = try JSONEncoder().encode(workspace)
        XCTAssertEqual(try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: data), workspace)
    }

    func testScenesRememberOrderAndNeverMuteControlLayer() {
        let noteID = UUID(), controlID = UUID(), sceneID = UUID()
        let note = SpatialInstrumentLayer(id: noteID, name: "Notes", color: .orange, isActive: true)
        let control = SpatialInstrumentLayer(id: controlID, name: "Control", color: .green, isActive: true,
            routings: [.init(target: .sceneSwitch(action: .next, dwellSeconds: 0.2), program: .constant(1))])
        var workspace = SpatialInstrumentWorkspace(layers: [note, control], preserveLayerStructure: true)
        let created = workspace.addScene(name: "One")
        XCTAssertEqual(workspace.scenes.first?.activeLayerIDs, [noteID])
        workspace.updateLayer(noteID) { $0.isActive = false }
        workspace.rememberCurrentScene()
        XCTAssertEqual(workspace.scenes.first?.activeLayerIDs, [])
        workspace.selectScene(created)
        XCTAssertFalse(workspace.layers.first(where: { $0.id == noteID })!.isActive)
        XCTAssertTrue(workspace.layers.first(where: { $0.id == controlID })!.isActive)
        _ = workspace.addScene(name: "Two")
        workspace.moveScene(id: sceneID, by: 1) // unknown IDs are harmless
        XCTAssertEqual(try? JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: JSONEncoder().encode(workspace)), workspace)
    }

    func testPolarMoveRastersByTargetMidpointsAndFallsBackInwardWithoutLosingValue() {
        let grid = MetricSquareGrid.quarterMeter
        let source = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let action = SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 64, velocity: 90))
        let layer = SpatialInstrumentLayer(name: "Move", color: .orange, polarCells: [source], polarCellOverrides: [source: [action]])
        let workspace = SpatialInstrumentWorkspace(grid: grid, layers: [layer])

        let outward = PolarCellMove.applying(radialSteps: 1, angularSteps: 0, cells: [source], layerIDs: [], to: workspace)
        XCTAssertFalse(outward.didHitBoundary)
        XCTAssertGreaterThanOrEqual(outward.cells.count, 1)
        XCTAssertTrue(outward.cells.allSatisfy { outward.workspace.selectedLayer.polarCellOverrides[$0] == [action] })

        let inward = PolarCellMove.applying(radialSteps: -1, angularSteps: 0, cells: [source], layerIDs: [], to: workspace)
        XCTAssertFalse(inward.didHitBoundary)
        XCTAssertFalse(inward.cells.isEmpty, "The shifted source midpoint is the required inward fallback")
        XCTAssertTrue(inward.cells.allSatisfy { inward.workspace.selectedLayer.polarCellOverrides[$0] == [action] })
    }

    func testPolarMoveCollisionUsesNearestShiftedCentreAndBoundaryStopsWholeSelection() {
        let grid = MetricSquareGrid.quarterMeter
        let near = PolarMetricGridCell(ring: 3, angularIndex: 16)
        let far = PolarMetricGridCell(ring: 3, angularIndex: 17)
        let a = SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 60, velocity: 100))
        let b = SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 61, velocity: 100))
        let layer = SpatialInstrumentLayer(name: "Move", color: .orange, polarCells: [near, far], polarCellOverrides: [near: [a], far: [b]])
        let workspace = SpatialInstrumentWorkspace(grid: grid, layers: [layer])
        let stopped = PolarCellMove.applying(radialSteps: 10, angularSteps: 0, cells: [near, far], layerIDs: [], to: workspace)
        XCTAssertTrue(stopped.didHitBoundary)
        XCTAssertNotEqual(stopped.workspace, workspace)
        XCTAssertTrue(stopped.workspace.selectedLayer.polarCells.allSatisfy { $0.ring == 7 })
        let moved = PolarCellMove.applying(radialSteps: 0, angularSteps: 1, cells: [near], layerIDs: [], to: workspace)
        XCTAssertFalse(moved.cells.isEmpty)
    }

    func testPolarMoveAcrossSelectedLayersMovesEveryLayerCell() {
        let grid = MetricSquareGrid.quarterMeter
        let aID = UUID(), bID = UUID()
        let a = SpatialInstrumentLayer(id: aID, name: "A", color: .orange, polarCells: [.init(ring: 2, angularIndex: 8)])
        let b = SpatialInstrumentLayer(id: bID, name: "B", color: .blue, polarCells: [.init(ring: 4, angularIndex: 16)])
        let untouched = SpatialInstrumentLayer(name: "C", color: .green, polarCells: [.init(ring: 3, angularIndex: 8)])
        let workspace = SpatialInstrumentWorkspace(grid: grid, layers: [a, b, untouched])
        let moved = PolarCellMove.applying(radialSteps: 1, angularSteps: 0, cells: a.polarCells, layerIDs: [aID, bID], to: workspace)
        XCTAssertNotEqual(moved.workspace.layers[0].polarCells, a.polarCells)
        XCTAssertNotEqual(moved.workspace.layers[1].polarCells, b.polarCells)
        XCTAssertEqual(moved.workspace.layers[2].polarCells, untouched.polarCells)
    }

    func testPolarMoveFallsBackToShiftedCentreWhenNoTargetMidpointIsCovered() {
        let grid = MetricSquareGrid.quarterMeter
        // A fine outer segment moved into this coarse ring lies strictly
        // between its -163.125° and -151.875° target midpoints.
        let shifted = PolarMetricCellSegment(
            innerRadiusMeters: 0.75, outerRadiusMeters: 1,
            startBearingDegrees: -160.5, endBearingDegrees: -154.875
        )

        let targets = PolarCellMove.targetCells(for: shifted, grid: grid)

        XCTAssertEqual(targets, [.init(ring: 3, angularIndex: 1)])
    }

    func testFullRadialExtentIncludingRingZeroAnd199HasNoShiftAndEmptyOutsideRangeDoesNotTrap() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.01)
        let cells: Set<PolarMetricGridCell> = [.init(point: .init(xMeters: 0, yMeters: 0.005), grid: grid),
                                              .init(point: .init(xMeters: 0, yMeters: 1.995), grid: grid)]
        XCTAssertEqual(cells.map(\.ring).sorted(), [0, 199])
        let workspace = SpatialInstrumentWorkspace(grid: grid, layers: [.init(name: "Full radius", color: .blue, polarCells: cells)])
        for direction in [-1000, 1000] {
            let result = PolarCellMove.applying(radialSteps: direction, angularSteps: 0, cells: cells, layerIDs: [], to: workspace)
            XCTAssertTrue(result.didHitBoundary); XCTAssertEqual(result.workspace, workspace); XCTAssertEqual(result.cells, cells)
        }
        let outside = PolarMetricCellSegment(innerRadiusMeters: 3, outerRadiusMeters: 3.01, startBearingDegrees: -1, endBearingDegrees: 1)
        XCTAssertTrue(PolarCellMove.targetCells(for: outside, grid: grid).isEmpty)
    }

    func testNoFeasibleRadialIntervalThroughDragKeepsWholeSelectedSetAndReportsBoundary() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.01)
        let first = PolarMetricGridCell(point: .init(xMeters: 0, yMeters: 0.005), grid: grid)
        let edge = PolarMetricGridCell(point: .init(xMeters: 0, yMeters: 2.005), grid: grid)
        let layer = SpatialInstrumentLayer(name: "Unshiftable extent", color: .blue, polarCells: [first, edge])
        var state = MetricCanvasInteractionState()
        state.replaceWorkspace(.init(grid: grid, layers: [layer]))
        let size = CGSize(width: 800, height: 800)
        _ = state.resetViewport(canvasSize: size)
        _ = state.selectLayers([layer.id])
        let bounds = try XCTUnwrap(state.selectionBounds)
        let geometry = MetricCanvasGeometry(size: size, viewport: state.viewport)
        // The fixed-size inner handle covers the scanner origin. Start in
        // the selection envelope instead so this really tests MOVE, not resize.
        let point = geometry.screenPoint(for: bounds.point(radiusMeters: bounds.midpoint.radiusMeters, bearingDegrees: bounds.midpoint.bearingDegrees))
        let end = geometry.screenPoint(for: bounds.point(radiusMeters: bounds.midpoint.radiusMeters + 0.5, bearingDegrees: bounds.midpoint.bearingDegrees))
        XCTAssertEqual(state.selectedPolarCells, [first, edge])
        let before = state.workspace
        XCTAssertTrue(state.beginDrag(at: point, canvasSize: size))
        XCTAssertTrue(state.updateDrag(to: end, canvasSize: size))
        XCTAssertTrue(state.isMovingSelection)
        XCTAssertTrue(state.moveHitBoundary)
        state.endDrag(canvasSize: size)
        XCTAssertEqual(state.workspace, before)
    }
    func testPolarMovePreviewWorkForTwoHundredCellsStaysBelowEightMilliseconds() {
        func cells(count: Int, grid: MetricSquareGrid) -> Set<PolarMetricGridCell> {
            var result: [PolarMetricGridCell] = []
            for ring in 0..<Int(2 / grid.cellSizeMeters) where result.count < count {
                let step = PolarMetricCellSegment.angularStepDegrees(
                    outerRadiusMeters: Double(ring + 1) * grid.cellSizeMeters,
                    radialHeightMeters: grid.cellSizeMeters
                )
                for angularIndex in 0..<Int((360 / step).rounded()) where result.count < count {
                    result.append(.init(ring: ring, angularIndex: angularIndex))
                }
            }
            return Set(result)
        }
        func averageMilliseconds(grid: MetricSquareGrid) -> Double {
            let moving = cells(count: 200, grid: grid)
            let workspace = SpatialInstrumentWorkspace(grid: grid, layers: [.init(name: "Move", color: .orange, polarCells: moving)])
            for _ in 0..<10 { _ = PolarCellMove.applying(radialSteps: 1, angularSteps: 0, cells: moving, layerIDs: [], to: workspace) }
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<100 { _ = PolarCellMove.applying(radialSteps: 1, angularSteps: 0, cells: moving, layerIDs: [], to: workspace) }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 100_000_000
        }

        let quarterMeter = averageMilliseconds(grid: .quarterMeter)
        let oneCentimeter = averageMilliseconds(grid: .oneCentimeter)
        print("Move preview 200 cells: 25 cm \(quarterMeter) ms; 1 cm \(oneCentimeter) ms")
        XCTAssertLessThan(quarterMeter, 8)
        XCTAssertLessThan(oneCentimeter, 8)
    }

    func testDuplicateAndPasteFreshenIDsAndKeepSceneContract() {
        let routing = SpatialRouting(target: .midiNote(channel: 0), program: .constant(0.5))
        let original = SpatialInstrumentLayer(name: "Lead", color: .orange,
                                              polarCells: [.init(ring: 1, angularIndex: 2)], routings: [routing])
        let scene = SpatialScene(name: "Verse", activeLayerIDs: [original.id])
        var workspace = SpatialInstrumentWorkspace(layers: [original], preserveLayerStructure: true,
                                                   scenes: [scene], currentSceneID: scene.id)
        let duplicateID = try! XCTUnwrap(workspace.duplicateSelectedLayer())
        let duplicate = try! XCTUnwrap(workspace.layers.first { $0.id == duplicateID })
        XCTAssertEqual(duplicate.name, "Lead copy")
        XCTAssertEqual(duplicate.polarCells, original.polarCells)
        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertNotEqual(duplicate.routings[0].id, original.routings[0].id)
        XCTAssertTrue(workspace.scenes[0].activeLayerIDs.contains(duplicateID))

        let pasted = workspace.insertCopiedLayers([original])
        XCTAssertEqual(pasted.count, 1)
        XCTAssertNotEqual(pasted[0], original.id)
        XCTAssertTrue(workspace.scenes[0].activeLayerIDs.contains(pasted[0]))
    }

    func testPasteWithoutSceneDoesNotChangeCopiedLayerActivity() {
        let original = SpatialInstrumentLayer(name: "Muted", color: .orange, isActive: false,
                                              polarCells: [.init(ring: 2, angularIndex: 4)])
        var workspace = SpatialInstrumentWorkspace(layers: [original], preserveLayerStructure: true)

        let pasted = try! XCTUnwrap(workspace.insertCopiedLayers([original]).first)

        XCTAssertEqual(workspace.layers.first { $0.id == pasted }?.isActive, false)
    }
}

extension SpatialInstrumentWorkspaceTests {
    func testLayerPaletteCyclesTwentyFourWithoutRecoloringStoredLayersAndSeventeenthIsNew() throws {
        var workspace = SpatialInstrumentWorkspace()
        for _ in 1..<24 { _ = workspace.addLayer() }
        let colors = workspace.layers.map(\.color)
        XCTAssertEqual(colors, SpatialLayerColor.palette)
        XCTAssertFalse(colors.prefix(16).contains(colors[16]))
        _ = workspace.addLayer(); XCTAssertEqual(workspace.layers.last?.color, colors[0])
        let custom = SpatialLayerColor(red: 0.137, green: 0.28, blue: 0.691)
        workspace.updateSelectedLayer { $0.color = custom }
        let restored = try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(restored.layers.map(\.color), workspace.layers.map(\.color))
    }
    func testLayerPaletteSeparationAndDarkFieldContrast() {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        func lab(_ color: SpatialLayerColor) -> [Double] {
            let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
            func f(_ v: Double) -> Double { v > 216.0 / 24389 ? pow(v, 1.0 / 3) : (24389.0 / 27 * v + 16) / 116 }
            let x = f((0.4124564*r + 0.3575761*g + 0.1804375*b) / 0.95047)
            let y = f(0.2126729*r + 0.7151522*g + 0.072175*b)
            let z = f((0.0193339*r + 0.119192*g + 0.9503041*b) / 1.08883)
            return [116*y - 16, 500*(x-y), 200*(y-z)]
        }
        func luminance(_ c: SpatialLayerColor) -> Double { 0.2126*linear(c.red) + 0.7152*linear(c.green) + 0.0722*linear(c.blue) }
        let palette = SpatialLayerColor.palette
        XCTAssertEqual(palette.count, 24)
        let background = luminance(.init(red: 0.085, green: 0.085, blue: 0.095))
        var minimum = Double.infinity, contrast = Double.infinity
        for (index, color) in palette.enumerated() {
            contrast = min(contrast, (luminance(color) + 0.05) / (background + 0.05))
            for other in palette.dropFirst(index + 1) {
                let delta = sqrt(zip(lab(color), lab(other)).reduce(0) { $0 + pow($1.0 - $1.1, 2) })
                minimum = min(minimum, delta)
            }
        }
        print("RUNDE-G palette min DeltaE76=\(minimum), min dark-field contrast=\(contrast)")
        XCTAssertGreaterThan(minimum, 15)
        XCTAssertGreaterThan(contrast, 3)
    }
}
