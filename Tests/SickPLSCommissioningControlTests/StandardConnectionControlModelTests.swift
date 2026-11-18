import Combine
import PlanariumInput
import PlanariumDomain
import SickPLSMacTransport
import SickPLSMonitorKit
import PlanariumScannerUI
import PlanariumPresets
import XCTest
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl

/// Das Verbindungsmodell als **erster und einziger Produktionsaufrufer**
/// des Standardlaufs (SICK-0330b).
///
/// Echte Übergänge: echter ``StandardConnectionRun``, echtes
/// ``SerialPortOwnership`` im Spion-Koordinator. Die Reihenfolge „TX-Port
/// wirklich zu, Besitz zurück, dann RX" ist hier nicht behauptet, sondern
/// am Transport und am Besitzmodell beobachtet.
@MainActor final class StandardConnectionControlModelTests: XCTestCase {
    func testRepeatedDiscreteStreamingStatusDoesNotRepublishAndPointCountChangeDoes() {
        let harness = ConnectionHarness()
        harness.coordinator.simulateFirstProfile(portPath: ConnectionHarness.portPath, rateHz: 25, pointCount: 90)
        var publications = 0
        let token = harness.model.objectWillChange.sink { publications += 1 }
        defer { token.cancel() }
        for _ in 0..<50 {
            harness.coordinator.simulateFirstProfile(portPath: ConnectionHarness.portPath, rateHz: nil, pointCount: 90)
        }
        XCTAssertEqual(publications, 0)
        harness.coordinator.simulateFirstProfile(portPath: ConnectionHarness.portPath, rateHz: 25, pointCount: 361)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(harness.model.barState, .ready(portPath: ConnectionHarness.portPath, pointCount: 361))
    }

    func testUSBClassificationAndSupportList() {
        let usb = ["usbserial-BG03R8Q4", "usbmodem123", "SLAB_USBtoUART", "wchusbserial1410"]
        let other = ["Bluetooth-Incoming-Port", "Bluetooth-Modem", "bluetooth-incoming-port", "JBLTUNE520BT", "debug-console", "POST", "PRE"]
        for name in usb { XCTAssertEqual(ScannerSerialPortKind.classify("/dev/cu." + name), .usbSerial) }
        for name in other { XCTAssertEqual(ScannerSerialPortKind.classify("/dev/cu." + name), .other) }
        XCTAssertEqual(ScannerSerialPortKind.classify("/dev/tty.usbserial-X"), .other)
        let h = ConnectionHarness(selectPort: false)
        h.listing.paths = (other + usb).map { "/dev/cu." + $0 }; h.model.refreshPorts()
        XCTAssertEqual(h.model.visiblePorts, usb.map { "/dev/cu." + $0 }.sorted())
        h.model.showsAllPorts = true
        XCTAssertEqual(h.model.visiblePorts, usb.map { "/dev/cu." + $0 }.sorted() + other.map { "/dev/cu." + $0 }.sorted())
    }
    func testAutomaticSearchFiltersBluetoothAndUsesStableUSBOrderThroughRealRun() {
        let h = ConnectionHarness(selectPort: false)
        h.listing.paths = ["/dev/cu.usbserial-B", "/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.usbserial-A", "/dev/cu.JBLTUNE520BT"]
        var attempted: [String] = []
        h.provider.prepareTransportForPort = { path, transport in
            attempted.append(path)
            transport.failNextOpen = .openFailed("offline")
        }
        XCTAssertEqual(h.model.connectAutomatically(), .started(candidateCount: 2)); h.settle()
        XCTAssertEqual(attempted, ["/dev/cu.usbserial-A", "/dev/cu.usbserial-B"])
        XCTAssertEqual(h.model.automaticSearchAttempts.map(\.portPath), attempted)
        h.listing.paths = ["/dev/cu.Bluetooth-Incoming-Port"]
        XCTAssertEqual(h.model.connectAutomatically(), .refusedNoCandidates)
        XCTAssertEqual(h.model.notice, StandardConnectionControlModel.noUSBAdapterNotice)
        XCTAssertEqual(attempted.count, 2)
    }
    func testUSBStartupOneManyNoneAndHotplugWithoutRepeatedAttempts() {
        for paths in [[], ["/dev/cu.usbserial-A"], ["/dev/cu.usbserial-B", "/dev/cu.usbserial-A"]] {
            let h = ConnectionHarness(selectPort: false)
            h.listing.paths = ["/dev/cu.Bluetooth-Incoming-Port"] + paths
            var starts: [[String]] = []
            h.model.checkUSBStartup(simulationSelected: false) { starts.append($0); _ = h.model.connect() }
            h.model.checkUSBStartup(simulationSelected: false) { starts.append($0) }
            XCTAssertEqual(starts, paths.isEmpty ? [] : [paths.sorted()])
            XCTAssertEqual(h.provider.runs.count, paths.isEmpty ? 0 : 1)
            if paths.isEmpty {
                XCTAssertEqual(h.model.notice, StandardConnectionControlModel.noUSBAdapterNotice)
                h.listing.paths.append("/dev/cu.usbmodem-LATER")
                h.model.checkUSBStartup(simulationSelected: false) { starts.append($0); _ = h.model.connect() }
                XCTAssertEqual(starts, [["/dev/cu.usbmodem-LATER"]]); XCTAssertEqual(h.provider.runs.count, 1)
            }
            h.model.disconnect(); h.settle()
        }
    }
    func testUSBStartupRespectsSimulationExistingOwnerAndExplicitDisconnect() {
        for barrier in ["simulationChoice", "simulationOwner", "connected", "disconnect"] {
            let h = ConnectionHarness(selectPort: false)
            h.listing.paths = ["/dev/cu.usbserial-A"]
            switch barrier {
            case "simulationOwner": h.coordinator.holdSimulationForTest()
            case "connected":
                _ = h.model.connectDevelopment(portPath: "/dev/cu.usbserial-A", baudRate: .baud500000)
                h.coordinator.simulateFirstProfile(portPath: "/dev/cu.usbserial-A", rateHz: 25, pointCount: 361)
            case "disconnect":
                _ = h.model.connectDevelopment(portPath: "/dev/cu.usbserial-A", baudRate: .baud500000)
                h.model.disconnect(); h.coordinator.simulatePortReleased()
            default: break
            }
            var starts = 0
            h.model.checkUSBStartup(simulationSelected: barrier == "simulationChoice") { _ in starts += 1 }
            h.listing.paths.append("/dev/cu.usbserial-B")
            h.model.checkUSBStartup(simulationSelected: barrier == "simulationChoice") { _ in starts += 1 }
            XCTAssertEqual(starts, 0, barrier)
        }
    }
    func testUSBAdapterAppearingDuringAConnectionAttemptWaitsForRealPortRelease() {
        let h = ConnectionHarness(selectPort: false)
        h.listing.paths = ["/dev/cu.usbserial-A"]
        h.provider.prepareTransport = { $0.failNextOpen = .openFailed("offline") }
        var starts: [[String]] = []
        func check() {
            h.model.checkUSBStartup(simulationSelected: false) {
                starts.append($0); _ = h.model.connectAutomatically()
            }
        }
        check()
        XCTAssertEqual(starts, [["/dev/cu.usbserial-A"]])
        XCTAssertEqual(h.coordinator.portOwner, .commissioning)
        h.listing.paths.append("/dev/cu.usbserial-B")
        check(); check()
        XCTAssertEqual(starts.count, 1, "No second owner while the first attempt runs")
        h.settle()
        XCTAssertEqual(h.coordinator.portOwner, .free)
        check(); h.settle()
        XCTAssertEqual(starts, [["/dev/cu.usbserial-A"], ["/dev/cu.usbserial-A", "/dev/cu.usbserial-B"]])
        XCTAssertEqual(h.model.automaticSearchAttempts.map(\.portPath), ["/dev/cu.usbserial-A", "/dev/cu.usbserial-B"])
        check(); XCTAssertEqual(starts.count, 2, "A failure must not create a repeated search")

        // The app's safe setup route owns the same edge through deviceSetupActive,
        // rather than StandardConnectionRun. It must retain hotplug as well.
        let coordinator = SpyStandardConnectionCoordinator(), listing = FakeSerialPortListing()
        let model = StandardConnectionControlModel(coordinator: coordinator, runProvider: ScriptedStandardConnectionRunProvider(),
            dispatcher: ManualCommissioningDispatcher(), portListing: listing, releaseOutputs: { $0() })
        listing.paths = ["/dev/cu.usbserial-A"]
        var setupStarts: [[String]] = []
        func checkSetup() {
            model.checkUSBStartup(simulationSelected: false) { ports in
                model.beginDeviceSetup(mode: .fullScan) { setupStarts.append(ports) }
            }
        }
        checkSetup(); XCTAssertTrue(model.deviceSetupActive)
        listing.paths.append("/dev/cu.usbserial-B")
        checkSetup(); XCTAssertEqual(setupStarts.count, 1)
        model.finishDeviceSetup(portPath: nil, baudRate: nil, mode: .fullScan)
        checkSetup(); XCTAssertEqual(setupStarts, [["/dev/cu.usbserial-A"], ["/dev/cu.usbserial-A", "/dev/cu.usbserial-B"]])
        model.finishDeviceSetup(portPath: nil, baudRate: nil, mode: .fullScan)
        checkSetup(); XCTAssertEqual(setupStarts.count, 2)
    }
    func testUSBHotplugWaitsDuringRXOpeningAndIsConsumedBySuccessfulConnection() {
        for succeeds in [false, true] {
            let h = ConnectionHarness(selectPort: false)
            h.listing.paths = ["/dev/cu.usbserial-A"]
            var starts: [[String]] = []
            h.model.checkUSBStartup(simulationSelected: false) { ports in
                starts.append(ports)
                _ = h.model.connectDevelopment(portPath: ports[0], baudRate: .baud500000)
            }
            h.listing.paths.append("/dev/cu.usbserial-B")
            h.model.checkUSBStartup(simulationSelected: false) { starts.append($0) }
            XCTAssertEqual(starts.count, 1, "Opening RX still owns the port")
            if succeeds {
                h.coordinator.simulateFirstProfile(portPath: "/dev/cu.usbserial-A", rateHz: 25, pointCount: 361)
                h.model.checkUSBStartup(simulationSelected: false) { starts.append($0) }
            }
            h.coordinator.simulateStreamLost(portPath: "/dev/cu.usbserial-A", message: "offline")
            h.model.checkUSBStartup(simulationSelected: false) { starts.append($0) }
            XCTAssertEqual(starts, succeeds ? [["/dev/cu.usbserial-A"]] : [["/dev/cu.usbserial-A"], ["/dev/cu.usbserial-A", "/dev/cu.usbserial-B"]])
        }
    }
    func testExplicitDisconnectWinsOverLateSuccessfulSetupAndStandardReports() {
        let coordinator = SpyStandardConnectionCoordinator(), listing = FakeSerialPortListing()
        let model = StandardConnectionControlModel(coordinator: coordinator, runProvider: ScriptedStandardConnectionRunProvider(),
            dispatcher: ManualCommissioningDispatcher(), portListing: listing, releaseOutputs: { $0() })
        model.selectPort(ConnectionHarness.portPath)
        var starts = 0
        model.beginDeviceSetup(mode: .fullScan) { starts += 1 }
        XCTAssertEqual(starts, 1)
        model.cancelPendingDeviceSetup() // worker has started; its success is already queued
        model.finishDeviceSetup(portPath: ConnectionHarness.portPath, baudRate: .baud500000, mode: .fullScan)
        XCTAssertTrue(coordinator.connectRequests.isEmpty)
        XCTAssertEqual(coordinator.portOwner, .free)
        XCTAssertEqual(model.notice, "Connection cancelled by user.")
        coordinator.disconnect(); coordinator.simulatePortReleased()
        listing.paths = [ConnectionHarness.portPath, "/dev/cu.usbserial-LATER"]
        model.checkUSBStartup(simulationSelected: false) { _ in starts += 1 }
        XCTAssertEqual(starts, 1, "A late success must not re-enable USB startup")

        for closeAlreadyScheduled in [false, true] {
            let h = ConnectionHarness(); h.preparePassiveSuccess()
            XCTAssertEqual(h.model.connect(), .started)
            XCTAssertTrue(h.dispatcher.runNextBackground()) // successful report awaits Main
            if closeAlreadyScheduled {
                while h.dispatcher.deliverNextMain() {}
                XCTAssertEqual(h.model.runStage, .releasingTransmitPort)
            }
            h.model.disconnect(); h.settle()
            XCTAssertTrue(h.coordinator.connectRequests.isEmpty)
            XCTAssertEqual(h.coordinator.portOwner, .free)
            XCTAssertFalse(h.provider.transport.isOpen)
            XCTAssertEqual(h.model.notice, "Connection cancelled by user.")
        }
    }
    func testConnectUsesFullScanDefaultThroughRealRun() {
        for choice in [nil, ScannerMeasurementMode.fullScan] {
            let harness = ConnectionHarness(measurementMode: choice)
            let expected: ScannerMeasurementMode = .fullScan
            harness.provider.prepareTransport = { transport in
                transport.readScript = [.standardFrame(standardScanProfileFrame(pointCount: expected == .fullScan ? 361 : 90))]
            }
            XCTAssertEqual(harness.model.measurementMode, expected)
            XCTAssertEqual(harness.connectToCompletion(), .started)
            XCTAssertEqual(harness.provider.requestedModes, [expected])
            XCTAssertEqual(harness.coordinator.events, ["requestAccess", "finishCommissioning", "rxConnect"])
            XCTAssertEqual(harness.coordinator.connectRequests.count, 1)
            XCTAssertFalse(harness.provider.transport.isOpen)
        }
    }
    func testOldMeasurementChoiceIsNeverReadOrWritten() {
        let harness = ConnectionHarness()
        let name = "LocalMeasurementChoice-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        func restored() -> StandardConnectionControlModel {
            StandardConnectionControlModel(coordinator: harness.coordinator, runProvider: harness.provider,
                dispatcher: harness.dispatcher, defaults: defaults)
        }
        XCTAssertEqual(restored().measurementMode, .fullScan)
        for oldValue in ["fullScan", "mmk", "invalid"] {
            defaults.set(oldValue, forKey: "Planarium.MeasurementMode.v1")
            let model = restored()
            XCTAssertEqual(model.measurementMode, .fullScan)
            model.selectMeasurementMode(.fullScan)
            XCTAssertEqual(defaults.string(forKey: "Planarium.MeasurementMode.v1"), oldValue)
            XCTAssertTrue(harness.coordinator.events.isEmpty)
            XCTAssertEqual(harness.coordinator.portOwner, .free)
        }
        defaults.set("invalid", forKey: "Planarium.MeasurementMode.v1")
        XCTAssertEqual(restored().measurementMode, .fullScan)
    }

    func testDeviceSetupWaitsForOutputAcknowledgementAndRealRXCloseInBothOrders() throws {
        for releaseBeforeAck in [true, false] {
            let harness = ConnectionHarness()
            let defaults = UserDefaults(suiteName: "BuendelMode-\(UUID())")!
            var acknowledge: (() -> Void)?
            var releaseRequests = 0
            let model = StandardConnectionControlModel(coordinator: harness.coordinator,
                runProvider: harness.provider, dispatcher: harness.dispatcher, defaults: defaults,
                releaseOutputs: { releaseRequests += 1; acknowledge = $0 })
            _ = model.connectDevelopment(portPath: ConnectionHarness.portPath, baudRate: .baud500000)
            var starts = 0
            model.beginDeviceSetup(mode: .fullScan) { starts += 1 }
            XCTAssertEqual(releaseRequests, 1, "A measurement mode switch must release outputs first")
            harness.dispatcher.runToCompletion()
            XCTAssertEqual(starts, 0, "No setup before the output release acknowledgement")
            if releaseBeforeAck { harness.coordinator.disconnect(); harness.coordinator.simulatePortReleased(); harness.dispatcher.runToCompletion() }
            try XCTUnwrap(acknowledge)()
            if !releaseBeforeAck {
                XCTAssertEqual(starts, 0, "RX still owns the port until real close")
                harness.coordinator.simulatePortReleased(); harness.dispatcher.runToCompletion()
            }
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(harness.coordinator.portOwner, .commissioning)
            model.finishDeviceSetup(portPath: ConnectionHarness.portPath, baudRate: .baud500000, mode: .mmk)
            XCTAssertEqual(harness.coordinator.portOwner, .monitor)
            XCTAssertEqual(model.measurementMode, .mmk)
            XCTAssertNil(defaults.string(forKey: "Planarium.MeasurementMode.v1"))
        }
    }
    func testCancelledPendingDeviceSetupCannotStartOnALateAcknowledgement() {
        let harness = ConnectionHarness()
        var acknowledge: (() -> Void)?
        let model = StandardConnectionControlModel(coordinator: harness.coordinator, runProvider: harness.provider,
            dispatcher: harness.dispatcher, defaults: UserDefaults(suiteName: "CancelledMode-\(UUID())")!, releaseOutputs: { acknowledge = $0 })
        var starts = 0
        model.beginDeviceSetup(mode: .fullScan) { starts += 1 }
        model.cancelPendingDeviceSetup(); acknowledge?(); harness.dispatcher.runToCompletion()
        XCTAssertEqual(starts, 0); XCTAssertFalse(model.deviceSetupActive)
    }
    func testPreviousSetupAcknowledgementCannotReleaseTheNextGeneration() throws {
        let harness = ConnectionHarness()
        var acknowledgements: [() -> Void] = []
        let model = StandardConnectionControlModel(coordinator: harness.coordinator, runProvider: harness.provider,
            dispatcher: harness.dispatcher, defaults: UserDefaults(suiteName: "ModeGeneration-\(UUID())")!,
            releaseOutputs: { acknowledgements.append($0) })
        var starts = 0
        model.beginDeviceSetup(mode: .fullScan) { starts += 1 }; model.cancelPendingDeviceSetup()
        model.beginDeviceSetup(mode: .fullScan) { starts += 1 }
        XCTAssertEqual(acknowledgements.count, 2)
        guard acknowledgements.count == 2 else { return }
        acknowledgements[0](); harness.dispatcher.runToCompletion()
        XCTAssertEqual(starts, 0)
        acknowledgements[1](); harness.dispatcher.runToCompletion()
        XCTAssertEqual(starts, 1)
        model.finishDeviceSetup(portPath: nil, baudRate: nil, mode: .mmk)
    }
    func testDeviceSetupRequiresAnInstalledOutputReleaseBoundary() {
        let harness = ConnectionHarness()
        var starts = 0
        harness.model.beginDeviceSetup(mode: .fullScan) { starts += 1 }
        XCTAssertEqual(starts, 0); XCTAssertFalse(harness.model.deviceSetupActive)
        XCTAssertTrue(harness.model.notice?.contains("no output release boundary") == true)
        XCTAssertEqual(harness.coordinator.portOwner, .free)
    }

    func testScannerConnectIsRejectedWhileSimulationRunsWithoutDisconnect() {
        let harness = ConnectionHarness()
        harness.coordinator.holdSimulationForTest()

        XCTAssertEqual(
            harness.model.connectDevelopment(portPath: ConnectionHarness.portPath, baudRate: .baud38400),
            .refused(.heldBySimulation)
        )
        XCTAssertEqual(
            harness.model.connect(),
            .refused(.heldBySimulation)
        )
        XCTAssertEqual(
            harness.model.notice,
            "The iPhone simulation is still using this port. Please disconnect first."
        )
        XCTAssertEqual(harness.coordinator.portOwner, .simulation)
        XCTAssertEqual(harness.coordinator.disconnectCount, 0)
        XCTAssertTrue(harness.coordinator.isAwaitingPortRelease == false)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("Bedingung nicht innerhalb von \(timeout)s erfüllt", file: file, line: line)
    }

    func testRealDisconnectReleaseUpdatesBarWithoutAnotherEvent() {
        let descriptor = DISCDisconnectDescriptor()
        let session = RXSession(
            opener: DISCDisconnectOpener(descriptor: descriptor),
            readTimeoutMilliseconds: 10
        )
        let coordinator = ScannerWorkspaceModel(
            session: session
        )
        let model = StandardConnectionControlModel(
            coordinator: coordinator,
            runProvider: ScriptedStandardConnectionRunProvider(),
            dispatcher: ManualCommissioningDispatcher(),
            portListing: FakeSerialPortListing(),
            defaults: UserDefaults(suiteName: "ConnectionDisconnect-\(UUID())")!
        )
        let commissioningModel = CommissioningControlModel(
            coordinator: coordinator,
            runProvider: SpyRunProvider(),
            dispatcher: ManualCommissioningDispatcher(),
            portListing: FakeSerialPortListing(),
            passwordStore: FakeScannerPasswordStore(initial: fabricatedSecretText)
        )

        XCTAssertEqual(
            model.connectDevelopment(portPath: "/dev/cu.disc-test", baudRate: .baud9600),
            MonitorConnectOutcome.connecting(baudRate: .baud9600)
        )
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.disc-test", baudRate: .baud9600) }

        model.disconnect()
        XCTAssertEqual(
            model.barState,
            ConnectionBarState.disconnecting(portPath: "/dev/cu.disc-test"),
            "Die Klick-Kante muss bis zur echten Freigabe als laufend schließen erscheinen"
        )
        waitUntil { !session.isPortHeld }

        XCTAssertEqual(
            model.barState,
            ConnectionBarState.disconnectedScannerMaySend(portPath: "/dev/cu.disc-test"),
            "Nach portReleased muss die Leiste ohne weiteres Ereignis den finalen Zustand zeigen"
        )
        XCTAssertFalse(commissioningModel.isAwaitingPortRelease)
        XCTAssertEqual(commissioningModel.portOwner, .free)
    }

    // MARK: - Der Standardweg

    func testPassiveSuccessClosesTheTransmitPortBeforeMeasurementStarts() {
        let harness = ConnectionHarness()
        harness.preparePassiveSuccess()
        var transmitPortWasClosedAtConnect: Bool?
        harness.coordinator.onConnect = {
            transmitPortWasClosedAtConnect = !harness.provider.transport.isOpen
                && harness.provider.transport.closeCount == 1
        }

        XCTAssertEqual(harness.connectToCompletion(), .started)

        XCTAssertEqual(transmitPortWasClosedAtConnect, true, "RX beginnt erst nach dem echten Schluss")
        XCTAssertEqual(
            harness.coordinator.events,
            ["requestAccess", "finishCommissioning", "rxConnect"],
            "Besitz anfordern, nach dem Schluss zurückgeben, dann RX beanspruchen"
        )
        XCTAssertEqual(harness.coordinator.finishedBaudRates, [.baud38400])
        XCTAssertEqual(harness.coordinator.connectRequests.count, 1)
        XCTAssertEqual(harness.coordinator.connectRequests[0].baudRate, .baud38400)
        XCTAssertEqual(harness.coordinator.connectRequests[0].portPath, ConnectionHarness.portPath)
        XCTAssertEqual(harness.coordinator.portOwner, .monitor)
        XCTAssertEqual(harness.model.runStage, .idle)
        XCTAssertEqual(harness.model.barState, .openingMeasurement(portPath: ConnectionHarness.portPath))
    }

    func testTheProgressBoundaryIsObservedAsRealTransitions() {
        let harness = ConnectionHarness()
        harness.prepareFullFallback()

        harness.connectToCompletion()

        XCTAssertEqual(harness.model.observedPhases, [
            .observingPassively,
            .checkingIdentityAtTargetRate,
            .runningCommissioning(.checkingStartingRate, origin: .fallbackFromStartingRate),
            .runningCommissioning(.respondingAtStartingRate, origin: .fallbackFromStartingRate),
            .runningCommissioning(.loggingInAndSwitchingBaudRate, origin: .fallbackFromStartingRate),
            .runningCommissioning(.verifiedAtTargetRate, origin: .fallbackFromStartingRate),
            .runningCommissioning(.awaitingMeasurementStream, origin: .fallbackFromStartingRate),
            .ready(.commissioningFallbackMeasurementStream)
        ])
        XCTAssertEqual(harness.coordinator.events.last, "rxConnect")
        XCTAssertFalse(harness.provider.transport.isOpen)
        XCTAssertEqual(harness.provider.passwordStore.loadCount, 1)
    }

    func testTheBarFollowsEachProgressReportWhileTheRunIsStillBlocking() {
        let harness = ConnectionHarness()
        harness.prepareFullFallback()
        harness.model.connect()
        XCTAssertEqual(harness.model.barState, .observing(portPath: ConnectionHarness.portPath))

        // Der Hintergrundlauf ist komplett durch, seine Zwischenberichte
        // liegen noch in der Hauptwarteschlange -- einer nach dem anderen.
        harness.dispatcher.runNextBackground()
        harness.dispatcher.deliverNextMain()
        XCTAssertEqual(harness.model.barState, .observing(portPath: ConnectionHarness.portPath))
        harness.dispatcher.deliverNextMain()
        XCTAssertEqual(harness.model.barState, .checkingIdentity(portPath: ConnectionHarness.portPath))
        harness.dispatcher.deliverNextMain()
        XCTAssertEqual(
            harness.model.barState,
            .preparing(portPath: ConnectionHarness.portPath, stage: .checkingStartingRate)
        )
        harness.settle()
        XCTAssertEqual(harness.model.barState, .openingMeasurement(portPath: ConnectionHarness.portPath))
    }

    func testReadyStateCarriesRateAndPointCountFromTheSession() {
        let harness = ConnectionHarness()
        harness.preparePassiveSuccess()
        harness.connectToCompletion()

        harness.coordinator.simulateFirstProfile(portPath: ConnectionHarness.portPath, rateHz: 12.4, pointCount: 90)

        XCTAssertEqual(
            harness.model.barState,
            .ready(portPath: ConnectionHarness.portPath, pointCount: 90)
        )
        XCTAssertEqual(ConnectionBarPresentation(harness.model.barState, profileRateHz: 12.4).statusText, "Ready – 90 points, 12,4 Hz.")
        XCTAssertTrue(harness.model.presentation.showsDisconnect)
    }

    func testVerifiedDevelopmentEndpointFeedsMainMeasurementAndIsReusedAfterDisconnect() {
        let harness = ConnectionHarness()

        XCTAssertEqual(
            harness.model.connectDevelopment(
                portPath: ConnectionHarness.portPath,
                baudRate: .baud500000
            ),
            .connecting(baudRate: .baud500000)
        )
        XCTAssertEqual(harness.model.selectedPortPath, ConnectionHarness.portPath)
        XCTAssertEqual(harness.coordinator.connectRequests.map(\.baudRate), [.baud500000])
        XCTAssertTrue(harness.provider.runs.isEmpty, "Der alte 38.400-Baud-Standardlauf darf nicht starten")

        harness.model.disconnect()
        harness.coordinator.simulatePortReleased()

        XCTAssertEqual(harness.model.connect(), .started)
        XCTAssertEqual(harness.coordinator.connectRequests.map(\.baudRate), [.baud500000, .baud500000])
        XCTAssertTrue(harness.provider.runs.isEmpty, "Auch erneutes Verbinden nutzt den belegten Endpunkt")
    }

    // MARK: - Gegenprobe: Ohne echten Schluss kein RX

    /// Wird der Besitz zurückgegeben, **bevor** der Port real zu ist,
    /// verweigert das echte Besitzmodell nichts -- deshalb prüft diese
    /// Gegenprobe die andere Richtung: Ein RX-Anspruch **vor** der
    /// Rückgabe wird vom echten ``SerialPortOwnership`` abgelehnt. Das
    /// Modell ruft ihn strukturell erst danach; hier wird belegt, dass
    /// die Ablehnung real wäre.
    func testCounterProofAMeasurementClaimWhileTheRunHoldsTheOwnershipIsRefused() {
        let harness = ConnectionHarness()
        harness.preparePassiveSuccess()
        harness.model.connect()
        harness.dispatcher.runNextBackground()
        // Der Lauf ist bei `.ready` mit gehaltenem Port; der Schluss
        // steht noch aus.
        XCTAssertEqual(harness.coordinator.portOwner, .commissioning)
        let premature = harness.coordinator.connect(portPath: ConnectionHarness.portPath, baudRate: .baud38400)
        XCTAssertEqual(premature, .refused(.heldByCommissioning))
    }

    // MARK: - Fehlgeschlagener Schluss

    func testAFailedTransmitPortCloseKeepsTheRunAndOffersARetry() {
        let harness = ConnectionHarness()
        harness.provider.prepareTransport = { transport in
            transport.readScript = [.standardFrame(standardScanProfileFrame())]
            transport.alwaysFailClose = .openFailed("Schluss schlägt fehl")
        }

        harness.connectToCompletion()

        XCTAssertEqual(harness.model.barState, .transmitPortStillHeld(portPath: ConnectionHarness.portPath))
        XCTAssertTrue(harness.model.presentation.offersCloseRetry)
        XCTAssertEqual(harness.coordinator.events, ["requestAccess"], "Kein Besitzwechsel, kein RX")
        XCTAssertEqual(harness.coordinator.portOwner, .commissioning)

        harness.provider.transport.alwaysFailClose = nil
        harness.model.retryClose()
        harness.settle()

        XCTAssertEqual(harness.coordinator.events, ["requestAccess", "finishCommissioning", "rxConnect"])
        XCTAssertEqual(harness.model.barState, .openingMeasurement(portPath: ConnectionHarness.portPath))
        XCTAssertEqual(harness.provider.transport.closeCount, 1)
    }

    // MARK: - Fehlschläge geben den Besitz genau einmal zurück

    func testAMissingPasswordEndsWithTheSettingsHintAndReleasesOwnership() {
        let harness = ConnectionHarness(storedPassword: "")
        harness.prepareFullFallback()

        harness.connectToCompletion()

        XCTAssertEqual(
            harness.model.barState,
            .failed(portPath: ConnectionHarness.portPath, failure: .missingOrUnusablePassword)
        )
        XCTAssertEqual(harness.coordinator.events, ["requestAccess", "finishCommissioning"])
        XCTAssertEqual(harness.coordinator.finishedBaudRates, [nil])
        XCTAssertEqual(harness.coordinator.portOwner, .free)
        XCTAssertTrue(harness.model.presentation.nextActionText?.contains("Settings") == true)
        XCTAssertFalse(harness.provider.transport.isOpen)
    }

    func testAPortOpenFailureIsShownAsBusyOrUnreachable() {
        let harness = ConnectionHarness()
        harness.provider.prepareTransport = { $0.failNextOpen = .openFailed("EBUSY simuliert") }

        harness.connectToCompletion()

        XCTAssertEqual(harness.model.barState, .failed(portPath: ConnectionHarness.portPath, failure: .portOpenFailed))
        XCTAssertTrue(harness.model.presentation.nextActionText?.contains("busy") == true)
        XCTAssertEqual(harness.coordinator.portOwner, .free)
    }

    func testAnUnavailableRunReturnsOwnershipWithoutStartingAnything() {
        let harness = ConnectionHarness()
        harness.provider.failure = .transportUnavailable

        XCTAssertEqual(harness.model.connect(), .refusedRunUnavailable(.transportUnavailable))
        XCTAssertEqual(harness.coordinator.events, ["requestAccess", "finishCommissioning"])
        XCTAssertEqual(harness.coordinator.portOwner, .free)
        XCTAssertEqual(harness.model.barState, .disconnected)
        XCTAssertNotNil(harness.model.notice)
        XCTAssertTrue(harness.dispatcher.backgroundWork.isEmpty, "Nichts eingeplant")
    }

    // MARK: - Trennen

    func testDisconnectDuringTheRunIsACooperativeAbort() {
        let harness = ConnectionHarness()
        harness.provider.prepareTransport = { transport in
            // Kein Frame: der passive Lesevorgang läuft; der Abbruch kommt
            // aus der Bedienung, deterministisch beim ersten Read.
            transport.onRead = { [weak harness = harness.model] in harness?.disconnect() }
        }
        harness.model.connect()
        XCTAssertTrue(harness.model.presentation.showsDisconnect)

        harness.settle()

        XCTAssertEqual(harness.model.barState, .failed(portPath: ConnectionHarness.portPath, failure: .aborted))
        XCTAssertEqual(harness.coordinator.events, ["requestAccess", "finishCommissioning"])
        XCTAssertEqual(harness.coordinator.portOwner, .free)
        XCTAssertFalse(harness.provider.transport.isOpen)
    }

    func testDisconnectDuringMeasurementExplainsThatTheScannerMayKeepSending() {
        let harness = ConnectionHarness()
        harness.preparePassiveSuccess()
        harness.connectToCompletion()
        harness.coordinator.simulateFirstProfile(portPath: ConnectionHarness.portPath, rateHz: 12.5, pointCount: 90)

        harness.model.disconnect()

        XCTAssertEqual(harness.coordinator.disconnectCount, 1)
        XCTAssertEqual(harness.model.barState, .ready(portPath: ConnectionHarness.portPath, pointCount: 90),
                       "Bis zum echten Freigabe-Ereignis bleibt die Sitzungslage maßgeblich")
        harness.coordinator.simulatePortReleased()
        XCTAssertEqual(harness.model.barState, .disconnectedScannerMaySend(portPath: ConnectionHarness.portPath))
        XCTAssertEqual(harness.model.presentation.statusText, "Disconnected – scanner may still be sending.")
        XCTAssertFalse(harness.model.presentation.showsDisconnect)
    }

    func testStreamLossIsShownWithTheRedactedSessionText() {
        let harness = ConnectionHarness()
        harness.preparePassiveSuccess()
        harness.connectToCompletion()

        harness.coordinator.simulateStreamLost(
            portPath: ConnectionHarness.portPath, message: "Connection ended unexpectedly (end of stream)."
        )

        XCTAssertEqual(
            harness.model.barState,
            .streamLost(portPath: ConnectionHarness.portPath, message: "Connection ended unexpectedly (end of stream).")
        )
        XCTAssertEqual(harness.model.presentation.nextActionText, "Reconnect.")
        XCTAssertFalse(harness.model.presentation.isBusy)
    }

    // MARK: - Sperren

    func testASecondConnectWhileBusyIsRefused() {
        let harness = ConnectionHarness()
        harness.preparePassiveSuccess()
        XCTAssertEqual(harness.model.connect(), .started)
        XCTAssertEqual(harness.model.connect(), .refusedBusy)
        XCTAssertEqual(harness.provider.runs.count, 1, "Kein zweiter Lauf")
        XCTAssertEqual(harness.coordinator.events, ["requestAccess"])
    }

    func testConnectWithoutASelectedPortStartsNothing() {
        let harness = ConnectionHarness(selectPort: false)
        XCTAssertEqual(harness.model.connect(), .refusedNoPortSelected)
        XCTAssertTrue(harness.coordinator.events.isEmpty)
        XCTAssertTrue(harness.provider.runs.isEmpty)
    }

    func testPortSelectionIsLockedWhileTheRunHoldsThePort() {
        let harness = ConnectionHarness()
        harness.preparePassiveSuccess()
        harness.model.connect()
        harness.model.selectPort("/dev/cu.other")
        XCTAssertEqual(harness.model.selectedPortPath, ConnectionHarness.portPath)
        harness.settle()
        harness.model.selectPort("/dev/cu.other")
        XCTAssertEqual(harness.model.selectedPortPath, "/dev/cu.other", "Nach dem Lauf wieder frei")
    }

    // MARK: - Automatischer Portkandidatenlauf

    func testAutomaticSearchChecksCandidatesSequentiallyAndStopsOnTheFirstReadyPort() {
        let harness = ConnectionHarness(selectPort: false)
        let first = "/dev/cu.usbserial-NONE"
        let second = "/dev/cu.usbserial-SCANNER"
        let third = "/dev/cu.usbserial-UNTOUCHED"
        harness.listing.paths = [first, second, third]
        harness.provider.prepareTransportForPort = { path, transport in
            if path == first {
                transport.failNextOpen = .openFailed("nicht vorhanden")
            } else if path == second {
                transport.readScript = [.standardFrame(standardScanProfileFrame())]
            } else {
                XCTFail("Nach dem belegten Scanner darf kein weiterer Kandidat starten")
            }
        }

        XCTAssertEqual(harness.model.connectAutomatically(), .started(candidateCount: 3))
        harness.settle()

        XCTAssertEqual(harness.provider.runs.count, 2)
        XCTAssertEqual(harness.coordinator.connectRequests.map(\.portPath), [second])
        XCTAssertEqual(harness.model.selectedPortPath, second)
        XCTAssertNil(harness.model.automaticSearchProgress)
        XCTAssertEqual(harness.model.automaticSearchAttempts, [
            .init(portPath: first, result: .failed(.portOpenFailed)),
            .init(portPath: second, result: .ready)
        ])
    }

    func testAutomaticSearchPublishesTheCurrentPortAndOrdinalBeforeWorkRuns() {
        let harness = ConnectionHarness(selectPort: false)
        harness.listing.paths = ["/dev/cu.usbserial-first", "/dev/cu.usbserial-second"]
        harness.preparePassiveSuccess()

        XCTAssertEqual(harness.model.connectAutomatically(), .started(candidateCount: 2))

        XCTAssertEqual(
            harness.model.automaticSearchProgress,
            AutomaticPortSearchProgress(portPath: "/dev/cu.usbserial-first", candidateNumber: 1, candidateCount: 2)
        )
        XCTAssertEqual(
            harness.model.automaticSearchProgress?.operatorText,
            "Searching for scanner (1/2): /dev/cu.usbserial-first"
        )
    }

    func testAutomaticSearchStopsAtAnIdentifiedScannerThatNeedsThePassword() {
        let harness = ConnectionHarness(storedPassword: "", selectPort: false)
        harness.listing.paths = ["/dev/cu.usbserial-A-scanner", "/dev/cu.usbserial-B-other"]
        harness.prepareFullFallback()

        XCTAssertEqual(harness.model.connectAutomatically(), .started(candidateCount: 2))
        harness.settle()

        XCTAssertEqual(harness.provider.runs.count, 1, "Ein erkannter Scannerfehler ist kein Anlass, andere Ports zu senden")
        XCTAssertEqual(harness.model.selectedPortPath, "/dev/cu.usbserial-A-scanner")
        XCTAssertEqual(harness.model.automaticSearchAttempts, [
            .init(portPath: "/dev/cu.usbserial-A-scanner", result: .failed(.missingOrUnusablePassword))
        ])
        XCTAssertNil(harness.model.automaticSearchProgress)
    }

    func testAutomaticSearchWithNoCandidatesStartsNothing() {
        let harness = ConnectionHarness(selectPort: false)
        harness.listing.paths = []

        XCTAssertEqual(harness.model.connectAutomatically(), .refusedNoCandidates)
        XCTAssertTrue(harness.provider.runs.isEmpty)
        XCTAssertEqual(harness.model.notice, StandardConnectionControlModel.noUSBAdapterNotice)
    }

    func testAConnectWhileTheMonitorHoldsThePortAsksForADisconnectFirst() {
        let harness = ConnectionHarness()
        harness.preparePassiveSuccess()
        harness.connectToCompletion()
        // RX hält den Port. Ein zweiter Verbindungsversuch wartet auf die
        // echte Freigabe, statt einen zweiten Port zu öffnen.
        XCTAssertEqual(harness.model.connect(), .awaitingPortRelease)
        XCTAssertEqual(harness.provider.runs.count, 1)
        XCTAssertEqual(harness.coordinator.disconnectCount, 1)
    }

    // MARK: - Evidenz

    func testEvidenceExportContainsTheReferenceMeasurementLineIndented() {
        let harness = ConnectionHarness()
        harness.preparePassiveSuccess()
        harness.connectToCompletion()

        harness.coordinator.referenceMeasurementLine =
            "Reference index 180: n=12 min=412 max=438 median=425.0 mean=424.83 sigma=8.12 countAtZero=0 countAt8191=0 withoutIndex=0\n"
            + "Reference index 270: n=12 min=398 max=421 median=410.0 mean=409.58 sigma=6.44 countAtZero=0 countAt8191=0 withoutIndex=0"

        let text = harness.model.evidenceExportText()

        XCTAssertTrue(text.contains("Reference measurement:"))
        XCTAssertTrue(
            text.contains("  Reference index 180: n=12 min=412 max=438 median=425.0 mean=424.83 sigma=8.12 countAtZero=0 countAt8191=0 withoutIndex=0"),
            "Erste Zeile muss um zwei Leerzeichen eingerückt sein"
        )
        XCTAssertTrue(
            text.contains("  Reference index 270: n=12 min=398 max=421 median=410.0 mean=409.58 sigma=6.44 countAtZero=0 countAt8191=0 withoutIndex=0"),
            "Zweite Zeile muss um zwei Leerzeichen eingerückt sein"
        )
    }

    func testEvidenceExportShowsTheDefaultReferenceLineWhenNoMeasurementIsRunning() {
        let harness = ConnectionHarness()
        harness.preparePassiveSuccess()
        harness.connectToCompletion()

        let text = harness.model.evidenceExportText()

        XCTAssertTrue(text.contains("Reference measurement:"))
        XCTAssertTrue(text.contains("  Reference measurement: not running"))
    }

    func testEvidenceExportNeverContainsThePasswordAndListsBothAudits() {
        let harness = ConnectionHarness(storedPassword: "GEHEIMXX")
        harness.prepareFullFallback()
        harness.connectToCompletion()
        harness.coordinator.streamEvidence = MeasurementStreamEvidence(
            status: .streaming(portPath: ConnectionHarness.portPath, pointCount: 90),
            deliveredProfileBatches: 7, readsWithSeveralProfiles: 2,
            validFrames: 9, discardedCandidates: 1, discardedCandidatesOversize: 0,
            discardedCandidatesChecksumMismatch: 1, discardedCandidatesAtFinish: 0, skippedNoiseBytes: 3
        )

        let text = harness.model.evidenceExportText()

        XCTAssertFalse(text.contains("GEHEIMXX"), "Das Passwort erreicht den Export nie")
        XCTAssertTrue(text.contains("Connection: \(ConnectionHarness.portPath)"))
        XCTAssertTrue(text.contains("Ready (Measurement stream after full commissioning)"))
        XCTAssertTrue(text.contains("Run audit:"))
        XCTAssertTrue(text.contains("Commissioning audit:"))
        XCTAssertTrue(text.contains("Login (attempt 1) → Acknowledged"))
        XCTAssertTrue(text.contains("Delivered read operations: 7"))
        XCTAssertTrue(text.contains("reads with several profiles: 2"))
        XCTAssertTrue(text.contains("of which CRC errors: 1"))
        XCTAssertTrue(text.contains("Port held: no; final: yes"))
    }

}

private final class DISCDisconnectDescriptor: SerialPortFileDescriptor {
    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        Thread.sleep(forTimeInterval: TimeInterval(timeoutMilliseconds) / 1000.0)
        return .timeout
    }

    func close() {
        Thread.sleep(forTimeInterval: 0.05)
    }
}

private final class DISCDisconnectOpener: SerialPortOpener {
    let descriptor: DISCDisconnectDescriptor

    init(descriptor: DISCDisconnectDescriptor) {
        self.descriptor = descriptor
    }

    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> SerialPortFileDescriptor {
        descriptor
    }
}
