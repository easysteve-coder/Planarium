import XCTest
import PlanariumDomain
import PlanariumPresets
@testable import SickPLSMonitorKit

final class FieldContractTests: XCTestCase {
    func testChordTypesInEveryInversionAndWideVoicingAndBass() {
        let types: [(String,[Int])] = [("C",[0,4,7]),("Cm",[0,3,7]),("C°",[0,3,6]),("C+",[0,4,8]),
            ("C7",[0,4,7,10]),("Cmaj7",[0,4,7,11]),("Cm7",[0,3,7,10]),("Cm7♭5",[0,3,6,10]),
            ("C°7",[0,3,6,9]),("Csus2",[0,2,7]),("Csus4",[0,5,7]),("C6",[0,4,7,9]),("Cm6",[0,3,7,9])]
        for (name, intervals) in types {
            for inversion in intervals.indices {
                let notes = intervals.enumerated().map { 60+$0.element+($0.offset < inversion ? 12 : 0) }.sorted()
                let expected = name == "C+" || name == "C°7" ? MIDINoteName.pitchClassName(for: notes[0]) + (name == "C+" ? "+" : "°7") : name
                XCTAssertEqual(SpatialCellLabel.chordName(notes: notes, preferredName: expected), expected, "\(name) inversion \(inversion)")
                let wide = notes.enumerated().map { $0.element + $0.offset*12 }
                XCTAssertEqual(SpatialCellLabel.chordName(notes: wide, preferredName: expected), expected, "\(name) wide inversion \(inversion)")
            }
        }
        XCTAssertEqual(SpatialCellLabel.chordName(notes: [48,60,65,68]), "Fm/C")
        XCTAssertEqual(SpatialCellLabel.chordName(notes: [45,62,66,69]), "D/A")
        XCTAssertEqual(SpatialCellLabel.chordName(notes: [45,62,65,70]), "B♭/A")
        XCTAssertEqual(SpatialCellLabel.chordName(notes: [60,64,69]), "Am")
        XCTAssertEqual(SpatialCellLabel.text(for: .notes([.init(number: 60, velocity: 100),.init(number: 61, velocity: 100),.init(number: 66, velocity: 100)], transition: .legato), target: .midiNote(channel: 0)), "C4 +2")
    }
    func testPureRecognitionFindsUnambiguousInversionsWithoutLayerContext() {
        let examples: [(String,[Int])] = [("C",[0,4,7]),("Cm",[0,3,7]),("C°",[0,3,6]),
            ("C7",[0,4,7,10]),("Cmaj7",[0,4,7,11])]
        for (name, intervals) in examples {
            for inversion in intervals.indices {
                let notes = intervals.enumerated().map { 60+$0.element+($0.offset < inversion ? 12 : 0) }.sorted()
                XCTAssertEqual(SpatialCellLabel.chordName(notes: notes),name,"\(name) inversion \(inversion)")
            }
        }
    }
    func testAllFourteenHarmonyPresetsMatchLayerNames() throws {
        let names = ["Ruhe und Spannung","Sehnsucht","Episch","Moll-Dreieck","Andalusisch","Modus-Schalter","Hexatonik-Stern","Terz-Ring","Goetterakkorde","Tritonus-Bruecke","Drehtuer","Liegender Ton C","Spuk","Pop-Netz"]
        for (index, name) in names.enumerated() {
            let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: String(format: "Harmonie %02d ", index+1)+name))
            let doc = try JSONDecoder().decode(InstrumentPresetV6.self, from: data).document
            for layer in doc.spatial.layers {
                guard case let .chord(notes,_,_) = layer.routings.first?.program else { return XCTFail("Missing chord") }
                let expected = layer.name.replacingOccurrences(of: "b", with: "♭").replacingOccurrences(of: "#", with: "♯")
                XCTAssertEqual(SpatialCellLabel.chordName(notes: notes, preferredName: layer.name), expected, "Preset \(index+1) layer \(layer.name)")
            }
        }
    }
    func testAmbiguousSetsAndInvalidLayerNamesHaveDeterministicFallback() {
        XCTAssertEqual(SpatialCellLabel.chordName(notes: [60,64,67,69]), "Am7")
        XCTAssertEqual(SpatialCellLabel.chordName(notes: [60,63,67,69]), "Am7♭5")
        XCTAssertEqual(SpatialCellLabel.chordName(notes: [60,62,67]), "Csus2")
        XCTAssertEqual(SpatialCellLabel.chordName(notes: [60,64,67,69], preferredName: "C6"), "C6")
        XCTAssertEqual(SpatialCellLabel.chordName(notes: [60,64,69], preferredName: "F"), "Am")
        XCTAssertEqual(SpatialCellLabel.chordName(notes: [56,60,63], preferredName: "G#"), "G♯")
        XCTAssertEqual(SpatialCellLabel.chordName(notes: [56,60,63], preferredName: "Ab"), "A♭")
    }
    private func layer(_ cells: Set<PolarMetricGridCell>, name: String = "C", note: [Int] = [60,64,67]) -> SpatialInstrumentLayer {
        .init(name: name, color: .orange, polarCells: cells,
              routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: note, velocity: 100, transition: .legato))])
    }
    func testAudibleOverlapOwnsLabelAndTopFillBeforeAndAfterSceneSwitchEvenWhenMutedIsSelected() {
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 9)
        let a = layer([cell], name: "C"), b = layer([cell], name: "Cm", note: [60,63,67])
        for layers in [[a,b], [b,a]] {
            var workspace = SpatialInstrumentWorkspace(grid: .quarterMeter, layers: layers)
            workspace.updateLayer(b.id) { $0.isActive = false }
            let day = workspace.addScene(name: "Day")
            workspace.updateLayer(a.id) { $0.isActive = false }
            workspace.updateLayer(b.id) { $0.isActive = true }
            let night = workspace.addScene(name: "Night")
            var plan = SpatialFieldPlan(workspace: workspace)
            let geometryID = plan.identity
            for (scene, sounding, muted, title) in [(day, a.id, b.id, "C"), (night, b.id, a.id, "Cm"), (day, a.id, b.id, "C")] {
                workspace.selectScene(scene)
                workspace.selectLayer(muted)
                for performing in [false, true] {
                    var state = MetricCanvasInteractionState(); state.projectWorkspace(workspace)
                    state.setPerformanceLocked(performing)
                    plan.updateAudibility(workspace: state.workspace)
                    XCTAssertEqual(plan.identity, geometryID)
                    XCTAssertEqual(plan.paintOrder(selectedLayerID: muted).map(\.id), [muted, sounding])
                    let labels = plan.labels(selectedLayerID: muted)
                    XCTAssertEqual(labels.map { plan.regions[$0.regionIndex].layerID }, [sounding])
                    XCTAssertEqual(labels.map { plan.regions[$0.regionIndex].label }, [title])
                    XCTAssertEqual(plan.audibilityOpacity[muted], 0.3)
                    XCTAssertEqual(plan.regions.count, 2, "Muted geometry must remain underneath and editable")
                }
            }
            workspace.updateLayer(a.id) { $0.isActive = true; $0.isSoloed = false }
            workspace.updateLayer(b.id) { $0.isActive = true; $0.isSoloed = true }
            plan.updateAudibility(workspace: workspace)
            let solo = plan
            XCTAssertEqual(solo.identity, geometryID)
            XCTAssertEqual(solo.paintOrder(selectedLayerID: a.id).map(\.id), [a.id, b.id])
            XCTAssertEqual(solo.labels(selectedLayerID: a.id).map { solo.regions[$0.regionIndex].label }, ["Cm"])
        }
    }
    func testSwitchLabelsUsePerCellTargetsAndKeepDifferentActionsInSeparateRegions() {
        let cells = (9...13).map { PolarMetricGridCell(ring: 3, angularIndex: $0) }
        var control = layer(Set(cells), name: "Switch")
        let day = SpatialScene(name: "Day", activeLayerIDs: []), night = SpatialScene(name: "Night", activeLayerIDs: [])
        let target = SpatialRoutingTarget.sceneSwitch(action: .next, dwellSeconds: 0.2)
        control.routings = [.init(target: target, program: .constant(1))]
        for (cell, action) in zip(cells.dropFirst(), [SpatialSceneSwitchAction.previous, .scene(day.id), .scene(night.id), .scene(UUID())]) {
            control.polarCellOverrides[cell] = [.init(target: target, value: .sceneSwitch(action: action))]
        }
        let plan = SpatialFieldPlan(workspace: .init(grid: .quarterMeter, layers: [control], scenes: [day, night]))
        XCTAssertEqual(plan.regions.map(\.label), ["Next", "Previous", "Day", "Night", "missing scene"])
        XCTAssertEqual(plan.regions.map(\.cells), cells.map { [$0] })
        XCTAssertEqual(plan.regions.map(\.hasOwnValue), [false, true, true, true, true])
    }
    func testSeparateComponentsAndLayersGetSeparateLabels() {
        let cells: Set<PolarMetricGridCell> = [.init(ring: 3, angularIndex: 9), .init(ring: 3, angularIndex: 10), .init(ring: 3, angularIndex: 13)]
        let a = layer(cells), b = layer(cells)
        let plan = SpatialFieldPlan(workspace: .init(grid: .quarterMeter, layers: [a,b]))
        XCTAssertEqual(plan.regions.count, 4)
        XCTAssertTrue(plan.regions.allSatisfy { $0.label == "C" })
        XCTAssertEqual(plan.regions.filter { $0.layerID == a.id }.count, 2)
        XCTAssertEqual(plan.regions.filter { plan.labelCell(for: $0, selectedLayerID: a.id) != nil }.count, 2)
        XCTAssertTrue(plan.regions.filter { $0.layerID == b.id }.allSatisfy { plan.labelCell(for: $0, selectedLayerID: UUID()) != nil })
    }
    func testThreeVisibleLayersAllHaveLabelsWithSelectedAtFullOpacity() {
        let a = layer([.init(ring: 3,angularIndex: 9)]), b = layer([.init(ring: 3,angularIndex: 11)]), c = layer([.init(ring: 3,angularIndex: 13)])
        let plan = SpatialFieldPlan(workspace: .init(grid: .quarterMeter,layers: [a,b,c]))
        let labels = plan.labels(selectedLayerID: b.id)
        XCTAssertEqual(labels.count,3)
        XCTAssertEqual(labels.map(\.opacity),[0.6,1,0.6])
    }
    func testMuteAndSoloPresentationUsesTheCompilerAudibilityRuleAndKeepsCellsEditable() throws {
        let cell = PolarMetricGridCell(ring: 3,angularIndex: 9)
        let a = layer([cell]), b = layer([.init(ring: 3,angularIndex: 11)])
        var workspace = SpatialInstrumentWorkspace(grid: .quarterMeter,layers: [a,b])
        for (active, ownSolo, otherSolo, otherActive, expected) in [
            (true,false,false,true,1.0), (false,false,false,true,0.3),
            (true,false,true,true,0.3), (true,true,true,true,1.0),
            (true,false,true,false,1.0), (true,false,false,true,1.0)
        ] {
            workspace.updateLayer(a.id) { $0.isActive = active; $0.isSoloed = ownSolo }
            workspace.updateLayer(b.id) { $0.isActive = otherActive; $0.isSoloed = otherSolo }
            let plan = SpatialFieldPlan(workspace: workspace)
            XCTAssertEqual(plan.audibilityOpacity[a.id],expected)
            let ownLabels = plan.labels(selectedLayerID: a.id).filter { plan.regions[$0.regionIndex].layerID == a.id }
            XCTAssertEqual(ownLabels.count, expected == 1 ? 1 : 0)
            if expected == 1 { XCTAssertEqual(ownLabels.first?.opacity, 1) }
            XCTAssertEqual(plan.regions.count,2)
            let document = try SpatialDocument(latticeVersion: .polarDeviceV2,layers: workspace.layers.map {
                .init(id: $0.id,name: $0.name,color: $0.color,isVisible: $0.isVisible,isActive: $0.isActive,
                      isLocked: $0.isLocked,isSoloed: $0.isSoloed,cells: [],routings: [],cellOverrides: [:])
            },selectedLayerID: a.id)
            let compiled = try SpatialInstrumentCompiler.compile(document,revision: .newSession())
            XCTAssertEqual(Set(compiled.layers.map(\.id)),Set(plan.audibilityOpacity.filter { $0.value == 1 }.map(\.key)))
            XCTAssertEqual(SpatialInstrumentEvaluator().evaluate(activeCells: [a.id:cell],workspace: workspace).contains { $0.routingID == a.routings[0].id },expected == 1)
            var state = MetricCanvasInteractionState(); state.projectWorkspace(workspace)
            let size = CGSize(width: 800,height: 800), p = SpatialFieldPlan.center(.init(cell: cell,grid: .quarterMeter))
            let point = MetricCanvasGeometry(size: size,viewport: state.viewport).screenPoint(for: .init(xMeters: p.x,yMeters: p.y))
            _ = state.selectCell(atScreenPoint: point,canvasSize: size)
            XCTAssertEqual(state.selectedPolarCell,cell); XCTAssertNil(state.command)
        }
        workspace.updateLayer(b.id) { $0.isSoloed = true; $0.isActive = true; $0.isVisible = false }
        let hiddenSolo = SpatialFieldPlan(workspace: workspace)
        XCTAssertEqual(hiddenSolo.regions.count,1); XCTAssertEqual(hiddenSolo.audibilityOpacity[a.id],0.3)
        XCTAssertTrue(hiddenSolo.labels(selectedLayerID: a.id).isEmpty)
    }
    func testAdjacentSameValueOneFormWithoutInternalEdgeAndCellModeKeepsCells() throws {
        let a = PolarMetricGridCell(ring: 3, angularIndex: 9), b = PolarMetricGridCell(ring: 3, angularIndex: 10)
        let plan = SpatialFieldPlan(workspace: .init(grid: .quarterMeter, layers: [layer([a,b])]))
        let region = try XCTUnwrap(plan.regions.first)
        XCTAssertEqual(plan.regions.count, 1); XCTAssertEqual(region.cellPaths.count, 2)
        XCTAssertFalse(region.boundary.contains(.radial(inner: 0.75, outer: 1, bearing: -67.5)))
        XCTAssertEqual(region.boundary.filter { if case .radial = $0 { return true }; return false }.count, 2)
    }
    func testRingStepHalvingProducesOneFormAndOnlyExteriorArcs() throws {
        // Ring 0 has 45°, ring 1 22.5°; one inner cell meets two outer cells.
        let inner = PolarMetricGridCell(ring: 0, angularIndex: 2)
        let outer = [PolarMetricGridCell(ring: 1, angularIndex: 4), .init(ring: 1, angularIndex: 5)]
        let plan = SpatialFieldPlan(workspace: .init(grid: .quarterMeter, layers: [layer(Set([inner]+outer))]))
        XCTAssertEqual(plan.regions.count, 1)
        XCTAssertFalse(plan.regions.flatMap(\.boundary).contains { if case let .arc(radius,_,_) = $0 { return radius == 0.25 }; return false })
    }
    func testHolePreservesInnerOutlineAndLabelIsInsideRegion() throws {
        var cells = Set<PolarMetricGridCell>()
        // Rings 4...6 all use 11.25°. Omit the middle cell of a 3×3 block.
        for ring in 4...6 { for angle in 10...12 where !(ring == 5 && angle == 11) { cells.insert(.init(ring: ring, angularIndex: angle)) } }
        let plan = SpatialFieldPlan(workspace: .init(grid: .quarterMeter, layers: [layer(cells)]))
        let region = try XCTUnwrap(plan.regions.first)
        XCTAssertEqual(plan.regions.count, 1)
        XCTAssertFalse(region.fill.contains(SpatialFieldPlan.center(.init(cell: .init(ring: 5, angularIndex: 11), grid: .quarterMeter))))
        XCTAssertTrue(region.fill.contains(region.center))
        XCTAssertTrue(region.boundary.contains(.arc(radius: 1.25, start: -56.25, end: -45)))
        XCTAssertTrue(region.boundary.contains(.arc(radius: 1.5, start: -56.25, end: -45)))
    }
    func testFiveCentimeterBatchedFillAndCellMeshKeepHolesAndHitCoverage() {
        let grid = MetricSquareGrid.CellSize.fiveCentimeter.grid
        var cells: Set<PolarMetricGridCell> = []
        for ring in 10..<40 {
            let step = PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: Double(ring + 1) * grid.cellSizeMeters, radialHeightMeters: grid.cellSizeMeters)
            for index in Int(150 / step)..<Int(210 / step) {
                let cell = PolarMetricGridCell(ring: ring, angularIndex: index)
                let middle = PolarMetricCellSegment(cell: cell, grid: grid).midpoint
                if !(20...24).contains(ring) || abs(middle.bearingDegrees) > 5 { cells.insert(cell) }
            }
        }
        let plan = SpatialFieldPlan(workspace: .init(grid: grid, layers: [layer(cells)]))
        for radius in stride(from: 0.4137, through: 2.1, by: 0.031) {
            for angle in stride(from: -34.71, through: 34.8, by: 2.37) {
                let point = MetricScanPoint(xMeters: sin(angle * .pi / 180) * radius, yMeters: cos(angle * .pi / 180) * radius)
                let expected = cells.contains(PolarMetricGridCell(point: point, grid: grid))
                let cg = CGPoint(x: point.xMeters, y: point.yMeters)
                XCTAssertEqual(plan.regions.contains { $0.fill.contains(cg) }, expected, "r=\(radius) angle=\(angle)")
                XCTAssertEqual(plan.regions.contains { $0.cellMesh.contains(cg) }, expected, "r=\(radius) angle=\(angle)")
            }
        }
    }

    func testNativeCircularFillKeepsSubMillimeterRadialEdges() {
        let grid = MetricSquareGrid.CellSize.fiveCentimeter.grid
        let step = PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: 1.05, radialHeightMeters: 0.05)
        let cells = Set((Int(157.5 / step)..<Int(202.5 / step)).map { PolarMetricGridCell(ring: 20, angularIndex: $0) })
        let plan = SpatialFieldPlan(workspace: .init(grid: grid, layers: [layer(cells)]))
        for angle in stride(from: -20.1, through: 20.2, by: 1.37) {
            for (radius, expected) in [(0.9999, false), (1.0001, true), (1.0499, true), (1.0501, false)] {
                let point = CGPoint(x: sin(angle * .pi / 180) * radius, y: cos(angle * .pi / 180) * radius)
                XCTAssertEqual(plan.regions.contains { $0.fill.contains(point) }, expected)
            }
        }
    }

    func testMergedStylingLeavesHitTestingAndDocumentBytesUnchanged() throws {
        let cell = PolarMetricGridCell(ring: 3,angularIndex: 10)
        var state = MetricCanvasInteractionState()
        state.projectWorkspace(.init(grid: .quarterMeter,layers: [layer([cell])]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(state.workspace)
        let size = CGSize(width: 800,height: 800)
        let center = SpatialFieldPlan.center(.init(cell: cell,grid: .quarterMeter))
        let point = MetricCanvasGeometry(size: size,viewport: state.viewport).screenPoint(for: .init(xMeters: center.x,yMeters: center.y))
        for merge in [true,false] {
            state.mergeZones = merge
            state.showRawScan = !merge
            _ = state.selectCell(atScreenPoint: point,canvasSize: size)
            XCTAssertEqual(state.selectedPolarCell,cell)
            XCTAssertEqual(try encoder.encode(state.workspace),bytes)
            XCTAssertNil(state.command)
        }
    }
    func testClickSelectsVisibleUnlockedLayerWithoutUndoAndBrushRectangleKeepLayer() {
        let aCell = PolarMetricGridCell(ring: 3, angularIndex: 9), bCell = PolarMetricGridCell(ring: 3, angularIndex: 10)
        let a = layer([aCell]), b = layer([bCell]), c = layer([bCell])
        var state = MetricCanvasInteractionState()
        state.projectWorkspace(.init(grid: .quarterMeter, layers: [a,b,c]))
        let size = CGSize(width: 800, height: 800)
        func point(_ cell: PolarMetricGridCell) -> CGPoint {
            let p = SpatialFieldPlan.center(.init(cell: cell, grid: .quarterMeter))
            return MetricCanvasGeometry(size: size, viewport: state.viewport).screenPoint(for: .init(xMeters: p.x, yMeters: p.y))
        }
        _ = state.selectCell(atScreenPoint: point(bCell), canvasSize: size)
        XCTAssertEqual(state.workspace.selectedLayerID, c.id); XCTAssertEqual(state.selectedPolarCells, [bCell]); XCTAssertNil(state.command)
        state.updateWorkspace { $0.selectLayer(b.id) }
        _ = state.selectCell(atScreenPoint: point(bCell), canvasSize: size)
        XCTAssertEqual(state.workspace.selectedLayerID, c.id)
        _ = state.selectCell(atScreenPoint: point(.init(ring: 3, angularIndex: 12)), canvasSize: size)
        XCTAssertEqual(state.workspace.selectedLayerID, c.id)
        state.updateWorkspace { $0.selectLayer(a.id) }
        _ = state.selectCell(atScreenPoint: point(bCell), canvasSize: size, modifiers: .option)
        XCTAssertEqual(state.workspace.selectedLayerID, c.id)
        let start = point(bCell)
        state.beginDrag(at: start, canvasSize: size, modifiers: [])
        state.updateDrag(to: .init(x: start.x+20,y: start.y+20), canvasSize: size)
        state.endDrag(canvasSize: size)
        XCTAssertEqual(state.workspace.selectedLayerID, c.id)
        var hidden = c; hidden.isVisible = false
        var locked = b; locked.isLocked = true
        state.projectWorkspace(.init(grid: .quarterMeter, layers: [a,locked,hidden]))
        _ = state.selectCell(atScreenPoint: point(bCell), canvasSize: size)
        XCTAssertEqual(state.workspace.selectedLayerID, a.id)
        locked.isLocked = false
        state.projectWorkspace(.init(grid: .quarterMeter, layers: [a,locked,hidden]))
        _ = state.selectCell(atScreenPoint: point(bCell), canvasSize: size)
        XCTAssertEqual(state.workspace.selectedLayerID, b.id)
    }
    func testPreparedLabelSelectionsMatchOwnershipOracleAcrossOverlapMuteSoloHiddenAndReplacement() {
        let cells: Set<PolarMetricGridCell> = [.init(ring: 3, angularIndex: 9), .init(ring: 3, angularIndex: 10)]
        let a = layer(cells, name: "C"), b = layer(cells, name: "Cm", note: [60, 63, 67])
        let c = layer([.init(ring: 4, angularIndex: 13)], name: "G", note: [67, 71, 74])
        for order in [[a, b, c], [b, a, c]] {
            var workspace = SpatialInstrumentWorkspace(layers: order)
            for mode in 0..<5 {
                workspace.updateLayer(b.id) {
                    $0.isActive = mode != 1
                    $0.isSoloed = mode == 2
                    $0.isVisible = mode != 3
                }
                if mode == 4 {
                    workspace.updateLayer(a.id) {
                        $0.name = "C7"
                        $0.routings[0].program = .chord(notes: [60, 64, 67, 70], velocity: 100, transition: .legato)
                    }
                }
                let plan = SpatialFieldPlan(workspace: workspace)
                for selected in [a.id, b.id, c.id, UUID(), a.id] {
                    let labels = plan.labels(selectedLayerID: selected)
                    // The existing per-region ownership calculation is an
                    // independent, uncached oracle for each prepared state.
                    let expected = plan.regions.enumerated().compactMap { index, region -> (Int, PolarMetricGridCell)? in
                        guard region.label != nil, let cell = plan.labelCell(for: region, selectedLayerID: selected) else { return nil }
                        return (index, cell)
                    }
                    XCTAssertEqual(labels.map(\.regionIndex), expected.map { $0.0 })
                    XCTAssertEqual(labels.map(\.cell), expected.map { $0.1 })
                    for label in labels {
                        let region = plan.regions[label.regionIndex]
                        XCTAssertEqual(label.center, SpatialFieldPlan.center(.init(cell: label.cell, grid: plan.grid)))
                        XCTAssertEqual(label.opacity, (region.layerID == selected ? 1 : 0.6) * plan.audibilityOpacity[region.layerID, default: 1])
                    }
                }
            }
        }
    }

}
