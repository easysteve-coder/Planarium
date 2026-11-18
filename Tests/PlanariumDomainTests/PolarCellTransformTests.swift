import XCTest
@testable import PlanariumDomain
import SickPLSMonitorKit

final class PolarCellTransformTests: XCTestCase {
    private func zone(grid: MetricSquareGrid = .quarterMeter, rings: Range<Int> = 2..<4,
                      bearings: ClosedRange<Double> = -22.5...22.5) -> Set<PolarMetricGridCell> {
        var cells: Set<PolarMetricGridCell> = []
        for ring in rings {
            let step = PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: Double(ring + 1) * grid.cellSizeMeters, radialHeightMeters: grid.cellSizeMeters)
            for index in 0..<Int(360 / step) {
                let cell = PolarMetricGridCell(ring: ring, angularIndex: index)
                let segment = PolarMetricCellSegment(cell: cell, grid: grid)
                if bearings.contains(segment.midpoint.bearingDegrees) { cells.insert(cell) }
            }
        }
        return cells
    }
    private func workspace(_ cells: Set<PolarMetricGridCell>, grid: MetricSquareGrid = .quarterMeter) -> SpatialInstrumentWorkspace {
        .init(grid: grid, layers: [.init(name: "Zone", color: .orange, polarCells: cells)])
    }
    private func contour(count: Int, wall: UInt16? = 60) -> SpatialRoomContour {
        .init(geometry: .init(pointCount: count, angleResolutionDegrees: 180 / Double(count - 1), startAngleDegrees: -90, sourceIdentifier: "test"),
              nearestDistancesCentimeters: Array(repeating: wall, count: count), spreadCentimeters: Array(repeating: 0, count: count))
    }

    func testMoveClampsEachAxisToLargestFeasibleStepThroughSelectDragAndUndo() throws {
        let cells = zone(rings: 3..<5, bearings: -22.5...0)
        var state = MetricCanvasInteractionState()
        state.replaceWorkspace(workspace(cells))
        XCTAssertTrue(state.perform(.selectAll))
        let before = state.workspace, size = CGSize(width: 800, height: 800)
        let cell = try XCTUnwrap(state.selectedPolarCells.sorted(by: PolarCellMove.addressOrder).first)
        let geometry = MetricCanvasGeometry(size: size, viewport: state.viewport)
        let middle = PolarMetricCellSegment(cell: cell, grid: before.grid).midpoint
        let start = geometry.screenPoint(for: .init(xMeters: sin(middle.bearingDegrees * .pi / 180) * middle.radiusMeters,
                                                  yMeters: cos(middle.bearingDegrees * .pi / 180) * middle.radiusMeters))
        let end = geometry.screenPoint(for: .init(xMeters: sin(middle.bearingDegrees * .pi / 180) * 3,
                                                yMeters: cos(middle.bearingDegrees * .pi / 180) * 3))
        XCTAssertTrue(state.beginDrag(at: start, canvasSize: size))
        XCTAssertTrue(state.updateDrag(to: end, canvasSize: size))
        XCTAssertEqual(Set(state.movePreviewCells.map(\.ring)), [6, 7])
        XCTAssertTrue(state.moveHitBoundary)
        state.endDrag(canvasSize: size)
        XCTAssertNotEqual(state.workspace, before)
        XCTAssertEqual(Set(state.workspace.selectedLayer.polarCells.map(\.ring)), [6, 7])
        let after = state.workspace
        let command = try XCTUnwrap(state.command)
        XCTAssertEqual(command.before, before)
        XCTAssertEqual(command.after, after)
        XCTAssertEqual(command.name, "Move cells")

        let atEdge = PolarCellMove.applying(radialSteps: 100, angularSteps: 1, cells: after.selectedLayer.polarCells, layerIDs: [], to: after)
        XCTAssertTrue(atEdge.didHitBoundary)
        XCTAssertNotEqual(atEdge.workspace, after, "A blocked radial axis must not suppress a feasible angular axis")
        XCTAssertEqual(Set(atEdge.cells.map(\.ring)), [6, 7])
    }

    func testAffineRadialAndAngularExpansionFillsEveryCoveredTargetWithExactlyOneSource() throws {
        let cells = zone(), source = workspace(cells)
        let actions = cells.sorted(by: PolarCellMove.addressOrder).enumerated().map { index, cell in
            (cell, [SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 50 + index, velocity: 90))])
        }
        var withValues = source
        withValues.updateSelectedLayer { $0.polarCellOverrides = Dictionary(uniqueKeysWithValues: actions) }
        let bounds = try XCTUnwrap(PolarCellTransform.bounds(cells: cells, grid: source.grid))
        let transform = PolarCellTransform(radialOrigin: bounds.innerRadiusMeters, radialTarget: bounds.innerRadiusMeters,
            radialScale: 2, angularOrigin: bounds.startBearingDegrees, angularTarget: bounds.startBearingDegrees, angularScale: 2)
        let result = PolarCellTransform.applying(transform, cells: cells, layerIDs: [], to: withValues)
        let expected = zone(rings: 2..<6, bearings: -22.5...67.5)
        XCTAssertEqual(result.cells, expected, "Expansion must fill the entire formerly closed zone")
        XCTAssertEqual(Set(result.workspace.selectedLayer.polarCellOverrides.keys), expected)
        XCTAssertTrue(result.workspace.selectedLayer.polarCellOverrides.values.allSatisfy { $0.count == 1 })
        let values = actions.map { $0.1[0].value }
        XCTAssertTrue(result.workspace.selectedLayer.polarCellOverrides.values.allSatisfy { values.contains($0[0].value) })
    }

    func testCompressionUsesExistingNearestCentreAndAddressTieWinnerForOverrides() {
        let a = PolarMetricGridCell(ring: 2, angularIndex: 8), b = PolarMetricGridCell(ring: 3, angularIndex: 16)
        let action = SpatialCellAction(target: .sceneSwitch(action: .next, dwellSeconds: 0.5), value: .sceneSwitch(action: .next))
        var source = workspace([a, b])
        source.updateSelectedLayer { $0.polarCellOverrides = [a: [], b: [action]] }
        let transform = PolarCellTransform(radialScale: 0.5)
        let result = PolarCellTransform.applying(transform, cells: [a, b], layerIDs: [], to: source)
        XCTAssertEqual(result.workspace.selectedLayer.polarCellOverrides[.init(ring: 1, angularIndex: 8)], [], "Nearest transformed source wins, including an explicit empty override")
        let shifted = Dictionary(uniqueKeysWithValues: [a, b].map { ($0, transform.segment(.init(cell: $0, grid: source.grid))) })
        for target in result.cells {
            let candidates = [a, b].filter { PolarCellMove.targetCells(for: shifted[$0]!, grid: source.grid).contains(target) }
            let winner = candidates.sorted { PolarCellMove.isBetterWinner($0, than: $1, for: target, shifted: shifted, grid: source.grid) }.first!
            XCTAssertEqual(result.workspace.selectedLayer.polarCellOverrides[target], source.selectedLayer.polarCellOverrides[winner])
        }
    }

    func testTransformClampsExpansionAtAllEdgesAndNeverCollapsesBelowRingOrSegment() throws {
        let cells = zone(), source = workspace(cells)
        for transform in [PolarCellTransform(radialTarget: -10, radialScale: 0.001, angularTarget: -500, angularScale: 0.001),
                          .init(radialTarget: 10, radialScale: 20, angularTarget: 500, angularScale: 20)] {
            let result = PolarCellTransform.applying(transform, cells: cells, layerIDs: [], to: source)
            XCTAssertTrue(result.didHitBoundary)
            let bounds = try XCTUnwrap(PolarCellTransform.bounds(cells: result.cells, grid: source.grid))
            XCTAssertGreaterThanOrEqual(bounds.innerRadiusMeters, 0)
            XCTAssertLessThanOrEqual(bounds.outerRadiusMeters, 2)
            XCTAssertGreaterThanOrEqual(bounds.startBearingDegrees, -90)
            XCTAssertLessThanOrEqual(bounds.endBearingDegrees, 90)
            XCTAssertGreaterThanOrEqual(bounds.radialHeightMeters, source.grid.cellSizeMeters)
            XCTAssertFalse(result.cells.isEmpty)
        }
        XCTAssertEqual(PolarCellTransform.applying(.init(radialScale: .nan), cells: cells, layerIDs: [], to: source).workspace, source)
    }

    func testWholeLayerScopeDoesNotDependOnCellSelectionAndLeavesOtherLayersAndMetadataUntouched() {
        let a = SpatialInstrumentLayer(name: "A", color: .orange, polarCells: zone())
        let b = SpatialInstrumentLayer(name: "B", color: .blue, polarCells: zone(rings: 4..<6))
        let c = SpatialInstrumentLayer(name: "C", color: .green, polarCells: zone(rings: 6..<7))
        let scene = SpatialScene(name: "Scene", activeLayerIDs: [a.id, b.id])
        let source = SpatialInstrumentWorkspace(grid: .quarterMeter, layers: [a, b, c], scenes: [scene])
        XCTAssertEqual(PolarCellMove.applying(radialSteps: 0, angularSteps: 0, cells: [], layerIDs: [a.id, b.id], to: source).cells,
                       a.polarCells.union(b.polarCells), "A zero-step preview still represents the complete layer scope")
        let result = PolarCellTransform.applying(.init(radialScale: 0.5), cells: [], layerIDs: [a.id, b.id], to: source)
        XCTAssertNotEqual(result.workspace.layers[0].polarCells, a.polarCells)
        XCTAssertNotEqual(result.workspace.layers[1].polarCells, b.polarCells)
        XCTAssertEqual(result.workspace.layers[2], c)
        XCTAssertEqual(result.workspace.layers.map(\.id), source.layers.map(\.id))
        XCTAssertEqual(result.workspace.scenes, source.scenes)
        XCTAssertEqual(result.workspace.layers.map(\.routings), source.layers.map(\.routings))
    }

    func testRoomFitRoundRoomMatchesCompressionAndCanExpandToPlayRange() {
        let source = workspace(zone()) // outer radius 1 m
        let fit = SpatialRoomFit.applying(to: source, contour: contour(count: 361))
        XCTAssertEqual(fit.factor, 0.5, accuracy: 1e-12)
        XCTAssertEqual(fit.transform.workspace.selectedLayer.polarCells.map(\.ring).max(), 1)
        let roomy = SpatialRoomFit.applying(to: source, contour: contour(count: 90, wall: 200))
        XCTAssertEqual(roomy.factor, 1.9, accuracy: 1e-12); XCTAssertNotEqual(roomy.transform.workspace, source)
        let missing = SpatialRoomFit.applying(to: source, contour: contour(count: 361, wall: nil))
        XCTAssertEqual(missing.factor, 1); XCTAssertEqual(missing.transform.workspace, source)
        let zeroWall = SpatialRoomFit.applying(to: source, contour: contour(count: 90, wall: 5))
        XCTAssertEqual(zeroWall.factor, 0)
        XCTAssertFalse(zeroWall.transform.cells.isEmpty, "Grid floor is warned rather than blocked")
        XCTAssertFalse(SpatialRoomFit.warnings(in: zeroWall.transform.workspace, contour: contour(count: 90, wall: 5), toleranceCentimeters: 3).outsideCells.isEmpty)
    }

    func testRoomFitMaps90And361ByBearingIncludesNarrowWallAndIgnoresMissingRays() {
        // Negative bearings map to different indices in the two captures.
        let cells = zone(rings: 3..<4, bearings: -45 ... -22.5), source = workspace(cells)
        for count in [90, 361] {
            var values = Array<UInt16?>(repeating: nil, count: count)
            let step = 180 / Double(count - 1)
            for index in values.indices where abs(-90 + Double(index) * step + 30) < 4 { values[index] = 60 }
            let room = SpatialRoomContour(geometry: .init(pointCount: count, angleResolutionDegrees: step, startAngleDegrees: -90, sourceIdentifier: "test"),
                nearestDistancesCentimeters: values, spreadCentimeters: [])
            let fit = SpatialRoomFit.applying(to: source, contour: room)
            XCTAssertEqual(fit.factor, 0.5, accuracy: 1e-12, "\(count) rays must use bearing, never cell indices")
            XCTAssertNotEqual(fit.transform.workspace, source)
            let unknown = zone(rings: 3..<4, bearings: 22.5...45)
            let unknownSource = workspace(unknown)
            XCTAssertEqual(SpatialRoomFit.applying(to: unknownSource, contour: room).transform.workspace, unknownSource)
        }
    }

    func testRoomFitUsesSmallerWallInAnotherHiddenLockedLayerAndPreservesBearingSegments() {
        let near = SpatialInstrumentLayer(name: "Near wall", color: .orange, isVisible: false, isLocked: true,
            polarCells: zone(rings: 2..<3, bearings: -45 ... -22.5))
        let far = SpatialInstrumentLayer(name: "Far wall", color: .blue, polarCells: zone(rings: 7..<8, bearings: 22.5...45))
        var source = SpatialInstrumentWorkspace(grid: .quarterMeter, layers: [near, far])
        source.selectLayer(far.id)
        var values = Array<UInt16?>(repeating: 180, count: 361)
        for index in values.indices where -90 + Double(index) / 2 < 0 { values[index] = 40 }
        let contour = SpatialRoomContour(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5, startAngleDegrees: -90, sourceIdentifier: "test"),
            nearestDistancesCentimeters: values, spreadCentimeters: [])
        let fit = SpatialRoomFit.applying(to: source, contour: contour)
        XCTAssertLessThanOrEqual(fit.factor, 0.4)
        XCTAssertGreaterThan(fit.maximumFactor, fit.factor)
        XCTAssertNotEqual(fit.transform.workspace.layers[0].polarCells, near.polarCells)
        XCTAssertFalse(fit.transform.workspace.layers[0].isVisible)
        XCTAssertTrue(fit.transform.workspace.layers[0].isLocked)
        let transform = PolarCellTransform(radialScale: fit.factor)
        for cell in source.layers.flatMap(\.polarCells) {
            let segment = PolarMetricCellSegment(cell: cell, grid: source.grid)
            XCTAssertEqual(transform.segment(segment).startBearingDegrees, segment.startBearingDegrees)
            XCTAssertEqual(transform.segment(segment).endBearingDegrees, segment.endBearingDegrees)
        }
    }

    func testCompressionPreviewForThreeHundredCellsStaysBelowEightMilliseconds() {
        let grid = MetricSquareGrid.oneCentimeter
        let all = zone(grid: grid, rings: 30..<50, bearings: -40...40)
        let cells = Set(all.sorted(by: PolarCellMove.addressOrder).prefix(300)), source = workspace(cells, grid: grid)
        XCTAssertEqual(cells.count, 300)
        for _ in 0..<10 { _ = PolarCellTransform.applying(.init(radialScale: 0.7), cells: cells, layerIDs: [], to: source) }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<100 { _ = PolarCellTransform.applying(.init(radialScale: 0.7), cells: cells, layerIDs: [], to: source) }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 100_000_000
        print("Compression preview 300 cells: \(milliseconds) ms")
        XCTAssertLessThan(milliseconds, 8)
    }
}
