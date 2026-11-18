import XCTest
import PlanariumDomain
import SickPLSControlCore

final class RoomContourLifecycleContractTests: XCTestCase {
    func testContourSurvivesBothSessionBoundariesAndPresetReplacementUntilTermination() throws {
        let contour = SpatialRoomContour(capturedAt: Date(timeIntervalSince1970: 0), geometry: .init(pointCount: 361,
            angleResolutionDegrees: 0.5, startAngleDegrees: -90, sourceIdentifier: "scanner:default"),
            nearestDistancesCentimeters: Array(repeating: 100, count: 361), spreadCentimeters: Array(repeating: 0, count: 361))
        let id = UUID()
        var state = PlayEngine.step(PlayState(), .roomContour(contour)).0
        state = PlayEngine.step(state, .sessionBegan(id)).0
        XCTAssertEqual(state.roomContour, contour)
        state = PlayEngine.step(state, .sessionEnded(id)).0
        XCTAssertEqual(state.roomContour, contour)
        let layer = SpatialDocumentLayer(id: UUID(), name: "Blank", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        state = PlayEngine.step(state, .install(try InstrumentCompiler.compile(.init(spatial: spatial, revision: .newSession())))).0
        XCTAssertEqual(state.roomContour, contour)
        XCTAssertNil(PlayEngine.step(state, .terminate).0.roomContour)
    }
}
