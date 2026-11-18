import XCTest
import AppKit
import SwiftUI
import PlanariumDomain
import SickPLSCommissioning
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class DeviceFieldEditorTests: XCTestCase {
    func testFullScanConnectionBarWithoutModePickerWideAndNarrow() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop() }
        let directory = TestImageDirectory.make().appendingPathComponent("device-fields")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for mode in [ScannerMeasurementMode.fullScan] {
            for width in [420, 280] {
                let host = NSHostingView(rootView: ConnectionBarView(model: layout.view.connection, scannerSetup: layout.view.scannerSetup)
                    .padding(12).foregroundColor(.white).background(StageTheme.workspace).environment(\.colorScheme, .dark))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 340)
                host.wantsLayer = true; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("measurement-\(mode.rawValue)-\(width).png"))
            }
        }
    }
    func testReferenceEditingKeepsTheInstrumentDocumentAndPreviousExportIndependent() throws {
        let fixture = try MonitorRootFixture(), before = fixture.root.document.document
        let name = "IndependentFields-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DeviceFieldControlModel(defaults: defaults)
        let size = CGSize(width: 800, height: 800)
        model.selected = .warning
        let point = CGPoint(x: 400, y: 400) // 4 m ahead; outside the instrument's 2 m area.
        XCTAssertTrue(model.canvas.beginDrag(at: point, canvasSize: size))
        model.canvas.endDrag(canvasSize: size)
        XCTAssertFalse(model.canvas.selectedPolarCells.isEmpty)
        model.fillSelection(); XCTAssertTrue(model.draft.status.contains("Island"))
        model.eraseSelection(); XCTAssertTrue(model.draft.area.isEmpty)
        model.selected = .protective
        model.replace(.semicircle(kind: .protective, radius: 1))
        guard case .valid(let contour) = model.draft.validation else { return XCTFail(model.draft.status) }
        var draft = model.draft; draft.recordExport(contour); model.replace(draft)
        model.replace(.semicircle(kind: .protective, radius: 2))
        XCTAssertTrue(model.draft.exportDifference.contains("radii differ"), "Replacing a shape retains the previous export")
        model.update { $0.showInPerformance = false }
        XCTAssertEqual(fixture.root.document.document, before)
        XCTAssertEqual(DeviceFieldDraftStore.load(from: defaults), model.drafts)
    }
    func testExportRecordsOnlySuccessfulFilesAndRefusesUnsupportedFormat() throws {
        let name = "FieldExport-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DeviceFieldControlModel(defaults: defaults)
        model.replace(.semicircle(kind: .protective, radius: 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("field-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(model.export(to: url))
        let contour = try ScannerFieldContourCodec.decode(Array(Data(contentsOf: url)))
        XCTAssertEqual(contour.radiiCentimeters, Array(repeating: 100, count: 361))
        XCTAssertEqual(model.draft.exportDifference, "Matches last export.")
        var value = model.draft; value.segments = .oneEighty; model.replace(value)
        XCTAssertFalse(model.export(to: url))
        XCTAssertEqual(try Data(contentsOf: url), Data(try ScannerFieldContourCodec.encode(contour)))
        XCTAssertTrue(model.notice?.contains("unverified") == true)
        value.segments = .threeSixty; value.area = DeviceFieldDraft.semicircle(kind: .protective, radius: 2).area; model.replace(value)
        XCTAssertFalse(model.export(to: url.appendingPathComponent("missing")))
        XCTAssertTrue(model.draft.exportDifference.contains("radii differ"))
    }
    func testEditorStatesRenderWideAndNarrowOffline() throws {
        let directory = TestImageDirectory.make().appendingPathComponent("device-fields")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "FieldImages-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DeviceFieldControlModel(defaults: defaults)
        for state in ["protective-1m", "warning-2x2m", "invalid-island", "semicircle4-rectangle3"] {
            model.replace(.init(kind: .protective)); model.replace(.init(kind: .warning))
            if state == "semicircle4-rectangle3" {
                let controls = DeviceFieldEditorView(model: model, radius: "4", width: "3", depth: "3")
                model.selected = .warning; controls.createSemicircle()
                model.selected = .protective; controls.createRectangle()
                for draft in model.visibleDrafts {
                    guard case .valid(let contour) = draft.validation else { return XCTFail(draft.status) }
                    for p in contour.polygonMeters.dropFirst().dropLast() {
                        if draft.kind == .warning { XCTAssertEqual(hypot(p.xMeters, p.yMeters), 4, accuracy: 0.01) }
                        else { XCTAssertEqual(max(abs(p.xMeters) / 1.5, p.yMeters / 3), 1, accuracy: 0.01) }
                    }
                }
            }
            else if state == "warning-2x2m" { model.selected = .warning; model.replace(.rectangle(kind: .warning)) }
            else {
                model.selected = .protective
                if state == "protective-1m" { model.replace(.semicircle(kind: .protective, radius: 1)) }
                else { model.replace(.init(kind: .protective, area: [.init(innerRadiusMeters: 0.5, outerRadiusMeters: 1, startBearingDegrees: -20, endBearingDegrees: 20)])) }
            }
            for width in [1120, 360] {
                let view = state == "semicircle4-rectangle3" ? DeviceFieldEditorView(model: model, radius: "4", width: "3", depth: "3") : DeviceFieldEditorView(model: model)
                let host = NSHostingView(rootView: view.padding(12).foregroundColor(.white).background(StageTheme.workspace).environment(\.colorScheme, .dark))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 850)
                host.wantsLayer = true; host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                // onAppear resets the native field viewport. Zoom only after
                // that production transition, using the same minus action.
                let canvas = CGSize(width: Double(width - 24), height: 2 * model.canvas.viewport.centerYMeters / model.canvas.viewport.metersPerPoint)
                for _ in 0..<8 where Double(canvas.width) * model.canvas.viewport.metersPerPoint < 9 {
                    XCTAssertTrue(model.canvas.zoom(byFactor: 0.5, atScreenPoint: .init(x: canvas.width / 2, y: canvas.height / 2), canvasSize: canvas))
                }
                XCTAssertGreaterThanOrEqual(Double(canvas.width) * model.canvas.viewport.metersPerPoint, 9)
                host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(data.count, 1000)
                try data.write(to: directory.appendingPathComponent("\(state)-\(width).png"))
            }
        }
    }
    func testInvalidIslandOverlayDoesNotDrawFalseContourOrRadialComb() throws {
        let draft = DeviceFieldDraft(kind: .warning, area: [.init(innerRadiusMeters: 0.5, outerRadiusMeters: 1, startBearingDegrees: -20, endBearingDegrees: 20)])
        guard case .invalid = draft.validation else { return XCTFail("An island must not become an exportable contour") }
        let viewport = try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 1, metersPerPoint: 0.005)
        let host = NSHostingView(rootView: DeviceFieldOverlay(drafts: [draft], viewport: viewport).background(Color.black))
        host.frame = .init(x: 0, y: 0, width: 400, height: 400)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var brightEdges = 0, filledArea = 0
        for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.blueComponent > 0.5 && color.greenComponent > 0.4 { brightEdges += 1 }
            if color.blueComponent > 0.05 { filledArea += 1 }
        } }
        XCTAssertGreaterThan(filledArea, 20, "The invalid authored area remains visible")
        XCTAssertEqual(brightEdges, 0, "An island is not a contour: no misleading bright radial seam")
    }
}
