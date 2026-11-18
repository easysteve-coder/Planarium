import Foundation
import SickPLSActiveControl
import SickPLSCommissioning
import SickPLSCore
import SickPLSMacTransport

struct ScannerSetupWorkflowResult {
    let port: ActiveControlSerialPort
    let baudRate: SerialPortBaudRate
    let evidence: [String]
}

enum ScannerSetupWorkflowError: Error, Equatable {
    case scannerNotFound
    case streamDidNotStop
    case identityNotConfirmed
    case loginNotConfirmed
    case baudSwitchNotConfirmed
    case targetRateNotConfirmed
    case measurementStreamNotConfirmed
    case measurementModeRejected
    case measurementPointCountMismatch
    case aborted
}

/// Synchronous I/O worker for the development console.  It owns a port only
/// while a complete transaction is running; the UI model receives ownership
/// only after the target baud rate and a CRC-valid B0 stream are both proven.
/// This keeps reconnect/retry policy out of SwiftUI and makes app restarts
/// independent of stale in-memory baud-rate state.
final class SafeScannerSetupWorkflow {
    static let supportedRates: [SerialPortBaudRate] = [
        .baud500000, .baud38400, .baud9600,
    ]

    private let opener: ActiveControlSerialPortOpener
    private(set) var observedRate: SerialPortBaudRate?
    private(set) var observedPointCount: Int?
    private var onEvidence: (String) -> Void = { _ in }

    init(opener: ActiveControlSerialPortOpener) {
        self.opener = opener
    }

    func detectBaudRate(
        portPath: String,
        address: ConfirmedTargetAddress,
        preferredRate: SerialPortBaudRate? = nil
    ) throws -> (SerialPortBaudRate, [String]) {
        var evidence: [String] = []
        let candidates = orderedRates(preferredRate)
        for rate in candidates {
            evidence.append("State detection: probe \(rate.rawValue) Baud.")
            let port = try opener.open(atPath: portPath, baudRate: rate)
            defer { port.close() }

            let passive = collect(from: port, timeoutMilliseconds: 700)
            if passive.hasValidFrame {
                observedRate = rate
                evidence.append("\(rate.rawValue) baud detected through CRC-valid telegram.")
                return (rate, evidence)
            }

            for _ in 0..<(rate == .baud500000 ? 2 : 1) {
                try write(CommissioningTelegram.identityRequest(address: address).encoded(), to: port)
                let active = collect(from: port, timeoutMilliseconds: 1_200)
                if active.hasValidFrame {
                    observedRate = rate
                    evidence.append("\(rate.rawValue) baud detected through CRC-valid telegram.")
                    return (rate, evidence)
                }
            }
            evidence.append("\(rate.rawValue) baud not confirmed.")
        }
        throw ScannerSetupWorkflowError.scannerNotFound
    }

    func transition(
        portPath: String,
        targetRate: SerialPortBaudRate,
        address: ConfirmedTargetAddress,
        secret: InstallationSecret,
        preferredRate: SerialPortBaudRate? = nil,
        measurementMode: ScannerMeasurementMode = .mmk,
        isAborted: () -> Bool = { false },
        onModeEvidence: @escaping (String) -> Void = { _ in }
    ) throws -> ScannerSetupWorkflowResult {
        guard !isAborted() else { throw ScannerSetupWorkflowError.aborted }
        onEvidence = onModeEvidence
        observedRate = nil
        observedPointCount = nil
        // Full scan is adopted passively at every candidate rate before any TX.
        if measurementMode == .fullScan {
            for rate in orderedRates(preferredRate) {
                guard !isAborted() else { throw ScannerSetupWorkflowError.aborted }
                let port = try opener.open(atPath: portPath, baudRate: rate)
                onEvidence("Passive probe at \(rate.rawValue) baud.")
                let passiveTimeout: Int32 = rate == .baud9600 ? 4_000 : 1_200
                let passive = collect(from: port, timeoutMilliseconds: passiveTimeout, expectedPointCount: 361)
                if passive.hasValidFrame { observedRate = rate }
                if passive.confirmedProfileCount >= 3 {
                    guard !isAborted() else { port.close(); throw ScannerSetupWorkflowError.aborted }
                    return ScannerSetupWorkflowResult(port: port, baudRate: rate,
                        evidence: ["Full scan 361 adopted without TX at \(rate.rawValue) baud; three CRC-valid profiles."])
                }
                port.close()
            }
        }
        var (currentRate, evidence) = try detectBaudRate(
            portPath: portPath,
            address: address,
            preferredRate: preferredRate
        )
        observedRate = currentRate
        guard !isAborted() else { throw ScannerSetupWorkflowError.aborted }

        if currentRate != targetRate {
            let sourcePort = try opener.open(atPath: portPath, baudRate: currentRate)
            do {
                try stopContinuousStreamIfNeeded(
                    port: sourcePort, address: address, evidence: &evidence
                )
                guard try confirmIdentity(port: sourcePort, address: address, attempts: 2) else {
                    throw ScannerSetupWorkflowError.identityNotConfirmed
                }
                evidence.append("Identity confirmed before configuration.")
                guard !isAborted() else { throw ScannerSetupWorkflowError.aborted }

                let login = CommissioningTelegram.login(
                    secret: secret, recipe: .r26, address: address
                ).encoded()
                guard try sendModeAndRequireAcknowledgement(
                    login, port: sourcePort, attempts: 3
                ) else {
                    throw ScannerSetupWorkflowError.loginNotConfirmed
                }
                evidence.append("Login confirmed.")
                guard !isAborted() else { throw ScannerSetupWorkflowError.aborted }

                let baudFrame = try! Frame.build(
                    address: address.rawValue,
                    payload: [0x20, baudCode(for: targetRate)]
                ).encoded()
                guard try sendModeAndRequireAcknowledgement(
                    baudFrame, port: sourcePort, attempts: 1
                ) else {
                    throw ScannerSetupWorkflowError.baudSwitchNotConfirmed
                }
                evidence.append("Baud switch to \(targetRate.rawValue) acknowledged.")
            } catch {
                sourcePort.close()
                throw error
            }
            sourcePort.close()
            currentRate = targetRate
            observedPointCount = nil
        } else {
            evidence.append("Target baud rate already active; no baud command sent.")
        }

        guard !isAborted() else { throw ScannerSetupWorkflowError.aborted }
        let targetPort = try opener.open(atPath: portPath, baudRate: currentRate)
        do {
            if currentRate == .baud500000 {
                usleep(2_500)
            }
            let passive = collect(from: targetPort, timeoutMilliseconds: 800)
            if passive.hasValidFrame { observedRate = currentRate }
            if !passive.hasProfile {
                guard try confirmIdentity(port: targetPort, address: address, attempts: 2) else {
                    throw ScannerSetupWorkflowError.targetRateNotConfirmed
                }
            }
            observedRate = currentRate
            evidence.append("Target baud rate \(currentRate.rawValue) confirmed.")
            if measurementMode != .fullScan {
                try stopContinuousStreamIfNeeded(port: targetPort, address: address, evidence: &evidence)
            }

            let modeCommand = measurementMode.telegram(address: address).encoded()
            // Repeat after reopening and while a different stream is running.
            // ACK alone never proves the requested point count.
            var streamConfirmed = false
            for attempt in 1...5 {
                guard !isAborted() else { throw ScannerSetupWorkflowError.aborted }
                onModeEvidence("TX measurement \(measurementMode.title), address \(address.rawValue), attempt \(attempt).")
                try write(modeCommand, to: targetPort)
                let response = collect(from: targetPort, timeoutMilliseconds: 4_000,
                    expectedPointCount: measurementMode.pointCount)
                onModeEvidence("RX \(response.summary); B0 points \(response.pointCounts.sorted()).")
                evidence.append("\(measurementMode.title) attempt \(attempt): \(response.summary).")
                guard !isAborted() else { throw ScannerSetupWorkflowError.aborted }
                if response.isNegativeAcknowledgement {
                    throw ScannerSetupWorkflowError.measurementModeRejected
                }
                if response.confirmedProfileCount >= 3 {
                    streamConfirmed = true
                    break
                }
                if measurementMode != .fullScan, response.hasProfile {
                    guard response.pointCounts.allSatisfy({ measurementMode.accepts(pointCount: $0) }) else {
                        throw ScannerSetupWorkflowError.measurementPointCountMismatch
                    }
                    streamConfirmed = true
                    break
                }
                if measurementMode != .fullScan, response.isPositiveAcknowledgement {
                    let stream = collect(from: targetPort, timeoutMilliseconds: 3_000)
                    onModeEvidence("RX stream \(stream.summary); B0 points \(stream.pointCounts.sorted()).")
                    guard !isAborted() else { throw ScannerSetupWorkflowError.aborted }
                    if stream.hasProfile {
                        guard stream.pointCounts.allSatisfy({ measurementMode.accepts(pointCount: $0) }) else {
                            throw ScannerSetupWorkflowError.measurementPointCountMismatch
                        }
                        streamConfirmed = true
                        break
                    }
                }
            }
            guard streamConfirmed else {
                if observedPointCount != nil { throw ScannerSetupWorkflowError.measurementPointCountMismatch }
                throw ScannerSetupWorkflowError.measurementStreamNotConfirmed
            }
            evidence.append("\(measurementMode.title) confirmed through new CRC-valid B0 scan stream.")
            guard !isAborted() else { throw ScannerSetupWorkflowError.aborted }
            return ScannerSetupWorkflowResult(
                port: targetPort, baudRate: currentRate, evidence: evidence
            )
        } catch {
            targetPort.close()
            throw error
        }
    }

    /// Testet, ob ein Baudwechsel OHNE vorherigen Login angenommen wird.
    /// Stoppt zuvor nur den Dauerstrom (Moduswechsel, kein Login) und sendet
    /// dann `20 <baudcode>` ohne Anmeldung. Reine Diagnose der Frage
    /// „braucht der Baudwechsel das Passwort?".
    func probeBaudSwitchWithoutLogin(
        portPath: String,
        targetRate: SerialPortBaudRate,
        address: ConfirmedTargetAddress
    ) throws -> (accepted: Bool, negative: Bool, verifiedRate: SerialPortBaudRate?, evidence: [String]) {
        var (currentRate, evidence) = try detectBaudRate(
            portPath: portPath, address: address, preferredRate: nil
        )
        if currentRate == targetRate {
            evidence.append("Target rate is already active; select another target rate for the test.")
            return (false, false, currentRate, evidence)
        }
        let port = try opener.open(atPath: portPath, baudRate: currentRate)
        var accepted = false
        var negative = false
        do {
            try stopContinuousStreamIfNeeded(port: port, address: address, evidence: &evidence)
            evidence.append("NO login sent -- sending baud command directly.")
            let baudFrame = try! Frame.build(
                address: address.rawValue, payload: [0x20, baudCode(for: targetRate)]
            ).encoded()
            try write(baudFrame, to: port)
            let response = collect(from: port, timeoutMilliseconds: 2_000)
            evidence.append("Baud command without login: \(response.summary).")
            accepted = response.isPositiveAcknowledgement
            negative = response.isNegativeAcknowledgement
        } catch {
            port.close(); throw error
        }
        port.close()
        if accepted {
            let verifyPort = try opener.open(atPath: portPath, baudRate: targetRate)
            let passive = collect(from: verifyPort, timeoutMilliseconds: 800)
            var verified: SerialPortBaudRate? = nil
            if passive.hasProfile || confirmIdentitySafe(port: verifyPort, address: address) {
                verified = targetRate
                evidence.append("Rate \(targetRate.rawValue) verified effective after ACK.")
            } else {
                evidence.append("ACK received, but rate \(targetRate.rawValue) not confirmed.")
            }
            verifyPort.close()
            return (true, false, verified, evidence)
        }
        return (accepted, negative, nil, evidence)
    }

    private func confirmIdentitySafe(port: ActiveControlSerialPort, address: ConfirmedTargetAddress) -> Bool {
        return (try? confirmIdentity(port: port, address: address, attempts: 2)) ?? false
    }

    /// Sendet einen Messmodus (`20 <byte>`) OHNE Login und meldet, ob er
    /// quittiert wurde und ob danach ein B0-Strom folgt. Stoppt zuvor einen
    /// laufenden Strom, damit die Antwort lesbar ist.
    func sendMeasurementModeWithoutLogin(
        portPath: String,
        modeByte: UInt8,
        address: ConfirmedTargetAddress
    ) throws -> (accepted: Bool, negative: Bool, profileFollowed: Bool, evidence: [String]) {
        var (currentRate, evidence) = try detectBaudRate(
            portPath: portPath, address: address, preferredRate: nil
        )
        let port = try opener.open(atPath: portPath, baudRate: currentRate)
        do {
            try? stopContinuousStreamIfNeeded(port: port, address: address, evidence: &evidence)
            let frame = try! Frame.build(
                address: address.rawValue, payload: [0x20, modeByte]
            ).encoded()
            try write(frame, to: port)
            let response = collect(from: port, timeoutMilliseconds: 2_500)
            evidence.append("20 \(String(format: "%02X", modeByte)) without login: \(response.summary).")
            let stream = collect(from: port, timeoutMilliseconds: 2_000)
            let profile = response.hasProfile || stream.hasProfile
            evidence.append(profile ? "B0 stream present afterward." : "No B0 stream afterward.")
            port.close()
            return (response.isPositiveAcknowledgement, response.isNegativeAcknowledgement, profile, evidence)
        } catch {
            port.close(); throw error
        }
    }

    private func stopContinuousStreamIfNeeded(
        port: ActiveControlSerialPort,
        address: ConfirmedTargetAddress,
        evidence: inout [String]
    ) throws {
        let initial = collect(from: port, timeoutMilliseconds: 500)
        guard initial.hasProfile else { return }
        let stop = try! Frame.build(
            address: address.rawValue, payload: [0x20, 0x25]
        ).encoded()
        for attempt in 1...3 {
            try write(stop, to: port)
            let response = collect(from: port, timeoutMilliseconds: 1_500)
            evidence.append("Stream stop attempt \(attempt): \(response.summary).")
            if response.isNegativeAcknowledgement {
                throw ScannerSetupWorkflowError.streamDidNotStop
            }
            let quiet = collect(from: port, timeoutMilliseconds: 750)
            if !quiet.hasProfile {
                evidence.append("Continuous B0 stream stopped.")
                return
            }
        }
        throw ScannerSetupWorkflowError.streamDidNotStop
    }

    private func confirmIdentity(
        port: ActiveControlSerialPort,
        address: ConfirmedTargetAddress,
        attempts: Int
    ) throws -> Bool {
        let frame = CommissioningTelegram.identityRequest(address: address).encoded()
        for _ in 0..<attempts {
            try write(frame, to: port)
            if collect(from: port, timeoutMilliseconds: 1_200).hasIdentity { return true }
        }
        return false
    }

    private func sendModeAndRequireAcknowledgement(
        _ bytes: [UInt8],
        port: ActiveControlSerialPort,
        attempts: Int
    ) throws -> Bool {
        for _ in 0..<attempts {
            try write(bytes, to: port)
            let evidence = collect(from: port, timeoutMilliseconds: 4_000)
            if evidence.isPositiveAcknowledgement { return true }
            if evidence.isNegativeAcknowledgement { return false }
        }
        return false
    }

    private func orderedRates(_ preferred: SerialPortBaudRate?) -> [SerialPortBaudRate] {
        guard let preferred else { return Self.supportedRates }
        return [preferred] + Self.supportedRates.filter { $0 != preferred }
    }

    private func write(_ bytes: [UInt8], to port: ActiveControlSerialPort) throws {
        onEvidence("TX bytes " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
        try port.write(bytes)
    }

    private func baudCode(for rate: SerialPortBaudRate) -> UInt8 {
        switch rate {
        case .baud9600: return 0x42
        case .baud38400: return 0x40
        case .baud500000: return 0x48
        }
    }

    private struct ReadEvidence {
        var hasValidFrame = false
        var hasProfile = false
        var confirmedProfileCount = 0
        var pointCounts: Set<Int> = []
        var hasIdentity = false
        var isPositiveAcknowledgement = false
        var isNegativeAcknowledgement = false

        var summary: String {
            var values: [String] = []
            if hasProfile { values.append("B0") }
            if hasIdentity { values.append("B1") }
            if isPositiveAcknowledgement { values.append("A0/00") }
            if isNegativeAcknowledgement { values.append("A0/NAK") }
            return values.isEmpty ? "no usable reply" : values.joined(separator: ", ")
        }
    }

    private func collect(
        from port: ActiveControlSerialPort,
        timeoutMilliseconds: Int32,
        expectedPointCount: Int? = nil
    ) -> ReadEvidence {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutMilliseconds) * 1_000_000
        var parser = StreamParser()
        var evidence = ReadEvidence()
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            let remainingNanos = deadline - now
            let remainingMillis = max(1, min(Int32.max, Int32(remainingNanos / 1_000_000)))
            switch port.read(timeoutMilliseconds: remainingMillis) {
            case .bytes(let bytes):
                onEvidence("RX bytes " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                for frame in parser.feed(bytes) {
                    evidence.hasValidFrame = true
                    switch frame.payload.first {
                    case 0xB0:
                        if case .success(let profile) = B0ScanProfile.decode(from: frame.payload) {
                            evidence.hasProfile = true
                            evidence.pointCounts.insert(profile.measurements.count)
                            observedPointCount = profile.measurements.count
                            if profile.measurements.count == expectedPointCount {
                                evidence.confirmedProfileCount += 1
                            } else {
                                evidence.confirmedProfileCount = 0
                            }
                        }
                    case 0xB1:
                        evidence.hasIdentity = true
                    case 0xA0:
                        if frame.payload.dropFirst().first == 0x00 {
                            evidence.isPositiveAcknowledgement = true
                        } else {
                            evidence.isNegativeAcknowledgement = true
                        }
                    default:
                        break
                    }
                }
                if evidence.confirmedProfileCount >= 3 { return evidence }
            case .timeout, .closed:
                return evidence
            }
        }
        return evidence
    }
}
