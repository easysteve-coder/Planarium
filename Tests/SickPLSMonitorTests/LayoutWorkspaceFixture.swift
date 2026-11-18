import Foundation
import AppKit
import PlanariumDomain
import SwiftUI
import XCTest
import PlanariumPresets
import SickPLSCommissioning
import SickPLSCommissioningControl
import SickPLSMacTransport
import SickPLSSetupControl
import SickPLSSimulationControl
@testable import SickPLSMonitor

/// The actual ContentView, with every device/discovery/output boundary offline.
@MainActor struct LayoutWorkspaceFixture {
    let fixture: MonitorRootFixture
    let workspace: WorkspaceControlModel
    let view: ContentView
    let suiteName: String
    init(fixture: MonitorRootFixture, reader: ChannelMeterReader? = nil, pasteboard: NSPasteboard = .general) throws {
        self.fixture = fixture
        suiteName = "LayoutWorkspace-\(UUID().uuidString)"
        workspace = WorkspaceControlModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        view = ContentView(workspace: workspace, root: fixture.root,
            connection: .init(coordinator: fixture.root.input, runProvider: NoConnectionRuns(), portListing: NoPorts(),
                defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))),
            scannerSetup: .init(),
            presets: .init(store: .init(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)),
                documentOwner: fixture.root.document),
            spatialInstrument: fixture.root.document,
            audioUnits: .init(document: fixture.root.document, source: EmptyCatalog()),
            audioDevices: .init(host: fixture.root.audio),
            scannerWorkspace: .init(input: fixture.root.input),
            simulation: .init(coordinator: fixture.root.input, discoverer: NoDiscovery()), providedMeterReader: reader, canvasPasteboard: pasteboard)
    }
    func cleanDefaults() { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
}
private struct NoConnectionRuns: StandardConnectionRunProviding {
    func makeRun(portPath: String, measurementMode: ScannerMeasurementMode, onProgress: @escaping StandardConnectionProgressHandler) throws -> StandardConnectionRun {
        throw NSError(domain: "OfflineLayout", code: 1)
    }
}
private struct NoPorts: SerialPortListing {
    func availablePortPaths() -> [String] { [] }
}
private final class NoDiscovery: SimulationServiceDiscovering {
    var onServicesChanged: (([SimulationService]) -> Void)?
    func start() {}
    func stop() {}
}
