import XCTest
import PlanariumDomain
@testable import SickPLSMonitorKit

final class DeviceFieldDraftTests: XCTestCase {
    func testRangeBoundsAndRepresentabilityNameEveryFailure() {
        let valid = DeviceFieldDraft.semicircle(kind: .protective, radius: 4)
        guard case .valid(let contour) = valid.validation else { return XCTFail(valid.status) }
        XCTAssertEqual(contour.radiiCentimeters, Array(repeating: 400, count: 361))
        XCTAssertTrue(DeviceFieldDraft.semicircle(kind: .protective, radius: 4.01).status.contains("exceeds 4 m"))
        XCTAssertTrue(DeviceFieldDraft.semicircle(kind: .warning, radius: 50.01).status.contains("exceeds 50 m"))
        guard case .valid = DeviceFieldDraft.semicircle(kind: .warning, radius: 50).validation else { return XCTFail("50 m valid") }
        let island = PolarMetricCellSegment(innerRadiusMeters: 0.5, outerRadiusMeters: 1, startBearingDegrees: -10, endBearingDegrees: 10)
        XCTAssertTrue(DeviceFieldDraft(kind: .protective, area: [island]).status.contains("Island"))
        let root = PolarMetricCellSegment(innerRadiusMeters: 0, outerRadiusMeters: 0.2, startBearingDegrees: -10, endBearingDegrees: 10)
        XCTAssertTrue(DeviceFieldDraft(kind: .protective, area: [root, island]).status.contains("Ring or radial gap"))
        let fine = PolarMetricCellSegment(innerRadiusMeters: 0, outerRadiusMeters: 1, startBearingDegrees: -0.1, endBearingDegrees: 0.1)
        XCTAssertTrue(DeviceFieldDraft(kind: .warning, area: [fine]).status.contains("too fine"))
        let invalid = PolarMetricCellSegment(innerRadiusMeters: -1, outerRadiusMeters: 1, startBearingDegrees: -10, endBearingDegrees: 10)
        XCTAssertTrue(DeviceFieldDraft(kind: .warning, area: [invalid]).status.contains("Invalid geometry"))
        XCTAssertTrue(DeviceFieldDraft(kind: .warning).status.contains("Empty"))
    }
    func testSegmentSelectionRectangleAndExportDiff() {
        var draft = DeviceFieldDraft.semicircle(kind: .protective, radius: 1)
        for segments in ScannerFieldContour.SegmentCount.allCases {
            draft.segments = segments
            guard case .valid(let contour) = draft.validation else { return XCTFail(draft.status) }
            XCTAssertEqual(contour.radiiCentimeters.count, segments.rawValue + 1)
            draft.recordExport(contour); XCTAssertEqual(draft.exportDifference, "Matches last export.")
            draft.area = DeviceFieldDraft.semicircle(kind: .protective, radius: 2).area
            XCTAssertTrue(draft.exportDifference.contains("radii differ"))
            draft.area = DeviceFieldDraft.semicircle(kind: .protective, radius: 1).area
        }
        let rectangle = DeviceFieldDraft.rectangle(kind: .warning)
        guard case .valid(let contour) = rectangle.validation else { return XCTFail(rectangle.status) }
        XCTAssertEqual(contour.radiiCentimeters[180], 200)
        XCTAssertEqual(contour.radiiCentimeters[0], 100)
        XCTAssertEqual(rectangle.kind.output, "WEAK SIGNAL")
        draft.segments = .oneEighty; XCTAssertTrue(draft.status.contains("wire format unverified"))
    }
    func testMacLocalRoundTripAndCorruptionFallBackToEmpty() throws {
        let name = "DeviceFieldDrafts-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var value = DeviceFieldDrafts(); value.protective = .semicircle(kind: .protective, radius: 1)
        value.warning = .rectangle(kind: .warning); value.showInPerformance = false
        DeviceFieldDraftStore.save(value, to: defaults)
        XCTAssertEqual(DeviceFieldDraftStore.load(from: defaults), value)
        defaults.set(Data("damaged".utf8), forKey: DeviceFieldDraftStore.key)
        XCTAssertEqual(DeviceFieldDraftStore.load(from: defaults), .init())
        value.protective.area = [.init(innerRadiusMeters: -1, outerRadiusMeters: 1, startBearingDegrees: -10, endBearingDegrees: 10)]
        DeviceFieldDraftStore.save(value, to: defaults)
        XCTAssertEqual(DeviceFieldDraftStore.load(from: defaults), .init())
        XCTAssertNotEqual(DeviceFieldDraftStore.key, WorkspacePreferenceStore.key)
    }
}
