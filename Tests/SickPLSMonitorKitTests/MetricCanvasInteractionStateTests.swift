import XCTest

// Geometry and dormant-address bulk tests use the reference-field editor’s
// explicit area-selection mode. Instrument ownership is covered by CanvasEditingTests.
import SickPLSControlCore
@testable import SickPLSMonitorKit

@MainActor final class MetricCanvasInteractionStateTests: XCTestCase {
    private let canvasSize = CGSize(width: 800, height: 800)

    func testLayerSelectionMarksPaintedCellsVisibly() {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        let cell = PolarMetricGridCell(ring: 2, angularIndex: 8)
        state.updateWorkspace { $0.updateSelectedLayer { $0.polarCells = [cell] } }
        XCTAssertTrue(state.selectLayers([state.workspace.selectedLayerID]))
        XCTAssertEqual(state.selectedCells, [.init(layerID: state.workspace.selectedLayerID, cell: cell)])
    }

    func testSelectionIsTheDefaultAndOnlySelectionOrPanTool() {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertEqual(state.tool, .select)
        XCTAssertEqual(MetricCanvasTool.allCases, [.select, .paint, .erase, .pan, .audition])
        let workspace = state.workspace
        _ = state.handleKey(.auditionTool)
        XCTAssertEqual(state.tool, .audition)
        XCTAssertFalse(state.beginDrag(at: .init(x: 400, y: 400), canvasSize: canvasSize))
        XCTAssertEqual(state.workspace, workspace, "Audition has no painting or document path")
        state.select(tool: .select); state.setPerformanceLocked(true)
        _ = state.handleKey(.auditionTool)
        XCTAssertEqual(state.tool, .select, "P cannot enter Audition in Perform")
    }

    func testBrushDragFillsEveryCrossedCellWithoutPainting() throws {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)

        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 400, y: 750), canvasSize: canvasSize, modifiers: [.option], brush: true))
        XCTAssertTrue(state.updateDrag(to: CGPoint(x: 650, y: 750), canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)

        // AR-1a: Polar ist die einzige Topologie. Der Strich muss deshalb im
        // Polarraster lückenlos sein: beide Endsektoren liegen darin, die Ringe
        // bilden einen zusammenhängenden Lauf, innerhalb jedes Rings sind die
        // Sektoren zusammenhängend, und benachbarte Ringe überlappen im Azimut.
        let painted = state.selectedPolarCells
        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        for screenPoint in [CGPoint(x: 400, y: 750), CGPoint(x: 650, y: 750)] {
            let metricPoint = try XCTUnwrap(geometry.metricPoint(forScreenPoint: screenPoint))
            XCTAssertTrue(painted.contains(
                PolarMetricGridCell(point: metricPoint, grid: state.workspace.grid)
            ))
        }
        XCTAssertNil(Self.gaplessViolation(painted, grid: state.workspace.grid))
        XCTAssertTrue(state.workspace.selectedLayer.polarCells.isEmpty)
        XCTAssertFalse(state.isDragging)
    }

    func testPanUsesFrozenStartViewportInsteadOfAccumulatingDeltas() {
        var state = MetricCanvasInteractionState(tool: .pan)
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 100, y: 100), canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: CGPoint(x: 150, y: 140), canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: CGPoint(x: 200, y: 200), canvasSize: canvasSize))

        XCTAssertEqual(state.viewport.centerXMeters, -1, accuracy: 1e-12)
        XCTAssertEqual(state.viewport.centerYMeters, 5, accuracy: 1e-12)
    }

    func testToolChangeCancelsActiveDrag() {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 400, y: 400), canvasSize: canvasSize))

        state.select(tool: .pan)

        XCTAssertFalse(state.isDragging)
        XCTAssertFalse(state.updateDrag(to: CGPoint(x: 600, y: 400), canvasSize: canvasSize))
    }

    func testZoomKeepsPointerMetricAnchorAndIsBlockedDuringDrag() throws {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        let pointer = CGPoint(x: 600, y: 300)
        let beforeGeometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let anchor = try XCTUnwrap(beforeGeometry.metricPoint(forScreenPoint: pointer))

        XCTAssertTrue(state.zoom(byFactor: 2, atScreenPoint: pointer, canvasSize: canvasSize))
        let afterGeometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let afterAnchor = try XCTUnwrap(afterGeometry.metricPoint(forScreenPoint: pointer))
        XCTAssertEqual(afterAnchor.xMeters, anchor.xMeters, accuracy: 1e-12)
        XCTAssertEqual(afterAnchor.yMeters, anchor.yMeters, accuracy: 1e-12)

        XCTAssertTrue(state.beginDrag(at: pointer, canvasSize: canvasSize))
        XCTAssertFalse(state.zoom(byFactor: 2, atScreenPoint: pointer, canvasSize: canvasSize))
    }

    func testSizedResetPlacesScannerOriginAtBottomEdge() {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        let size = CGSize(width: 640, height: 360)

        XCTAssertTrue(state.resetViewport(canvasSize: size))
        let geometry = MetricCanvasGeometry(size: size, viewport: state.viewport)
        let origin = geometry.screenPoint(for: MetricScanPoint(xMeters: 0, yMeters: 0))

        XCTAssertEqual(origin.x, 320, accuracy: 1e-12)
        XCTAssertEqual(origin.y, 360, accuracy: 1e-12)
    }

    func testPolarSelectionAddressesTheExactVisibleSector() throws {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        let point = CGPoint(x: 400, y: 750)
        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let metricPoint = try XCTUnwrap(geometry.boundedMetricPoint(forScreenPoint: point))
        let target = PolarMetricGridCell(point: metricPoint, grid: state.workspace.grid)
        XCTAssertTrue(state.beginDrag(at: point, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)

        XCTAssertEqual(state.selectedPolarCells, [target])
    }

    func testSelectedCellDragPreviewsMovesEscapesAndUndoesAsOneEdit() throws {
        let state = CanvasDocumentFixture()
        let selected = PolarMetricGridCell(ring: 2, angularIndex: 8)
        state.replaceWorkspace(.init(layers: [.init(name: "Move", color: .orange, polarCells: [selected])]))
        let segment = PolarMetricCellSegment(cell: selected, grid: state.workspace.grid)
        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let point = geometry.screenPoint(for: segment.point(radiusMeters: segment.midpoint.radiusMeters, bearingDegrees: segment.midpoint.bearingDegrees))
        let end = geometry.screenPoint(for: segment.point(radiusMeters: segment.midpoint.radiusMeters + 0.5, bearingDegrees: segment.midpoint.bearingDegrees))
        XCTAssertTrue(state.selectCell(atScreenPoint: point, canvasSize: canvasSize))
        XCTAssertTrue(state.beginDrag(at: point, canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: end, canvasSize: canvasSize))
        XCTAssertFalse(state.movePreviewCells.isEmpty)
        _ = state.handleKey(.escape)
        XCTAssertEqual(state.selectedPolarCells, [selected])
        XCTAssertTrue(state.movePreviewCells.isEmpty)

        XCTAssertTrue(state.beginDrag(at: point, canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: end, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertNotEqual(state.selectedPolarCells, [selected])
        XCTAssertEqual(state.undoActionName, "Move cells")
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace.selectedLayer.polarCells, [selected])
    }

    func testSelectedCellDragOfOneAngularSegmentMovesExactlyOneAngularSegment() throws {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        let source = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let segment = PolarMetricCellSegment(cell: source, grid: state.workspace.grid)
        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        func point(radius: Double, bearing: Double) -> CGPoint {
            geometry.screenPoint(for: .init(
                xMeters: sin(bearing * .pi / 180) * radius,
                yMeters: cos(bearing * .pi / 180) * radius
            ))
        }
        let start = point(radius: segment.midpoint.radiusMeters, bearing: segment.midpoint.bearingDegrees)
        XCTAssertTrue(state.beginDrag(at: start, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertEqual(state.selectedPolarCells, [source])
        state.updateWorkspace { $0.updateSelectedLayer { $0.polarCells = [source] } }

        let step = segment.endBearingDegrees - segment.startBearingDegrees
        let end = point(radius: segment.midpoint.radiusMeters, bearing: segment.midpoint.bearingDegrees + step)
        XCTAssertTrue(state.beginDrag(at: start, canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: end, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)

        XCTAssertEqual(state.selectedPolarCells, [.init(ring: 2, angularIndex: 9)])
    }

    func testOutwardAndInwardGestureKeepsPreviewAndCommittedPolarCellsTogetherAcrossRingSplits() throws {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertEqual(state.workspace.grid.cellSizeMeters, 0.25, accuracy: 0.000_001)
        let source = PolarMetricGridCell(ring: 2, angularIndex: 8) // 0.50–0.75 m
        state.updateWorkspace { $0.updateSelectedLayer { $0.polarCells = [source] } }
        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let bearing = PolarMetricCellSegment(cell: source, grid: state.workspace.grid).midpoint.bearingDegrees
        func point(radius: Double) -> CGPoint {
            geometry.screenPoint(for: .init(
                xMeters: sin(bearing * .pi / 180) * radius,
                yMeters: cos(bearing * .pi / 180) * radius
            ))
        }
        let start = point(radius: 0.625)
        XCTAssertTrue(state.beginDrag(at: start, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertEqual(state.selectedPolarCells, [source])

        for rings in [1, 2, 4] {
            var attempt = state
            let end = point(radius: 0.625 + Double(rings) * 0.25)
            XCTAssertTrue(attempt.beginDrag(at: start, canvasSize: canvasSize))
            XCTAssertTrue(attempt.updateDrag(to: end, canvasSize: canvasSize))
            let preview = attempt.movePreviewCells
            XCTAssertFalse(preview.isEmpty, "\(rings) rings needs a visible preview")
            attempt.endDrag(canvasSize: canvasSize)
            XCTAssertEqual(attempt.selectedPolarCells, preview, "preview must be the committed result")
            XCTAssertTrue(attempt.selectedPolarCells.allSatisfy { $0.ring >= source.ring + rings - 1 })

            XCTAssertTrue(attempt.beginDrag(at: end, canvasSize: canvasSize))
            XCTAssertTrue(attempt.updateDrag(to: start, canvasSize: canvasSize))
            let inwardPreview = attempt.movePreviewCells
            attempt.endDrag(canvasSize: canvasSize)
            XCTAssertEqual(attempt.selectedPolarCells, inwardPreview, "inward preview must not jump on commit")
        }
    }

    func testCellMoveStaysMovableAfterLayerInspectionWhileExplicitLayerMoveStopsAtOuterCell() throws {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        let source = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let outer = PolarMetricGridCell(ring: 7, angularIndex: 8)
        state.updateWorkspace { $0.updateSelectedLayer { $0.polarCells = [source, outer] } }
        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let segment = PolarMetricCellSegment(cell: source, grid: state.workspace.grid)
        let start = geometry.screenPoint(for: .init(
            xMeters: sin(segment.midpoint.bearingDegrees * .pi / 180) * segment.midpoint.radiusMeters,
            yMeters: cos(segment.midpoint.bearingDegrees * .pi / 180) * segment.midpoint.radiusMeters
        ))
        XCTAssertTrue(state.beginDrag(at: start, canvasSize: canvasSize)); state.endDrag(canvasSize: canvasSize)
        XCTAssertEqual(state.selectedPolarCells, [source])
        let outward = CGPoint(x: start.x, y: start.y - 100)

        // Plain layer inspection deliberately leaves this set empty: only the
        // marked cell participates, so an unrelated 2 m cell cannot block it.
        XCTAssertTrue(state.beginDrag(at: start, canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: outward, canvasSize: canvasSize))
        XCTAssertFalse(state.moveHitBoundary)
        XCTAssertFalse(state.movePreviewCells.isEmpty)
        state.endDrag(canvasSize: canvasSize)

        // The old click path passed this non-empty set. It must visibly hit
        // the outer boundary, proving the counterexample is real.
        var wholeLayer = state
        _ = wholeLayer.selectLayers([wholeLayer.workspace.selectedLayerID])
        let moved = try XCTUnwrap(wholeLayer.selectedPolarCell)
        let movedSegment = PolarMetricCellSegment(cell: moved, grid: wholeLayer.workspace.grid)
        let movedStart = geometry.screenPoint(for: .init(
            xMeters: sin(movedSegment.midpoint.bearingDegrees * .pi / 180) * movedSegment.midpoint.radiusMeters,
            yMeters: cos(movedSegment.midpoint.bearingDegrees * .pi / 180) * movedSegment.midpoint.radiusMeters
        ))
        XCTAssertTrue(wholeLayer.beginDrag(at: movedStart, canvasSize: canvasSize))
        XCTAssertTrue(wholeLayer.updateDrag(to: CGPoint(x: movedStart.x, y: movedStart.y - 100), canvasSize: canvasSize))
        XCTAssertTrue(wholeLayer.moveHitBoundary, "The pre-fix whole-layer path must reach the 2 m edge")
    }

    func testWorkspaceReplacementCancelsAnActiveGesture() {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 400, y: 400), canvasSize: canvasSize))

        state.replaceWorkspace(SpatialInstrumentWorkspace())

        XCTAssertFalse(state.isDragging)
        XCTAssertFalse(state.updateDrag(to: CGPoint(x: 500, y: 400), canvasSize: canvasSize))
    }

    func testTwoFingerPanMovesTheContentByTheReportedScreenDelta() {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        let before = state.viewport
        let geometry = MetricCanvasGeometry(size: CGSize(width: 1, height: 1), viewport: before)

        XCTAssertTrue(state.panViewport(byScreenX: 75, screenY: -40))

        XCTAssertEqual(
            state.viewport,
            geometry.panned(byScreenX: 75, screenY: -40)
        )
    }

    func testMirroredTwoFingerAndToolPanUseTheSameScreenDelta() {
        var twoFinger = MetricCanvasInteractionState(isHorizontallyMirrored: true)
        XCTAssertTrue(twoFinger.panViewport(byScreenX: 75, screenY: -40))

        var tool = MetricCanvasInteractionState(
            tool: .pan,
            isHorizontallyMirrored: true
        )
        XCTAssertTrue(tool.beginDrag(at: CGPoint(x: 100, y: 100), canvasSize: canvasSize))
        XCTAssertTrue(tool.updateDrag(to: CGPoint(x: 175, y: 60), canvasSize: canvasSize))

        XCTAssertEqual(twoFinger.viewport, tool.viewport)
    }

    func testTwoFingerPanDoesNotCompeteWithAnActiveToolDrag() {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 400, y: 400), canvasSize: canvasSize))

        XCTAssertFalse(state.panViewport(byScreenX: 75, screenY: -40))
    }


    /// Benennt die erste Lücke einer bemalten Polarmenge, oder `nil` für einen
    /// lückenlosen Strich: die Ringe bilden einen zusammenhängenden Lauf, jeder
    /// Ring einen zusammenhängenden Sektorlauf, und die Azimutintervalle
    /// benachbarter Ringe berühren sich.
    static func gaplessViolation(
        _ cells: Set<PolarMetricGridCell>,
        grid: MetricSquareGrid
    ) -> String? {
        guard !cells.isEmpty else { return "keine Zelle bemalt" }
        let rings = Set(cells.map(\.ring)).sorted()
        guard let firstRing = rings.first, let lastRing = rings.last else { return "kein Ring" }
        guard rings == Array(firstRing...lastRing) else { return "Ringlücke in \(rings)" }

        var azimuth: [Int: (low: Double, high: Double)] = [:]
        for ring in rings {
            let indices = cells.filter { $0.ring == ring }.map(\.angularIndex).sorted()
            guard let low = indices.first, let high = indices.last else { continue }
            guard indices == Array(low...high) else {
                return "Sektorlücke in Ring \(ring): \(indices)"
            }
            let step = PolarMetricCellSegment.angularStepDegrees(
                outerRadiusMeters: Double(ring + 1) * grid.cellSizeMeters,
                radialHeightMeters: grid.cellSizeMeters
            )
            azimuth[ring] = (Double(low) * step - 180, Double(high + 1) * step - 180)
        }
        for ring in rings.dropLast() {
            guard let inner = azimuth[ring], let outer = azimuth[ring + 1] else { continue }
            guard inner.low <= outer.high, outer.low <= inner.high else {
                return "Azimutlücke zwischen Ring \(ring) und \(ring + 1)"
            }
        }
        return nil
    }

    /// Lückenlosigkeit über mehrere Strichrichtungen auf derselben Leinwand.
    func testMultipleStrokesAreGapless() throws {
        let strokes: [(name: String, from: CGPoint, to: CGPoint)] = [
            ("waagerecht nach rechts", CGPoint(x: 200, y: 400), CGPoint(x: 600, y: 400)),
            ("waagerecht nach links", CGPoint(x: 600, y: 400), CGPoint(x: 200, y: 400)),
            ("senkrecht vom Rand zur Mitte", CGPoint(x: 400, y: 750), CGPoint(x: 400, y: 400)),
            ("schräg", CGPoint(x: 200, y: 600), CGPoint(x: 600, y: 200))
        ]

        for stroke in strokes {
            var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
            // Diese historische Lückenlosigkeitsprobe misst die frühere
            // 50-cm-Geometrie ausdrücklich; GRID-1 prüft die neuen Weiten
            // separat, ohne den alten Invariantentest umzudeuten.
            XCTAssertEqual(state.requestGridChange(to: .fiftyCentimeter), .changed)
            XCTAssertTrue(
                state.beginDrag(at: stroke.from, canvasSize: canvasSize),
                "\(stroke.name): beginDrag fehlgeschlagen"
            )
            XCTAssertTrue(
                state.updateDrag(to: stroke.to, canvasSize: canvasSize),
                "\(stroke.name): updateDrag fehlgeschlagen"
            )
            state.endDrag(canvasSize: canvasSize)

            let painted = state.selectedPolarCells
            XCTAssertFalse(painted.isEmpty, "\(stroke.name): keine Zelle bemalt")

            let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
            for endpoint in [stroke.from, stroke.to] {
                let metricPoint = try XCTUnwrap(
                    geometry.metricPoint(forScreenPoint: endpoint),
                    "\(stroke.name): metrischer Punkt für \(endpoint) fehlt"
                )
                let cell = PolarMetricGridCell(point: metricPoint, grid: state.workspace.grid)
                XCTAssertTrue(
                    painted.contains(cell),
                    "\(stroke.name): Endsektor \(cell) fehlt in der bemalten Menge"
                )
            }

            XCTAssertNil(
                Self.gaplessViolation(painted, grid: state.workspace.grid),
                "\(stroke.name): Lücke im Strich"
            )
        }
    }

    /// Gegenprobe: die Lückenprüfung muss jede Art von Lücke wirklich benennen.
    func testGaplessCheckRejectsEveryPunchedOutStroke() throws {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: CGPoint(x: 650, y: 750), canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        let painted = state.selectedPolarCells
        let grid = state.workspace.grid
        XCTAssertNil(Self.gaplessViolation(painted, grid: grid))

        // Jede einzelne herausgenommene Zelle hinterlässt eine benannte Lücke,
        // sofern sie nicht am Rand des Strichs liegt.
        let middleRing = try XCTUnwrap(Set(painted.map(\.ring)).sorted().dropFirst().first)
        let punchedRing = painted.filter { $0.ring != middleRing }
        XCTAssertEqual(Self.gaplessViolation(punchedRing, grid: grid), "Ringlücke in \(Set(punchedRing.map(\.ring)).sorted())")

        let innerRing = try XCTUnwrap(Set(painted.map(\.ring)).sorted().first)
        let sectors = painted.filter { $0.ring == innerRing }.map(\.angularIndex).sorted()
        try XCTSkipIf(sectors.count < 3, "Ring \(innerRing) hat keinen inneren Sektor zum Ausstanzen")
        let punchedSector = painted.filter { !($0.ring == innerRing && $0.angularIndex == sectors[1]) }
        XCTAssertNotNil(Self.gaplessViolation(punchedSector, grid: grid))

        XCTAssertEqual(Self.gaplessViolation([], grid: grid), "keine Zelle bemalt")
    }

    // MARK: - AR-1d: Auswahl der Polarzelle

    func testSelectsTheExactSector() throws {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: CGPoint(x: 650, y: 750), canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)

        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let lastMetricPoint = try XCTUnwrap(
            geometry.boundedMetricPoint(forScreenPoint: CGPoint(x: 650, y: 750))
        )
        let expectedCell = PolarMetricGridCell(point: lastMetricPoint, grid: state.workspace.grid)

        XCTAssertTrue(state.selectedPolarCells.contains(expectedCell))
    }

    func testSelectionEndsOnWorkspaceReplacement() throws {
        // Nach dem Wegfall des Rasterwechsels ist der Austausch des
        // Arbeitsbereichs der einzige Weg, der eine bestehende Auswahl löscht.
        // Der Anfangszustand hat ohnehin keine. Werkzeugwechsel und Spiegelung
        // löschen bewusst nicht; das prüft der Gegentest darunter.
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertFalse(state.selectedPolarCells.isEmpty)

        state.replaceWorkspace(SpatialInstrumentWorkspace())

        XCTAssertTrue(state.selectedPolarCells.isEmpty)
    }

    func testSelectionSurvivesToolChangeAndMirrorToggle() throws {
        do {
            var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
            XCTAssertTrue(state.beginDrag(at: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
            state.endDrag(canvasSize: canvasSize)
            let before = state.selectedPolarCells
            XCTAssertFalse(before.isEmpty)
            state.select(tool: .pan)
            XCTAssertEqual(state.selectedPolarCells, before)
        }
        do {
            var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
            XCTAssertTrue(state.beginDrag(at: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
            state.endDrag(canvasSize: canvasSize)
            let before = state.selectedPolarCells
            XCTAssertFalse(before.isEmpty)
            state.toggleHorizontalMirror()
            XCTAssertEqual(state.selectedPolarCells, before)
        }
    }

    // MARK: - S1a: Mehrfach-Zellselektion

    func testToggleCellSelectionMatchesSelectAddress() throws {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        let point = CGPoint(x: 400, y: 750)

        // Toggle fügt genau die Zelle hinzu, die Malen am selben Punkt füllen würde.
        XCTAssertTrue(state.toggleCellSelection(atScreenPoint: point, canvasSize: canvasSize))

        // Gegen den bestehenden Auswahlweg prüfen: dieselbe Adresse.
        var paintState = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(paintState.beginDrag(at: point, canvasSize: canvasSize, modifiers: [.option], brush: true))
        paintState.endDrag(canvasSize: canvasSize)
        let paintCell = try XCTUnwrap(paintState.selectedPolarCells.first)

        XCTAssertEqual(state.selectedPolarCells, [paintCell])
        XCTAssertTrue(state.isSelected(paintCell))

        // Nochmaliges Toggle entfernt die Zelle.
        XCTAssertTrue(state.toggleCellSelection(atScreenPoint: point, canvasSize: canvasSize))
        XCTAssertEqual(state.selectedPolarCells, [])
        XCTAssertFalse(state.isSelected(paintCell))
    }

    func testTwoDifferentPointsYieldTwoCells() throws {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        let pointA = CGPoint(x: 300, y: 700)
        let pointB = CGPoint(x: 500, y: 600)

        XCTAssertTrue(state.toggleCellSelection(atScreenPoint: pointA, canvasSize: canvasSize))
        XCTAssertTrue(state.toggleCellSelection(atScreenPoint: pointB, canvasSize: canvasSize))

        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let metricPointA = try XCTUnwrap(geometry.boundedMetricPoint(forScreenPoint: pointA))
        let cellA = PolarMetricGridCell(point: metricPointA, grid: state.workspace.grid)
        let metricPointB = try XCTUnwrap(geometry.boundedMetricPoint(forScreenPoint: pointB))
        let cellB = PolarMetricGridCell(point: metricPointB, grid: state.workspace.grid)

        XCTAssertEqual(state.selectedPolarCells, [cellA, cellB])
        XCTAssertTrue(state.isSelected(cellA))
        XCTAssertTrue(state.isSelected(cellB))
    }

    func testClearSelectionEmptiesTheSet() {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.toggleCellSelection(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertFalse(state.selectedPolarCells.isEmpty)

        state.clearSelection()
        XCTAssertTrue(state.selectedPolarCells.isEmpty)
    }

    func testPointOutsideFieldChangesNothing() {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        let outside = CGPoint(x: CGFloat.nan, y: CGFloat.nan)

        XCTAssertFalse(state.toggleCellSelection(atScreenPoint: outside, canvasSize: canvasSize))
        XCTAssertTrue(state.selectedPolarCells.isEmpty)
    }

    func testMultiSelectionSurvivesToolChangeAndMirrorToggle() {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.toggleCellSelection(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        let before = state.selectedPolarCells
        XCTAssertFalse(before.isEmpty)

        state.select(tool: .pan)
        XCTAssertEqual(state.selectedPolarCells, before)

        state.toggleHorizontalMirror()
        XCTAssertEqual(state.selectedPolarCells, before)
    }

    func testMultiSelectionClearedOnWorkspaceReplacement() {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.toggleCellSelection(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertFalse(state.selectedPolarCells.isEmpty)

        state.replaceWorkspace(SpatialInstrumentWorkspace())
        XCTAssertTrue(state.selectedPolarCells.isEmpty)
    }

    func testExtendSelectionIsIdempotent() throws {
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        let point = CGPoint(x: 400, y: 750)

        XCTAssertTrue(state.extendSelection(toScreenPoint: point, canvasSize: canvasSize))
        XCTAssertTrue(state.extendSelection(toScreenPoint: point, canvasSize: canvasSize))

        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let metricPoint = try XCTUnwrap(geometry.boundedMetricPoint(forScreenPoint: point))
        let cell = PolarMetricGridCell(point: metricPoint, grid: state.workspace.grid)

        XCTAssertEqual(state.selectedPolarCells, [cell])
    }

    private func driveSelectGesture(
        _ state: inout MetricCanvasInteractionState,
        start: CGPoint,
        point: CGPoint,
        canvasSize: CGSize
    ) -> Bool {
        if !state.isDragging {
            _ = state.beginDrag(at: start, canvasSize: canvasSize)
        }
        return state.updateDrag(to: point, canvasSize: canvasSize)
    }

    func testPlainClickReplacesAndCommandClickToggles() throws {
        let start = CGPoint(x: 400, y: 750)
        let jitter = CGPoint(x: 402, y: 748)
        let jitterAgain = CGPoint(x: 401, y: 749)
        let returnToCell = CGPoint(x: 398, y: 752)
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let metricPoint = try XCTUnwrap(geometry.boundedMetricPoint(forScreenPoint: start))
        let cell = PolarMetricGridCell(point: metricPoint, grid: state.workspace.grid)

        // Ein Klick ersetzt; Bewegungs-Jitter ändert daran nichts.
        XCTAssertTrue(driveSelectGesture(&state, start: start, point: jitter, canvasSize: canvasSize))
        XCTAssertTrue(driveSelectGesture(&state, start: start, point: jitterAgain, canvasSize: canvasSize))
        XCTAssertTrue(driveSelectGesture(&state, start: start, point: returnToCell, canvasSize: canvasSize))
        XCTAssertTrue(driveSelectGesture(&state, start: start, point: jitter, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertEqual(state.selectedPolarCells, [cell])

        XCTAssertTrue(driveSelectGesture(&state, start: start, point: jitter, canvasSize: canvasSize))
        XCTAssertTrue(driveSelectGesture(&state, start: start, point: jitterAgain, canvasSize: canvasSize))
        XCTAssertTrue(driveSelectGesture(&state, start: start, point: returnToCell, canvasSize: canvasSize))
        XCTAssertTrue(driveSelectGesture(&state, start: start, point: jitter, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertEqual(state.selectedPolarCells, [cell])

        XCTAssertTrue(state.beginDrag(at: start, canvasSize: canvasSize, modifiers: [.command]))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertTrue(state.selectedPolarCells.isEmpty)

        // Außerhalb des Feldes liefert beginDrag false, hält die neutrale
        // Geste aber trotzdem fest: auch ein nachfolgendes updateDrag darf
        // keinen zweiten Toggle derselben onChanged-Folge auslösen.
        XCTAssertFalse(state.beginDrag(at: CGPoint(x: 10, y: 10), canvasSize: .zero))
        XCTAssertTrue(state.isDragging)
        XCTAssertTrue(state.updateDrag(to: jitter, canvasSize: .zero))
        XCTAssertTrue(state.selectedPolarCells.isEmpty)
        state.endDrag(canvasSize: .zero)
    }

    func testSelectToolKeepsTheMultiSelectionWhenTheToolChanges() {
        let point = CGPoint(x: 400, y: 750)
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.beginDrag(at: point, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        let selected = state.selectedPolarCells

        state.select(tool: .pan)

        XCTAssertEqual(state.selectedPolarCells, selected)
    }

    private func cell(
        at point: CGPoint,
        in state: MetricCanvasInteractionState,
        canvasSize: CGSize = CGSize(width: 800, height: 800)
    ) throws -> PolarMetricGridCell {
        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let metricPoint = try XCTUnwrap(geometry.boundedMetricPoint(forScreenPoint: point))
        return PolarMetricGridCell(point: metricPoint, grid: state.workspace.grid)
    }

    func testSelectDragReplacesEveryCellTouchedByTheScreenRectangle() throws {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        let start = CGPoint(x: 390, y: 730)
        let end = CGPoint(x: 450, y: 670)

        XCTAssertTrue(driveSelectGesture(&state, start: start, point: start, canvasSize: canvasSize))
        XCTAssertTrue(driveSelectGesture(&state, start: start, point: end, canvasSize: canvasSize))
        XCTAssertEqual(state.selectionRectangle, CGRect(x: 390, y: 670, width: 60, height: 60))
        state.endDrag(canvasSize: canvasSize)

        // Unabhängige Herleitung aus einem manuell festgelegten 15-pt-Testgitter,
        // nicht aus der Modell-Abtastfunktion.
        let expectedPoints = stride(from: 390, through: 450, by: 15).flatMap { x in
            stride(from: 670, through: 730, by: 15).map { y in CGPoint(x: x, y: y) }
        }
        let expected = Set(try expectedPoints.map { try cell(at: $0, in: state) })
        XCTAssertEqual(state.selectedPolarCells, expected)
        XCTAssertNil(state.selectionRectangle)
    }

    func testSelectFrameAddsWithCommandModifier() throws {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        let existingPoint = CGPoint(x: 400, y: 750)
        XCTAssertTrue(state.beginDrag(at: existingPoint, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        let existing = try cell(at: existingPoint, in: state)

        let start = CGPoint(x: 390, y: 730)
        let end = CGPoint(x: 450, y: 670)
        XCTAssertTrue(state.beginDrag(at: start, canvasSize: canvasSize, modifiers: [.command]))
        XCTAssertTrue(state.updateDrag(to: end, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)

        XCTAssertTrue(state.selectedPolarCells.contains(existing))
        XCTAssertGreaterThan(state.selectedPolarCells.count, 1)
    }

    func testSelectFrameHandlesPointsOutsideTheField() throws {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        let start = CGPoint(x: -20, y: 720)
        let end = CGPoint(x: 430, y: 680)
        XCTAssertTrue(state.beginDrag(at: start, canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: end, canvasSize: canvasSize))
        XCTAssertNotNil(state.selectionRectangle)
        state.endDrag(canvasSize: canvasSize)

        XCTAssertFalse(state.selectedPolarCells.isEmpty)
        XCTAssertTrue(state.selectedPolarCells.allSatisfy { $0.ring >= 0 })
        XCTAssertNil(state.selectionRectangle)
    }

    func testToolChangeCancelsAnActiveSelectionFrame() {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 390, y: 730), canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: CGPoint(x: 450, y: 670), canvasSize: canvasSize))
        XCTAssertNotNil(state.selectionRectangle)

        state.select(tool: .pan)

        XCTAssertFalse(state.isDragging)
        XCTAssertNil(state.selectionRectangle)
        XCTAssertTrue(state.selectedPolarCells.isEmpty)
    }

    func testClickOnFreeCanvasClearsSelection() {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.selectCell(atScreenPoint: CGPoint(x: 400, y: 700), canvasSize: canvasSize))
        XCTAssertFalse(state.selectedPolarCells.isEmpty)

        // Outside the visible canvas, but still in the reference editor's
        // front half-plane: it must not alias into the selected envelope.
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 1000, y: 700), canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertTrue(state.selectedPolarCells.isEmpty)
    }

    func testShiftClickUsesAnchorBlockAndWithoutAnchorActsAsClick() throws {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        let first = CGPoint(x: 400, y: 700)
        let second = CGPoint(x: 470, y: 650)
        XCTAssertTrue(state.selectCell(atScreenPoint: second, canvasSize: canvasSize, modifiers: [.shift]))
        XCTAssertEqual(state.selectedPolarCells.count, 1)

        XCTAssertTrue(state.selectCell(atScreenPoint: first, canvasSize: canvasSize))
        let anchor = try XCTUnwrap(state.selectedPolarCell)
        XCTAssertTrue(state.selectCell(atScreenPoint: second, canvasSize: canvasSize, modifiers: [.shift]))
        XCTAssertTrue(state.selectedPolarCells.contains(anchor))
        XCTAssertGreaterThan(state.selectedPolarCells.count, 1)
    }

    func testCommandAndShiftFrameAddWithoutChangingCapturedGesture() {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.selectCell(atScreenPoint: CGPoint(x: 400, y: 700), canvasSize: canvasSize))
        let before = state.selectedPolarCells
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 450, y: 680), canvasSize: canvasSize, modifiers: [.shift]))
        XCTAssertTrue(state.updateDrag(to: CGPoint(x: 500, y: 640), canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertTrue(state.selectedPolarCells.isSuperset(of: before))
        XCTAssertGreaterThan(state.selectedPolarCells.count, before.count)
    }

    func testBrushUnionsWithModifierAndNeverShowsRectangle() {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.selectCell(atScreenPoint: CGPoint(x: 400, y: 700), canvasSize: canvasSize))
        let before = state.selectedPolarCells
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 450, y: 700), canvasSize: canvasSize, modifiers: [.command, .option], brush: true))
        XCTAssertTrue(state.updateDrag(to: CGPoint(x: 600, y: 620), canvasSize: canvasSize))
        XCTAssertNil(state.selectionRectangle)
        state.endDrag(canvasSize: canvasSize)
        XCTAssertTrue(state.selectedPolarCells.isSuperset(of: before))
        XCTAssertGreaterThan(state.selectedPolarCells.count, before.count)
    }

    func testBrushModeIsFrozenWhenOptionIsReleased() throws {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 400, y: 700), canvasSize: canvasSize, modifiers: [.option], brush: true))
        XCTAssertTrue(state.updateDrag(to: CGPoint(x: 650, y: 500), canvasSize: canvasSize))
        XCTAssertNil(state.selectionRectangle)
        state.endDrag(canvasSize: canvasSize)
        XCTAssertGreaterThan(state.selectedPolarCells.count, 1)
        let offLine = try cell(at: CGPoint(x: 650, y: 700), in: state)
        XCTAssertFalse(state.selectedPolarCells.contains(offLine))
    }

    func testOptionClickTogglesLikeTheExplicitTogglePath() {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        let point = CGPoint(x: 400, y: 700)
        XCTAssertTrue(state.beginDrag(at: point, canvasSize: canvasSize, modifiers: [.option], brush: true))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertEqual(state.selectedPolarCells.count, 1)
        XCTAssertTrue(state.beginDrag(at: point, canvasSize: canvasSize, modifiers: [.option], brush: true))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertTrue(state.selectedPolarCells.isEmpty)
    }

    func testKeyboardCommandsSelectAllEscapeAndDeleteRespectLayerLock() {
        let cell = PolarMetricGridCell(ring: 0, angularIndex: 2)
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [SpatialInstrumentLayer(name: "x", color: .orange, polarCells: [cell])]))
        XCTAssertNil(state.handleKey(.commandA, modifiers: [.command]))
        XCTAssertEqual(state.selectedPolarCells, [cell])
        XCTAssertNil(state.handleKey(.escape))
        XCTAssertTrue(state.selectedPolarCells.isEmpty)

        _ = state.selectCell(atScreenPoint: CGPoint(x: 400, y: 700), canvasSize: canvasSize)
        XCTAssertEqual(state.handleKey(.commandA, modifiers: [.command]), nil)
        XCTAssertEqual(state.handleKey(.delete), .eraseSelection)
        XCTAssertEqual(state.applyToSelection(.erase), .success(.applied(changedCells: 1)))

        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [SpatialInstrumentLayer(name: "x", color: .orange, isLocked: true, polarCells: [cell])]))
        _ = state.selectCell(atScreenPoint: CGPoint(x: 400, y: 700), canvasSize: canvasSize)
        XCTAssertEqual(state.handleKey(.delete), .eraseSelection)
        XCTAssertEqual(state.applyToSelection(.erase), .failure(.layerLocked(layerID: state.workspace.selectedLayerID)))
    }

    func testEverySelectionPathRespectsContextRadiusWithoutAliasingOutsideToBoundary() throws {
        let grid = MetricSquareGrid.halfMeter
        var state = MetricCanvasInteractionState(selectionMaximumRadiusMeters: 50)
        XCTAssertTrue(state.zoom(byFactor: 0.04, atScreenPoint: CGPoint(x: 400, y: 400), canvasSize: canvasSize))
        let geometry = MetricCanvasGeometry(size: canvasSize, viewport: state.viewport)
        let outsideMetricPoint = MetricScanPoint(xMeters: 0, yMeters: 50.75)
        let boundaryMetricPoint = MetricScanPoint(xMeters: 0, yMeters: 49.75)
        let outside = PolarMetricGridCell(point: outsideMetricPoint, grid: grid)
        let boundary = PolarMetricGridCell(point: boundaryMetricPoint, grid: grid)
        let outsidePoint = geometry.screenPoint(for: outsideMetricPoint)
        let boundaryPoint = geometry.screenPoint(for: boundaryMetricPoint)
        XCTAssertTrue(geometry.canvasRect.contains(outsidePoint))
        XCTAssertTrue(geometry.canvasRect.contains(boundaryPoint))
        XCTAssertEqual(outside.ring, 101)
        XCTAssertEqual(boundary.ring, 99)
        state.replaceWorkspace(SpatialInstrumentWorkspace(grid: grid, layers: [
            SpatialInstrumentLayer(name: "Context boundary", color: .orange, polarCells: [outside, boundary])
        ]))

        _ = state.selectCell(atScreenPoint: outsidePoint, canvasSize: canvasSize)
        XCTAssertTrue(state.selectedPolarCells.isEmpty)
        XCTAssertTrue(state.selectCell(atScreenPoint: boundaryPoint, canvasSize: canvasSize))
        XCTAssertEqual(state.selectedPolarCells, [boundary])
        XCTAssertTrue(state.selectCell(atScreenPoint: boundaryPoint, canvasSize: canvasSize))
        XCTAssertTrue(state.selectCell(atScreenPoint: outsidePoint, canvasSize: canvasSize,
                                       modifiers: [.shift]))
        XCTAssertFalse(state.selectedPolarCells.contains(outside),
                       "Shift-Erweitern darf die vollständig äußere Zelle nicht übernehmen")
        _ = state.toggleCellSelection(atScreenPoint: outsidePoint, canvasSize: canvasSize)
        XCTAssertFalse(state.selectedPolarCells.contains(outside))
        _ = state.extendSelection(toScreenPoint: outsidePoint, canvasSize: canvasSize)
        XCTAssertFalse(state.selectedPolarCells.contains(outside))
        XCTAssertTrue(state.contextMenuSelection(at: outsidePoint, canvasSize: canvasSize))
        XCTAssertTrue(state.selectedCells.isEmpty)
        XCTAssertNil(state.contextPaintCell)

        state.clearSelection()
        XCTAssertTrue(state.beginDrag(at: outsidePoint, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertTrue(state.selectedPolarCells.isEmpty)
        XCTAssertTrue(state.beginDrag(at: outsidePoint, canvasSize: canvasSize, modifiers: [.option], brush: true))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertTrue(state.selectedPolarCells.isEmpty)
        XCTAssertTrue(state.beginDrag(at: boundaryPoint, canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: outsidePoint, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertFalse(state.selectedPolarCells.contains(outside))

        XCTAssertNil(state.handleKey(.commandA, modifiers: [.command]))
        XCTAssertEqual(state.selectedPolarCells, [boundary])
        XCTAssertEqual(state.applyToSelection(.erase), .success(.applied(changedCells: 1)))
        XCTAssertTrue(state.workspace.selectedLayer.polarCells.contains(outside))
        XCTAssertFalse(state.workspace.selectedLayer.polarCells.contains(boundary))
    }
}
