import XCTest
import PlanariumDomain
import SickPLSControlCore
@testable import SickPLSMonitor

@MainActor final class AcceptanceAProjectionTests: XCTestCase {
    func testHighlightMatchesPaintedTileEveryFineAddressAndEditorGrid() throws {
        for grid: MetricSquareGrid in [.fiveCentimeter, .tenCentimeter, try .build(cellSizeMeters: 0.25)] {
            var mismatches = 0
            for ring in 0...299 {
                for tick in 0...360 {
                    let cell = PolarDeviceLattice(ring: ring, sector: tick)!
                    if SpatialActiveCellDisplayModel.tile(cell, grid: grid) != (try LegacyLatticeMigration.project(cell, in: grid)) { mismatches += 1 }
                }
            }
            XCTAssertEqual(mismatches, 0, "highlight must use integer painted-cell projection, grid \(grid)")
        }
    }
}
