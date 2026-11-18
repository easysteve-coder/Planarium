import PlanariumInput
import PlanariumDomain
import XCTest
import PlanariumPresets
import PlanariumScannerUI
@testable import SickPLSCommissioningControl

// Lokale Doubles für den Produktionsaufrufer-Test (REFEXPORT-1c).
// Vorbild: Tests/PlanariumPresetsTests/PresetTestSupport.swift.
// Bewusst nicht geteilt -- jedes Testziel trägt seine eigenen Fakes.

/// REFEXPORT-1c: Die `referenceMeasurementLine`-Umsetzung auf dem
/// **echten** `ScannerWorkspaceModel` -- kein Spion.
///
/// Zwei Fälle, weil ein einzelner auch von einer festen Zeichenkette
/// erfüllt wäre. Beide müssen rot werden, wenn die Umsetzung `""` liefert.
@MainActor final class ReferenceMeasurementLineProductionTests: XCTestCase {

    private func makeCoordinator() -> ScannerWorkspaceModel {
        ScannerWorkspaceModel()
    }

    func testFreshCoordinatorReportsNotRunning() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(
            coordinator.referenceMeasurementLine,
            "Reference measurement: not running"
        )
    }

    func testAfterStartWithoutProfileReportsRunningNoValue() {
        let coordinator = makeCoordinator()
        coordinator.startReferenceMeasurement()
        XCTAssertEqual(
            coordinator.referenceMeasurementLine,
            "Reference measurement: running, no values yet"
        )
    }
}
