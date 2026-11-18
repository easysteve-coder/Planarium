import XCTest
import PlanariumDomain
import SickPLSCore
import SickPLSMonitorKit

final class RoomFieldContractTests: XCTestCase {
    func testWallContourStaysFixedForEveryRayAndTolerance() {
        for count in [90,361] {
            let room = SpatialRoomContour(geometry: .init(pointCount: count, angleResolutionDegrees: 180/Double(count-1), startAngleDegrees: -90, sourceIdentifier: "scanner:default"),
                nearestDistancesCentimeters: (0..<count).map { UInt16(200+$0%3) }, spreadCentimeters: Array(repeating: 14,count: count))
            let baseline = ScanFieldPresentation(contour: room, matches: true, configuration: .init(isEnabled: true, toleranceCentimeters: 1), showRawScan: false, objects: []).contour
            for tolerance: UInt16 in [1,2,3,5,8,10,30] {
                let model = ScanFieldPresentation(contour: room, matches: true,
                    configuration: .init(isEnabled: true,toleranceCentimeters: tolerance), showRawScan: false, objects: [])
                XCTAssertEqual(model.contour, baseline)
                XCTAssertEqual(model.contour.count,count); XCTAssertFalse(model.showsRawScan)
                for (index,value) in model.contour.enumerated() {
                    let expected = Double(200+index%3)
                    XCTAssertEqual(hypot(value!.xMeters,value!.yMeters)*100,expected,accuracy: 1e-9)
                    XCTAssertTrue(room.filters(distanceCentimeters: UInt16(expected-Double(tolerance)-1), at: index,toleranceCentimeters: tolerance))
                    XCTAssertFalse(room.filters(distanceCentimeters: UInt16(expected-Double(tolerance)), at: index,toleranceCentimeters: tolerance))
                }
                XCTAssertEqual(model.scatterNotice != nil, tolerance < 3)
                if tolerance == 2 { XCTAssertTrue(model.scatterNotice!.contains("suggest 3 cm")) }
            }
            let raw = ScanFieldPresentation(contour: room,matches: true,configuration: .init(isEnabled: true),showRawScan: true,objects: [])
            XCTAssertTrue(raw.showsRawScan)
            let mismatch = ScanFieldPresentation(contour: room,matches: false,configuration: .init(isEnabled: true),showRawScan: false,objects: [])
            XCTAssertTrue(mismatch.showsRawScan); XCTAssertTrue(mismatch.contour.isEmpty)
        }
        XCTAssertTrue(ScanFieldPresentation(contour: nil,matches: true,configuration: .init(),showRawScan: false,objects: []).showsRawScan)
    }
    func testTwoHandCirclesComeFromTheActualDetectionGroupsForMMK90And361() throws {
        for count in [90,361] {
            let left = (count/3-2)...(count/3+2), right = (2*count/3-2)...(2*count/3+2)
            let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map {
                try .build(value: left.contains($0) || right.contains($0) ? 100 : 200,fieldFlags: 0)
            })
            let geometry = try FullScanProfileAdapter.geometry(from: profile)
            let frame = ProfileFrame(sessionID: UUID(),sequence: 1,time: 0, measurements: try FullScanProfileAdapter.measurements(from: profile),geometry: geometry,rawProfile: profile)
            let room = SpatialRoomContour(geometry: .init(pointCount: count,angleResolutionDegrees: 180/Double(count-1),startAngleDegrees: -90,sourceIdentifier: frame.sourceIdentifier),
                nearestDistancesCentimeters: Array(repeating: 200,count: count),spreadCentimeters: Array(repeating: 0,count: count))
            let layer = SpatialDocumentLayer(id: UUID(),name: "Empty",color: .orange,isVisible: true,isActive: true,isLocked: false,isSoloed: false,cells: [],routings: [],cellOverrides: [:])
            var config = DetectionConfiguration.ownerDefaults; config.roomContour = .init(isEnabled: true); config.temporalSmoothing = .off
            let doc = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2,layers: [layer],selectedLayerID: layer.id),detection: config,revision: .newSession())
            var pipeline = SpatialDetectionPipeline()
            let selection = pipeline.select(frame: frame,instrument: try InstrumentCompiler.compile(doc),contour: room)
            XCTAssertEqual(selection.objects.count,2)
            let presentation = ScanFieldPresentation(contour: room,matches: selection.contourMatches,configuration: config.roomContour,showRawScan: false,objects: selection.objects)
            XCTAssertFalse(presentation.showsRawScan); XCTAssertEqual(presentation.objects,selection.objects)
            for (range,object) in zip([left,right],presentation.objects) {
                let points = frame.projectedMeasurements.filter { range.contains($0.order) }
                let xs = points.map { $0.point.xMeters }, ys = points.map { $0.point.yMeters }
                XCTAssertEqual(object.center.xMeters,xs.reduce(0,+)/5,accuracy: 1e-12)
                XCTAssertEqual(object.center.yMeters,ys.reduce(0,+)/5,accuracy: 1e-12)
                XCTAssertEqual(object.diameterMeters,max(0.04,hypot(xs.max()!-xs.min()!,ys.max()!-ys.min()!)),accuracy: 1e-12)
                XCTAssertTrue(points.contains { $0.point == object.representative.point })
            }
            XCTAssertEqual(selection.filteredOrders.count,count-10)
        }
    }
}
