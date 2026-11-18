import XCTest
@testable import PlanariumDomain
import PLSDeviceValues
import SickPLSControlCore

final class SpatialDrawnContourTests: XCTestCase {
    private func geometry(_ count: Int) -> SpatialRoomContour.Geometry {
        .init(pointCount: count, angleResolutionDegrees: 180 / Double(count-1), startAngleDegrees: -90, sourceIdentifier: "scanner:default")
    }
    func testFastStraightStrokeCoversEveryCrossedRayAndErasesBackToMeasuredWall() throws {
        for count in [90,361] {
            var drawing = SpatialDrawnContour(geometry: geometry(count))
            let a = MetricScanPoint(xMeters: -10, yMeters: 1.8), b = MetricScanPoint(xMeters: 10, yMeters: 1.8)
            drawing.stroke(from: a, to: b)
            for index in 6..<(count-6) {
                let bearing = (-90+Double(index)*180/Double(count-1)) * .pi / 180
                if abs(bearing) < 1.3 {
                    XCTAssertNotNil(drawing.distances[index])
                    XCTAssertEqual(Double(drawing.distances[index]!) * cos(bearing), 180, accuracy: 0.6)
                }
            }
            let wall = SpatialRoomContour(geometry: geometry(count), nearestDistancesCentimeters: Array(repeating: 400, count: count), spreadCentimeters: Array(repeating: 0, count: count))
            let effective = try XCTUnwrap(drawing.effective(measured: wall))
            XCTAssertLessThan(effective.nearestDistancesCentimeters[count/2]!, 200)
            drawing.stroke(from: a, to: b, erasing: true)
            XCTAssertEqual(drawing.effective(measured: wall), wall)
            XCTAssertNil(drawing.effective(measured: nil))
        }
    }
    func testDrawingOnlyMovesWallsInwardAndResamplesByNearestAngle() throws {
        var drawing = SpatialDrawnContour(geometry: geometry(90))
        drawing.stroke(from: .init(xMeters: -3,yMeters: 3), to: .init(xMeters: 3,yMeters: 3))
        let wall = SpatialRoomContour(geometry: geometry(90), nearestDistancesCentimeters: Array(repeating: 200, count: 90), spreadCentimeters: Array(repeating: 0, count: 90))
        XCTAssertEqual(drawing.effective(measured: wall)?.nearestDistancesCentimeters, wall.nearestDistancesCentimeters)
        let original = drawing.distances
        drawing.resample(to: geometry(361))
        for i in 0..<361 { XCTAssertEqual(drawing.distances[i], original[Int((Double(i)*89/360).rounded())]) }
        drawing.resample(to: geometry(90))
        XCTAssertEqual(drawing.distances, original)
    }
    func testCeilingFiltersBeforeGroupingWithAndWithoutMeasuredContour() throws {
        for count in [90,361] {
            var drawing = SpatialDrawnContour(geometry: geometry(count))
            drawing.stroke(from: .init(xMeters: -10,yMeters: 1.8), to: .init(xMeters: 10,yMeters: 1.8))
            let measured = SpatialRoomContour(geometry: geometry(count), nearestDistancesCentimeters: Array(repeating: 500,count: count), spreadCentimeters: Array(repeating: 0,count: count))
            for wall in [nil, measured] {
                let contour = try XCTUnwrap(drawing.effective(measured: wall))
                let configuration = SpatialRoomContourConfiguration(isEnabled: true)
                let points = [UInt16(100),200].map { distance in
                    ProjectedScanMeasurement(order: count/2, normalizedIndex: 0.5, distanceCentimeters: distance, fieldFlags: 0, point: .init(xMeters: 0,yMeters: Double(distance)/100))
                }
                let result = configuration.filter(points, contour: contour, geometry: geometry(count), matches: true)
                XCTAssertEqual(result.measurements.map(\.distanceCentimeters), [100])
                XCTAssertEqual(result.rejectedOrders, [count/2])
            }
        }
    }
    func testDrawnCeilingReleasesNormalNotesAndPreservesHoldAndToggle() throws {
        for count in [90,361] { for transition in [SpatialNoteTransition.legato, .holdUntilNext, .toggle] {
            let id = UUID(), session = UUID()
            let g = ProfileGeometryIdentity(operatingMode: "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            let order = count/2, sector = g.tickSpan(at: order)!.lower
            let cells = Set((100...240).map { PolarDeviceLattice(ring: $0, sector: sector)! })
            let layer = SpatialDocumentLayer(id: id, name: "Ceiling", color: .blue, isVisible: true, isActive: true,
                isLocked: false, isSoloed: false, cells: cells,
                routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 90, transition: transition))], cellOverrides: [:])
            var configuration = DetectionConfiguration.allStagesOff
            configuration.roomContour = .init(isEnabled: true)
            configuration.groupingEnabled = true; configuration.groupingMinimumPoints = 1; configuration.minimumAngleDegrees = 0
            let document = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id),
                detection: configuration, revision: .newSession())
            var state = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(document))).0
            state = PlayEngine.step(state, .sessionBegan(session)).0
            func frame(_ sequence: UInt64, _ distance: UInt16) -> PlayInput {
                .frame(.init(sessionID: session, sequence: sequence, time: Double(sequence),
                    measurements: [DeviceTickMeasurement(order: order, ticks: g.tickSpan(at: order)!, rawCentimeters: distance)!], geometry: g))
            }
            let entered = PlayEngine.step(state, frame(1,220)); state = entered.0
            XCTAssertTrue(entered.1.contains { if case .noteOn = $0 { return true }; return false })
            var drawing = SpatialDrawnContour(geometry: geometry(count))
            drawing.stroke(from: .init(xMeters: -10,yMeters: 1.8), to: .init(xMeters: 10,yMeters: 1.8))
            state = PlayEngine.step(state, .roomContour(drawing.effective(measured: nil))).0
            let outside = PlayEngine.step(state, frame(2,220)); state = outside.0
            XCTAssertTrue(state.selection.isEmpty)
            XCTAssertTrue(state.selection.objects.isEmpty)
            XCTAssertEqual(outside.1.contains { if case .noteOff = $0 { return true }; return false }, transition == .legato)
            // A new hand above the ceiling must never enter or sound.
            var fresh = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(document))).0
            fresh = PlayEngine.step(fresh, .sessionBegan(session)).0
            fresh = PlayEngine.step(fresh, .roomContour(drawing.effective(measured: nil))).0
            XCTAssertFalse(PlayEngine.step(fresh, frame(1,220)).1.contains { if case .noteOn = $0 { return true }; return false })
            XCTAssertTrue(PlayEngine.step(fresh, frame(2,100)).1.contains { if case .noteOn = $0 { return true }; return false })
        } }
    }
    func testFitClosingNeverBridgesAnInwardDrawnNotch() throws {
        var drawing = SpatialDrawnContour(geometry: geometry(361))
        drawing.stroke(from: .init(xMeters: 0,yMeters: 1), to: .init(xMeters: 0,yMeters: 1))
        let wall = SpatialRoomContour(geometry: geometry(361), nearestDistancesCentimeters: Array(repeating: 300,count: 361), spreadCentimeters: Array(repeating: 0,count: 361))
        let contour = try XCTUnwrap(drawing.effective(measured: wall))
        XCTAssertEqual(SpatialRoomFit.fittingContour(contour).nearestDistancesCentimeters[180], 100)
    }

    func testRoomFitStaysWithinDrawnCeilingAndMeasuredWall() throws {
        for count in [90,361] {
            var drawing = SpatialDrawnContour(geometry: geometry(count))
            drawing.stroke(from: .init(xMeters: -10,yMeters: 1.8), to: .init(xMeters: 10,yMeters: 1.8))
            let wall = SpatialRoomContour(geometry: geometry(count), nearestDistancesCentimeters: Array(repeating: 250,count: count), spreadCentimeters: Array(repeating: 0,count: count))
            let effective = try XCTUnwrap(drawing.effective(measured: wall))
            let cells = Set((8...10).flatMap { ring in (0..<360).map { PolarMetricGridCell(ring: ring,angularIndex: $0) }.filter {
                abs(PolarMetricCellSegment(cell: $0,grid: .quarterMeter).midpoint.bearingDegrees) < 20
            } })
            let source = SpatialInstrumentWorkspace(grid: .quarterMeter, layers: [.init(name: "Fit",color: .blue,polarCells: cells)])
            let fitted = SpatialRoomFit.applying(to: source,contour: effective,marginCentimeters: 5)
            XCTAssertFalse(fitted.transform.workspace.selectedLayer.polarCells.isEmpty)
            for cell in fitted.transform.workspace.selectedLayer.polarCells {
                let segment = PolarMetricCellSegment(cell: cell,grid: .quarterMeter)
                XCTAssertLessThanOrEqual(segment.outerRadiusMeters, try XCTUnwrap(SpatialRoomFit.wallMeters(over: segment,contour: effective)))
            }
        }
    }

    func testMixedResolutionsKeepMeasuredAngularSpanWhileDrawingUsesNearestRay() throws {
        for (measuredCount, drawnCount) in [(90,361),(361,90)] {
            let measured = SpatialRoomContour(geometry: geometry(measuredCount),
                nearestDistancesCentimeters: (0..<measuredCount).map { $0 % 2 == 0 ? 100 : 300 },
                spreadCentimeters: Array(repeating: 0,count: measuredCount))
            var drawing = SpatialDrawnContour(geometry: geometry(drawnCount))
            drawing.stroke(from: .init(xMeters: 0,yMeters: 0.5), to: .init(xMeters: 0,yMeters: 0.5))
            let effective = try XCTUnwrap(drawing.effective(measured: measured))
            for index in 0..<drawnCount {
                let angle = -90 + Double(index)*180/Double(drawnCount-1)
                let expectedMeasured = measured.filters(distanceCentimeters: 150, bearingDegrees: angle,
                    spanDegrees: geometry(drawnCount).angleResolutionDegrees, toleranceCentimeters: 5)
                let expectedDrawn = drawing.distances[index].map { 150 < Int($0)-5 } ?? true
                XCTAssertEqual(effective.filters(distanceCentimeters: 150, at: index, toleranceCentimeters: 5),
                    expectedMeasured && expectedDrawn, "Mixed resolution ray \(index)")
            }
        }
    }

}
