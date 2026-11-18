import SickPLSMacTransport
import XCTest
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl

/// Die Freigabegrenze des Standardlaufs (SICK-0330b):
/// ``StandardConnectionRun/releasePortForMeasurement()`` schließt den
/// nach einem Erfolg gehaltenen TX-fähigen Port **wirklich**, bevor RX
/// beginnen darf. Echter Lauf, echter Reducer, echter Executor -- nur
/// Transport, Uhr und Passwortablage sind gefälscht.
final class StandardConnectionReleaseTests: XCTestCase {

    private func makeRun() -> (StandardConnectionRun, ScriptedStandardConnectionTransport) {
        let clock = TestMonotonicClock()
        let transport = ScriptedStandardConnectionTransport(clock: clock)
        let run = StandardConnectionRun(
            transport: transport, passwordStore: TrackingScannerPasswordStore(), clock: clock
        )
        return (run, transport)
    }

    private func driveFullFallback(_ transport: ScriptedStandardConnectionTransport) {
        var readCount = 0
        transport.onRead = {
            readCount += 1
            if readCount == 3 {
                transport.readScript = [
                    .standardFrame(standardIdentityResponseFrame()),
                    .standardFrame(standardAcknowledgementFrame()),
                    .standardFrame(standardAcknowledgementFrame()),
                    .standardFrame(standardIdentityResponseFrame()),
                    .standardFrame(standardScanProfileFrame())
                ]
            }
        }
    }

    func testReleaseAfterPassiveSuccessReallyClosesAndKeepsTheSuccessPath() {
        let (run, transport) = makeRun()
        transport.readScript = [.standardFrame(standardScanProfileFrame())]
        let connected = run.connect(portPath: "/dev/cu.usbserial-TEST")
        XCTAssertEqual(connected.phase, .ready(.passiveScanProfile))
        XCTAssertTrue(connected.isPortHeld)
        XCTAssertFalse(connected.isFinal)

        let released = run.releasePortForMeasurement()

        XCTAssertEqual(released.phase, .ready(.passiveScanProfile), "Der Erfolgsweg überlebt den Schluss")
        XCTAssertFalse(released.isPortHeld)
        XCTAssertTrue(released.isFinal)
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertFalse(transport.isOpen)
        XCTAssertEqual(released.audit.entries.last?.action, .closePort)
        XCTAssertEqual(released.audit.entries.last?.outcome, .closed)
    }

    func testReleaseAfterCommissioningFallbackSuccessClosesTheExecutorsPort() {
        let (run, transport) = makeRun()
        driveFullFallback(transport)
        let connected = run.connect(portPath: "/dev/cu.usbserial-TEST")
        XCTAssertEqual(connected.phase, .ready(.commissioningFallbackMeasurementStream))
        XCTAssertTrue(connected.isPortHeld)
        let closesBefore = transport.closeCount
        let writesBefore = transport.writtenPayloads.count

        let released = run.releasePortForMeasurement()

        XCTAssertEqual(released.phase, .ready(.commissioningFallbackMeasurementStream))
        XCTAssertFalse(released.isPortHeld)
        XCTAssertTrue(released.isFinal)
        XCTAssertEqual(transport.closeCount, closesBefore + 1, "Genau ein realer Schluss")
        XCTAssertFalse(transport.isOpen)
        XCTAssertEqual(transport.writtenPayloads.count, writesBefore, "Der Schluss sendet nichts mehr")
    }

    func testReleaseAfterActiveContinuationSuccessClosesTheExecutorsPort() {
        let (run, transport) = makeRun()
        var readCount = 0
        transport.onRead = {
            readCount += 1
            if readCount == 2 {
                transport.readScript = [
                    .standardFrame(standardIdentityResponseFrame()),
                    .standardFrame(standardScanProfileFrame())
                ]
            }
        }
        let connected = run.connect(portPath: "/dev/cu.usbserial-TEST")
        XCTAssertEqual(connected.phase, .ready(.activeContinuationMeasurementStream))

        let released = run.releasePortForMeasurement()

        XCTAssertEqual(released.phase, .ready(.activeContinuationMeasurementStream))
        XCTAssertFalse(released.isPortHeld)
        XCTAssertTrue(released.isFinal)
        XCTAssertFalse(transport.isOpen)
    }

    func testAFailingReleaseIsDominantAndARetryRestoresTheSuccess() {
        let (run, transport) = makeRun()
        transport.readScript = [.standardFrame(standardScanProfileFrame())]
        run.connect(portPath: "/dev/cu.usbserial-TEST")
        transport.alwaysFailClose = .openFailed("Schluss schlägt zunächst fehl")

        let failed = run.releasePortForMeasurement()
        XCTAssertEqual(failed.phase, .failed(.portCloseFailed))
        XCTAssertTrue(failed.isPortHeld)
        XCTAssertFalse(failed.isFinal)

        transport.alwaysFailClose = nil
        let retried = run.retryClose()
        XCTAssertEqual(retried.phase, .ready(.passiveScanProfile), "Der ursprüngliche Erfolg kehrt zurück")
        XCTAssertFalse(retried.isPortHeld)
        XCTAssertTrue(retried.isFinal)
    }

    func testReleaseIsHarmlessBeforeAnySuccess() {
        let (run, transport) = makeRun()
        let untouched = run.releasePortForMeasurement()
        XCTAssertEqual(untouched.phase, .idle)
        XCTAssertEqual(transport.closeCount, 0)

        transport.failNextOpen = .openFailed("simuliert")
        let failed = run.connect(portPath: "/dev/cu.usbserial-TEST")
        XCTAssertEqual(failed.phase, .failed(.portOpenFailed))
        let afterFailure = run.releasePortForMeasurement()
        XCTAssertEqual(afterFailure, failed, "Ohne Erfolg gibt es nichts freizugeben")
        XCTAssertEqual(transport.closeCount, 0)
    }

    func testASecondReleaseAfterASuccessfulOneChangesNothing() {
        let (run, transport) = makeRun()
        transport.readScript = [.standardFrame(standardScanProfileFrame())]
        run.connect(portPath: "/dev/cu.usbserial-TEST")
        let first = run.releasePortForMeasurement()
        let second = run.releasePortForMeasurement()
        XCTAssertEqual(second, first)
        XCTAssertEqual(transport.closeCount, 1, "Kein zweiter Schließversuch")
    }
}
