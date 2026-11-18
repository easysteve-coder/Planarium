import Foundation
import XCTest
import SickPLSCore
@testable import SickPLSMonitorKit

final class ScannerFlagPresentationTests: XCTestCase {
    func testAllEightFlagsCountEveryRawPointAt90And361AndKeepProjectedValues() throws {
        for count in [90, 361] {
            let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map {
                try B0ScanProfile.Measurement.build(value: $0 == 0 ? 0 : $0 == 1 ? 8191 : UInt16(100 + $0), fieldFlags: UInt8($0 % 8))
            })
            let value = ScannerFlagPresentation(profile: profile)
            XCTAssertEqual(value.counts.reduce(0, +), count)
            for flag in ScannerFlagPresentation.values {
                XCTAssertEqual(value.counts[Int(flag)], (0..<count).filter { $0 % 8 == Int(flag) }.count)
                XCTAssertEqual(ScannerFlagPresentation.label(flag), "flag \(flag)")
            }
            let projected = MetricScanProjection().project(profile)
            XCTAssertEqual(projected.count, count - 2)
            for point in projected { XCTAssertEqual(ScannerFlagPresentation.paletteIndex(point), point.order % 8) }
        }
        XCTAssertEqual(ScannerFlagPresentation(profile: nil).counts, Array(repeating: 0, count: 8))
    }
    func testOldWorkspacePreferencesPreserveValuesAndFlagsDefaultOffThenPersist() throws {
        let old = Data(#"{"setup":false,"layers":false,"cell":true,"channelStrip":false,"selectedTab":"cell"}"#.utf8)
        var value = try JSONDecoder().decode(WorkspacePreferences.self, from: old)
        XCTAssertFalse(value.scannerFlagBits); XCTAssertFalse(value.setup); XCTAssertFalse(value.layers)
        let name = "BundleFlags-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        value.scannerFlagBits = true; WorkspacePreferenceStore.save(value, to: defaults)
        XCTAssertEqual(WorkspacePreferenceStore.load(from: defaults), value)
        value.scannerFlagBits = false; WorkspacePreferenceStore.save(value, to: defaults)
        XCTAssertFalse(WorkspacePreferenceStore.load(from: defaults).scannerFlagBits)
    }
}
