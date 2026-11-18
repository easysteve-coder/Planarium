import XCTest
import SickPLSActiveControl
import SickPLSCommissioning
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSSetupControl

final class SafeScannerSetupWorkflowTests: XCTestCase {
    @MainActor func testProductionSetupNeverPublishesForeignPortErrorText() {
        let marker = "fabricated-port-marker-\(UUID())"
        let device = SimulatedScanner(baudRate: .baud500000, streaming: true)
        device.modeWriteError = MarkerPortFailure(description: marker)
        let model = SetupConsoleModel(opener: device)
        model.selectedPort = "/dev/cu.test"
        let finished = expectation(description: "port failure without mode fallback")
        model.performSafeBaudTransition(measurementMode: .fullScan) { endpoint, mode in
            XCTAssertEqual(mode, .fullScan)
            XCTAssertNil(endpoint)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(model.status.contains(marker), "Foreign port error text must not reach status")
        XCTAssertFalse(model.transcript.contains { $0.message.contains(marker) })
        XCTAssertTrue(model.status.contains("failed while accessing the port"))
        XCTAssertEqual(device.openPorts, 0)
    }
    @MainActor func testProductionSetupReportsActualStateAfterNACKAndMidRequestAbortWithoutFallback() {
        for abort in [false, true] {
            let device = SimulatedScanner(baudRate: .baud500000, streaming: true)
            let model = SetupConsoleModel(opener: device)
            model.selectedPort = "/dev/cu.test"
            device.rejectFullScan = !abort
            if abort { device.onFullScanWrite = { model.abortSafeTransition() } }
            let finished = expectation(description: "closed setup port, no fallback")
            model.performSafeBaudTransition(measurementMode: .fullScan) { endpoint, mode in
                XCTAssertEqual(mode, .fullScan)
                XCTAssertNil(endpoint)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 5)
            XCTAssertFalse(device.configurationCommands.contains(0x20))
            XCTAssertEqual(device.openPorts, 0)
            XCTAssertEqual(device.maximumOpenPorts, 1)
            XCTAssertTrue(model.status.contains("\(abort ? 361 : 90) points at 500000 baud"))
            XCTAssertTrue(model.status.contains(abort ? "aborted" : "rejected"))
            XCTAssertTrue(model.status.hasSuffix("Retry Connect."))
            XCTAssertFalse(model.status.contains("unreachable"))
            XCTAssertFalse(model.canTryAnotherPort)
            XCTAssertFalse(model.isBusy)
        }
    }
    func testBothMeasurementOrdersVerifyTheNewPointCountAndCloseBeforeReopen() throws {
        for modes: [ScannerMeasurementMode] in [[.mmk, .fullScan, .mmk], [.fullScan, .mmk, .fullScan]] {
            let device = SimulatedScanner(baudRate: .baud500000, streaming: true)
            for mode in modes {
                let result = try SafeScannerSetupWorkflow(opener: device).transition(portPath: "/dev/cu.test",
                    targetRate: .baud500000, address: address, secret: secret, measurementMode: mode)
                XCTAssertEqual(device.pointCount, mode.pointCount)
                XCTAssertEqual(device.maximumOpenPorts, 1)
                result.port.close()
                XCTAssertEqual(device.openPorts, 0)
                XCTAssertTrue(result.evidence.contains { $0.contains("\(mode.title) confirmed") })
            }
        }
    }
    func testWrongPointCountNACKPowerLossAndAbortCloseTheWorkerPort() throws {
        for fault in 0..<4 {
            let device = SimulatedScanner(baudRate: .baud38400, streaming: true)
            device.wrongCount = fault == 0
            device.rejectFullScan = fault == 1
            device.losePowerOnFullScan = fault == 2
            var checks = 0
            XCTAssertThrowsError(try SafeScannerSetupWorkflow(opener: device).transition(portPath: "/dev/cu.test",
                targetRate: .baud38400, address: address, secret: secret, measurementMode: .fullScan,
                isAborted: { checks += 1; return fault == 3 && checks >= 2 })) { error in
                if fault == 0 { XCTAssertEqual(error as? ScannerSetupWorkflowError, .measurementPointCountMismatch) }
                if fault == 1 { XCTAssertEqual(error as? ScannerSetupWorkflowError, .measurementModeRejected) }
                if fault == 3 { XCTAssertEqual(error as? ScannerSetupWorkflowError, .aborted) }
            }
            XCTAssertEqual(device.openPorts, 0)
            device.wrongCount = false; device.powerLoss = false
            let fallback = try SafeScannerSetupWorkflow(opener: device).transition(portPath: "/dev/cu.test",
                targetRate: .baud38400, address: address, secret: secret, measurementMode: .mmk)
            XCTAssertEqual(device.pointCount, 90)
            fallback.port.close(); XCTAssertEqual(device.openPorts, 0)
        }
    }
    private let address = ConfirmedTargetAddress(rawValue: 0x00)!
    private let secret = InstallationSecret(bytes: Array(repeating: 0x61, count: 8))!

    func testFullScanAdoptsEveryRatePassivelyBeforeAnyTX() throws {
        for rate in SafeScannerSetupWorkflow.supportedRates {
            let device = SimulatedScanner(baudRate: rate, streaming: true)
            device.pointCount = 361
            let result = try SafeScannerSetupWorkflow(opener: device).transition(
                portPath: "/dev/cu.test", targetRate: .baud500000, address: address,
                secret: secret, preferredRate: .baud9600, measurementMode: .fullScan)
            XCTAssertEqual(result.baudRate, rate)
            XCTAssertTrue(device.allWrites.isEmpty)
            XCTAssertEqual(device.openedRates.first, .baud9600)
            XCTAssertEqual(device.maximumOpenPorts, 1)
            result.port.close()
            XCTAssertEqual(device.openPorts, 0)
        }
    }

    func testSlow9600FullScanIsAdoptedWithoutTX() throws {
        let device = SimulatedScanner(baudRate: .baud9600, streaming: true)
        device.pointCount = 361
        device.passiveDelayMilliseconds = 3_500
        let result = try SafeScannerSetupWorkflow(opener: device).transition(
            portPath: "/dev/cu.test", targetRate: .baud500000, address: address,
            secret: secret, preferredRate: .baud9600, measurementMode: .fullScan)
        XCTAssertEqual(result.baudRate, .baud9600)
        XCTAssertTrue(device.allWrites.isEmpty)
        result.port.close()
        XCTAssertEqual(device.openPorts, 0)
    }

    @MainActor func testProductionPrefersOnlyObservedRateAndIgnoresUnverifiedBaudChoice() {
        let device = SimulatedScanner(baudRate: .baud38400, streaming: true)
        device.pointCount = 361
        let model = SetupConsoleModel(opener: device)
        model.selectedPort = "/dev/cu.test"
        for attempt in 0..<2 {
            device.openedRates = []
            model.selectedBaudRate = .baud9600
            let finished = expectation(description: "passive production adoption")
            model.performSafeBaudTransition { endpoint, mode in
                XCTAssertEqual(endpoint?.baudRate, .baud38400)
                XCTAssertEqual(mode, .fullScan)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 5)
            XCTAssertEqual(device.openedRates.first, attempt == 0 ? .baud500000 : .baud38400)
            XCTAssertTrue(device.allWrites.isEmpty)
            XCTAssertEqual(device.openPorts, 0)
            XCTAssertTrue(model.status.contains("Full scan 361 verified"))
        }
    }

    func testFresh9600SetupWaitsForThreeSecondRepliesAndRepeatsLostFirst500KSend() throws {
        let device = SimulatedScanner(baudRate: .baud9600, streaming: false)
        device.delayedAcknowledgements = true
        device.loseFirst500KSend = true
        let result = try SafeScannerSetupWorkflow(opener: device).transition(
            portPath: "/dev/cu.test", targetRate: .baud500000, address: address,
            secret: secret, measurementMode: .fullScan)
        XCTAssertEqual(result.baudRate, .baud500000)
        XCTAssertEqual(device.configurationCommands, [0x00, 0x48, 0x24])
        XCTAssertEqual(device.identityWritesAt500KAfterSwitch, 2)
        XCTAssertEqual(device.maximumOpenPorts, 1)
        result.port.close()
        XCTAssertEqual(device.openPorts, 0)
    }

    func testRunning90And180IgnoreSingleModeCommandAndQueueRepeatedReplies() throws {
        for count in [90, 180] {
            let device = SimulatedScanner(baudRate: .baud500000, streaming: true)
            device.pointCount = count
            device.ignoreFirstStreamingMode = true
            device.delayedAcknowledgements = true
            let result = try SafeScannerSetupWorkflow(opener: device).transition(
                portPath: "/dev/cu.test", targetRate: .baud500000, address: address,
                secret: secret, measurementMode: .fullScan)
            XCTAssertEqual(device.configurationCommands, [0x24, 0x24])
            XCTAssertEqual(device.pointCount, 361)
            XCTAssertGreaterThanOrEqual(device.modeWriteTimes[1] - device.modeWriteTimes[0], 1_000)
            XCTAssertTrue(result.evidence.contains { $0.contains("attempt 2") })
            result.port.close()
            XCTAssertEqual(device.openPorts, 0)
        }
    }

    func testIdle500KRepeatsLostDetectionAndVerificationSends() throws {
        let device = SimulatedScanner(baudRate: .baud500000, streaming: false)
        device.loseFirst500KSend = true
        device.delayedAcknowledgements = true
        let result = try SafeScannerSetupWorkflow(opener: device).transition(
            portPath: "/dev/cu.test", targetRate: .baud500000, address: address,
            secret: secret, measurementMode: .fullScan)
        XCTAssertEqual(result.baudRate, .baud500000)
        XCTAssertEqual(device.configurationCommands, [0x24])
        XCTAssertEqual(device.allWrites.filter { $0.dropFirst(4).first == 0x31 }.count, 4)
        result.port.close()
        XCTAssertEqual(device.openPorts, 0)
    }

    func testACKAndOnlyTwoFullScanProfilesNeverPublishSuccess() {
        let device = SimulatedScanner(baudRate: .baud500000, streaming: true)
        device.confirmationProfiles = 2
        XCTAssertThrowsError(try SafeScannerSetupWorkflow(opener: device).transition(
            portPath: "/dev/cu.test", targetRate: .baud500000, address: address,
            secret: secret, measurementMode: .fullScan))
        XCTAssertEqual(device.openPorts, 0)
        XCTAssertEqual(device.configurationCommands, Array(repeating: 0x24, count: 5))
    }

    @MainActor func testUnreachableRequiresNoCRCValidTelegramAtAnyRate() {
        for state in 0..<3 {
            let responding = state == 2
            let device = SimulatedScanner(baudRate: .baud500000, streaming: state != 0)
            device.powerLoss = state == 0
            device.crcInvalidOnly = state == 1
            device.wrongCount = true
            let model = SetupConsoleModel(opener: device)
            model.selectedPort = "/dev/cu.test"
            let finished = expectation(description: "failed full scan")
            model.performSafeBaudTransition { endpoint, mode in
                XCTAssertNil(endpoint)
                XCTAssertEqual(mode, .fullScan)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 5)
            XCTAssertEqual(model.scannerUnreachable, !responding)
            XCTAssertEqual(model.canTryAnotherPort, !responding)
            XCTAssertEqual(model.status.contains("unreachable"), !responding)
            if responding { XCTAssertTrue(model.status.contains("90 points at 500000 baud")) }
            XCTAssertEqual(device.openPorts, 0)
        }
    }

    @MainActor func testAutomaticSearchSkipsOpenFailureButStopsOnEarlyOrDetectionAbort() {
        for stage in 0..<3 {
            let abort = stage != 0
            let device = SimulatedScanner(baudRate: .baud500000, streaming: false)
            device.openFailure = !abort
            device.powerLoss = stage == 2
            let model = SetupConsoleModel(opener: device)
            model.selectedPort = "/dev/cu.test"
            if stage == 1 { device.onOpen = { model.abortSafeTransition() } }
            if stage == 2 { device.onWrite = { model.abortSafeTransition() } }
            let finished = expectation(description: "port failure or early abort")
            model.performSafeBaudTransition { endpoint, _ in
                XCTAssertNil(endpoint)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 5)
            XCTAssertEqual(model.canTryAnotherPort, !abort)
            XCTAssertFalse(model.scannerUnreachable)
            if abort { XCTAssertTrue(model.status.contains("aborted")) }
            XCTAssertEqual(device.openPorts, 0)
        }
    }

    func testFreshProcessDetects500KFromAValidProfileWithoutChangingState() throws {
        let device = SimulatedScanner(baudRate: .baud500000, streaming: true)
        let workflow = SafeScannerSetupWorkflow(opener: device)

        let result = try workflow.detectBaudRate(
            portPath: "/dev/cu.test", address: address, preferredRate: .baud9600
        )

        XCTAssertEqual(result.0, .baud500000)
        XCTAssertEqual(device.baudRate, .baud500000)
        XCTAssertTrue(device.streaming)
        XCTAssertEqual(device.configurationCommands, [])
    }

    func testSafeTransitionCovers500KDownshiftAndLeavesVerifiedMMKPortOpen() throws {
        let device = SimulatedScanner(baudRate: .baud500000, streaming: true)
        let workflow = SafeScannerSetupWorkflow(opener: device)

        let result = try workflow.transition(
            portPath: "/dev/cu.test",
            targetRate: .baud38400,
            address: address,
            secret: secret,
            preferredRate: .baud500000
        )

        XCTAssertEqual(result.baudRate, .baud38400)
        XCTAssertEqual(device.baudRate, .baud38400)
        XCTAssertTrue(device.streaming)
        XCTAssertEqual(device.configurationCommands, [0x25, 0x00, 0x40, 0x20])
        XCTAssertFalse(device.lastOpenedPort?.isClosed ?? true)
        result.port.close()
    }

    func testNewWorkflowAfterHostDisconnectRediscoversChangedRate() throws {
        let device = SimulatedScanner(baudRate: .baud38400, streaming: true)
        let firstProcess = SafeScannerSetupWorkflow(opener: device)
        let first = try firstProcess.detectBaudRate(
            portPath: "/dev/cu.test", address: address, preferredRate: .baud500000
        )
        XCTAssertEqual(first.0, .baud38400)

        // Kein gemeinsam genutzter Workflowzustand: entspricht App-Abbruch
        // bzw. Neustart, waehrend der Scanner unveraendert weiterlaeuft.
        let restartedProcess = SafeScannerSetupWorkflow(opener: device)
        let second = try restartedProcess.detectBaudRate(
            portPath: "/dev/cu.test", address: address, preferredRate: .baud9600
        )
        XCTAssertEqual(second.0, .baud38400)
    }

    /// Opt-in-Realsystemtest fuer genau den Workflow, den die App benutzt.
    /// Ohne expliziten Port bleibt die regulaere Suite hardwarefrei.
    func testRealHardwareRoundTripWhenExplicitlyEnabled() throws {
        guard let path = ProcessInfo.processInfo.environment["SICK_PLS_REAL_PORT"] else {
            throw XCTSkip("Kein realer Scanner fuer diesen Lauf freigegeben.")
        }
        let workflow = SafeScannerSetupWorkflow(
            opener: DarwinActiveControlSerialPortOpener()
        )
        let realSecret = InstallationSecret(text: SetupConsoleModel.defaultPassword)!
        let configuredAddress = ProcessInfo.processInfo.environment["SICK_PLS_REAL_ADDRESS"]
            .flatMap(UInt8.init) ?? address.rawValue
        let realAddress = ConfirmedTargetAddress(rawValue: configuredAddress)!

        let down = try workflow.transition(
            portPath: path,
            targetRate: .baud38400,
            address: realAddress,
            secret: realSecret,
            preferredRate: .baud500000
        )
        XCTAssertEqual(down.baudRate, .baud38400)
        down.port.close()

        let up = try workflow.transition(
            portPath: path,
            targetRate: .baud500000,
            address: realAddress,
            secret: realSecret,
            preferredRate: .baud38400
        )
        XCTAssertEqual(up.baudRate, .baud500000)
        up.port.close()
    }
}

private final class SimulatedScanner: ActiveControlSerialPortOpener {
    var openFailure = false
    var onOpen: (() -> Void)?
    var onWrite: (() -> Void)?
    var crcInvalidOnly = false
    var delayedAcknowledgements = false
    var passiveDelayMilliseconds: Int32 = 0
    var loseFirst500KSend = false
    var ignoreFirstStreamingMode = false
    var confirmationProfiles = 3
    var elapsedMilliseconds: Int32 = 0
    var modeWriteTimes: [Int32] = []
    var identityWritesAt500KAfterSwitch = 0
    var allWrites: [[UInt8]] = []
    var openedRates: [SerialPortBaudRate] = []
    var modeWriteError: Error?
    var pointCount = 90
    var wrongCount = false
    var rejectFullScan = false
    var powerLoss = false
    var losePowerOnFullScan = false
    var onFullScanWrite: (() -> Void)?
    var openPorts = 0
    var maximumOpenPorts = 0
    var baudRate: SerialPortBaudRate
    var streaming: Bool
    var configurationCommands: [UInt8] = []
    weak var lastOpenedPort: SimulatedPort?

    init(baudRate: SerialPortBaudRate, streaming: Bool) {
        self.baudRate = baudRate
        self.streaming = streaming
    }

    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> ActiveControlSerialPort {
        if openFailure { throw SerialPortOpenError.pathNotAllowed(path) }
        onOpen?()
        guard path.hasPrefix("/dev/cu.") else {
            throw SerialPortOpenError.pathNotAllowed(path)
        }
        let port = SimulatedPort(device: self, hostRate: baudRate)
        openedRates.append(baudRate)
        openPorts += 1; maximumOpenPorts = max(maximumOpenPorts, openPorts)
        lastOpenedPort = port
        return port
    }
}

private final class SimulatedPort: ActiveControlSerialPort {
    private unowned let device: SimulatedScanner
    private let hostRate: SerialPortBaudRate
    private var queuedReads: [[UInt8]] = []
    private var emittedPassiveProfile = false
    private var firstWrite = true
    private var pendingDelay: Int32 = 0
    private var remainingPassiveDelay: Int32
    private(set) var isClosed = false

    init(device: SimulatedScanner, hostRate: SerialPortBaudRate) {
        self.device = device
        self.hostRate = hostRate
        remainingPassiveDelay = device.passiveDelayMilliseconds
    }

    func write(_ bytes: [UInt8]) throws {
        device.allWrites.append(bytes)
        device.onWrite?()
        guard !device.crcInvalidOnly else { return }
        guard hostRate == device.baudRate,
              case .success(let frame) = Frame.decodeExact(from: bytes),
              let command = frame.payload.first else { return }
        if command == 0x31, hostRate == .baud500000, device.configurationCommands.contains(0x48) {
            device.identityWritesAt500KAfterSwitch += 1
        }
        if firstWrite {
            firstWrite = false
            if hostRate == .baud500000, device.loseFirst500KSend { return }
        }
        if command == 0x31 {
            queuedReads.append(try! Frame.build(address: 0x80, payload: [0xB1]).encoded())
            return
        }
        guard command == 0x20, frame.payload.count >= 2 else { return }
        let mode = frame.payload[1]
        device.configurationCommands.append(mode)
        switch mode {
        case 0x25:
            device.streaming = false
            queuedReads.append(acknowledgement())
        case 0x00:
            if device.delayedAcknowledgements { pendingDelay = 3_000 }
            queuedReads.append(acknowledgement())
        case 0x40:
            queuedReads.append(acknowledgement())
            device.baudRate = .baud38400
        case 0x42:
            queuedReads.append(acknowledgement())
            device.baudRate = .baud9600
        case 0x48:
            queuedReads.append(acknowledgement())
            device.baudRate = .baud500000
        case 0x20, 0x24:
            if mode == 0x24 {
                device.modeWriteTimes.append(device.elapsedMilliseconds)
                if device.streaming, device.ignoreFirstStreamingMode, device.modeWriteTimes.count == 1 { return }
                if device.delayedAcknowledgements { pendingDelay = 3_000 }
            }
            if mode == 0x24 {
                device.onFullScanWrite?()
                if let error = device.modeWriteError { throw error }
                if device.losePowerOnFullScan { device.powerLoss = true }
            }
            if mode == 0x24 && device.rejectFullScan {
                queuedReads.append(try! Frame.build(address: 0x80, payload: [0xA0, 0x01]).encoded()); return
            }
            device.pointCount = mode == 0x20 || device.wrongCount ? 90 : 361
            device.streaming = true
            // The scanner queues acknowledgements for repeated commands.
            let replies = device.ignoreFirstStreamingMode ? acknowledgement() + acknowledgement() : acknowledgement()
            queuedReads.append(replies + Array(repeating: scanProfile(), count: device.confirmationProfiles).flatMap { $0 })
        default:
            queuedReads.append(try! Frame.build(address: 0x80, payload: [0xA0, 0x01]).encoded())
        }
    }

    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        if device.powerLoss { return .closed }
        if pendingDelay > 0 {
            let elapsed = min(pendingDelay, timeoutMilliseconds)
            device.elapsedMilliseconds += elapsed
            pendingDelay -= elapsed
            if pendingDelay > 0 { return .timeout }
        }
        if !queuedReads.isEmpty { return .bytes(queuedReads.removeFirst()) }
        if hostRate == device.baudRate, device.streaming, !emittedPassiveProfile {
            let elapsed = min(remainingPassiveDelay, timeoutMilliseconds)
            device.elapsedMilliseconds += elapsed
            remainingPassiveDelay -= elapsed
            if remainingPassiveDelay > 0 { return .timeout }
            emittedPassiveProfile = true
            return .bytes(Array(repeating: scanProfile(), count: 3).flatMap { $0 })
        }
        device.elapsedMilliseconds += timeoutMilliseconds
        return .timeout
    }

    func close() { if !isClosed { device.openPorts -= 1 }; isClosed = true }

    private func acknowledgement() -> [UInt8] {
        try! Frame.build(address: 0x80, payload: [0xA0, 0x00]).encoded()
    }

    private func scanProfile() -> [UInt8] {
        var bytes = try! Frame.build(
            address: 0x80,
            payload: [0xB0, UInt8(device.pointCount & 0xFF), UInt8(device.pointCount >> 8)]
                + Array(repeating: [UInt8(100), UInt8(0)], count: device.pointCount).flatMap { $0 } + [0]
        ).encoded()
        if device.crcInvalidOnly { bytes[bytes.count - 1] ^= 0xFF }
        return bytes
    }
}

private struct MarkerPortFailure: Error, CustomStringConvertible {
    let description: String
}
