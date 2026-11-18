import XCTest
import CoreGraphics
import PlanariumDomain
@testable import SickPLSMonitorKit

final class PolarProjectionPropertyTests: XCTestCase {
    func testSeededScreenPolarRoundTripsAcrossViewsMirroringAndEditorRadii() throws {
        var seed: UInt64 = 0xC0FFEE
        func unit() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64.max >> 11)
        }
        for _ in 0..<1000 {
            let size = CGSize(width: 200 + unit() * 1600, height: 200 + unit() * 1400)
            let view = try MetricCanvasViewport.build(centerXMeters: unit() * 6 - 3,
                centerYMeters: unit() * 6 - 3, metersPerPoint: 0.001 + unit() * 0.03)
            let projection = PolarProjection(geometry: .init(size: size, viewport: view, isHorizontallyMirrored: unit() < 0.5),
                                             maximumRadius: unit() < 0.5 ? 2 : 50)
            let r = unit() * projection.maximumRadius, theta = unit() * 180 - 90
            let screen = projection.screenPoint(radius: r, bearing: theta)
            let hit = try XCTUnwrap(projection.point(at: screen))
            XCTAssertEqual(hit.radius, r, accuracy: 1e-9)
            XCTAssertEqual(hit.bearing, theta, accuracy: 1e-8)
            let roundTrip = projection.screenPoint(radius: hit.radius, bearing: hit.bearing)
            XCTAssertEqual(roundTrip.x, screen.x, accuracy: 1e-7)
            XCTAssertEqual(roundTrip.y, screen.y, accuracy: 1e-7)
        }
    }
    func testClampingIsContinuousAtSideAndOriginWithoutRearReflection() throws {
        let geometry = MetricCanvasGeometry(size: .init(width: 800, height: 800), viewport: .instrumentDefault)
        let projection = PolarProjection(geometry: geometry, maximumRadius: 2)
        for x in [-1.0, -0.2, 0, 0.2, 1.0] {
            let front = try XCTUnwrap(projection.point(at: geometry.screenPoint(for: .init(xMeters: x, yMeters: 1e-8))))
            let behind = try XCTUnwrap(projection.point(at: geometry.screenPoint(for: .init(xMeters: x, yMeters: -1e-8))))
            XCTAssertEqual(front.radius, behind.radius, accuracy: 1e-7)
            if x != 0 { XCTAssertEqual(front.bearing, behind.bearing, accuracy: 1e-5) }
            let farther = try XCTUnwrap(projection.point(at: geometry.screenPoint(for: .init(xMeters: x, yMeters: -1))))
            XCTAssertEqual(farther.radius, behind.radius, accuracy: 1e-7)
            XCTAssertNil(projection.cell(at: geometry.screenPoint(for: .init(xMeters: x, yMeters: -1)), grid: .quarterMeter),
                         "A clamped gesture point is not a paint/hit address behind the scanner")
        }
    }
    func testRadialDragMovesExactlyRoundedGridRingsAcrossMirroring() throws {
        for mirrored in [false, true] { for steps in [-1, 0, 1, 2] {
            var state = MetricCanvasInteractionState(viewport: try .build(centerXMeters: 0.1, centerYMeters: 1, metersPerPoint: 0.002),
                                                     isHorizontallyMirrored: mirrored)
            let cells: Set<PolarMetricGridCell> = [.init(ring: 3, angularIndex: 15), .init(ring: 3, angularIndex: 16),
                                                 .init(ring: 4, angularIndex: 19), .init(ring: 4, angularIndex: 20)]
            state.replaceWorkspace(.init(grid: .quarterMeter, layers: [.init(name: "Patch", color: .blue, polarCells: cells)]))
            _ = state.perform(.selectAll)
            let bounds = try XCTUnwrap(state.selectionBounds), size = CGSize(width: 900, height: 800)
            let projection = PolarProjection(geometry: .init(size: size, viewport: state.viewport, isHorizontallyMirrored: mirrored), maximumRadius: 2)
            let down = projection.screenPoint(radius: bounds.midpoint.radiusMeters, bearing: bounds.midpoint.bearingDegrees)
            let up = projection.screenPoint(radius: bounds.midpoint.radiusMeters + Double(steps) * 0.25, bearing: bounds.midpoint.bearingDegrees)
            XCTAssertNil(state.selectionHandle(at: down, canvasSize: size))
            _ = state.beginDrag(at: down, canvasSize: size)
            _ = state.updateDrag(to: up, canvasSize: size)
            state.endDrag(canvasSize: size)
            XCTAssertEqual(state.selectionBounds?.innerRadiusMeters, bounds.innerRadiusMeters + Double(steps) * 0.25)
            XCTAssertEqual(state.selectionBounds?.outerRadiusMeters, bounds.outerRadiusMeters + Double(steps) * 0.25)
        } }
    }
}
