import Combine
import Foundation
import SickPLSActiveControl
import SickPLSCommissioning
import SickPLSCore
import SickPLSMacTransport

public struct SetupTranscriptEntry: Identifiable, Equatable {
    public enum Direction: String {
        case system = "SYS"
        case transmit = "TX "
        case receive = "RX "
        case frame = "FRM"
    }

    public let id: Int
    public let elapsedMilliseconds: UInt64
    public let direction: Direction
    public let message: String

    public var line: String {
        String(format: "+%08llu ms  %@  %@", elapsedMilliseconds, direction.rawValue, message)
    }
}

public enum SetupMeasurementMode: String, CaseIterable, Identifiable {
    case minimumContinuous
    case requestOnly
    case centered90Degrees
    case centered120Degrees
    case customSubrange

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .minimumContinuous: return "MMK – Continuous minimum (20 20)"
        case .requestOnly: return "Idle / Measurements on request (20 25)"
        case .centered90Degrees: return "Centered 90° – experimental (20 27)"
        case .centered120Degrees: return "Centered 120° – experimental (20 27)"
        case .customSubrange: return "Subrange by index – experimental (20 27)"
        }
    }

    public var fixedRange: ClosedRange<UInt16>? {
        switch self {
        case .centered90Degrees: return 91...271
        case .centered120Degrees: return 61...301
        default: return nil
        }
    }

    public var isExperimentalSubrange: Bool {
        fixedRange != nil || self == .customSubrange
    }
}

/// Ein vom sicheren Einrichtungsablauf real belegter Empfangsendpunkt.
/// Er wird erst nach erfolgreicher Baud-Verifikation und gültigem
/// B0-Messstrom veröffentlicht.
public struct VerifiedScannerConnection: Equatable, Sendable {
    public let portPath: String
    public let baudRate: SerialPortBaudRate

    public init(portPath: String, baudRate: SerialPortBaudRate) {
        self.portPath = portPath
        self.baudRate = baudRate
    }
}

/// UI-Zustand wird ausschließlich auf der Main Queue publiziert; Port,
/// Parser und Generation werden ausschließlich auf `ioQueue` benutzt.
/// Die explizite Grenze macht diese bestehende Zweiteilung für die
/// Swift-6-Sendability-Prüfung sichtbar.
public final class SetupConsoleModel: ObservableObject, @unchecked Sendable {
    /// Standardkennwort – Owner-Ausnahme: dieser Wert ist freigegeben
    /// und darf an dieser einen Stelle im Setup-Target als Literal stehen.
    public static let defaultPassword = "SICK_PLS"

    @Published public private(set) var ports: [String] = []
    @Published public var selectedPort = ""
    @Published public var selectedBaudRate: SerialPortBaudRate = .baud9600
    @Published public var baudSwitchTarget: SerialPortBaudRate = .baud500000
    @Published public var selectedMeasurementMode: SetupMeasurementMode = .minimumContinuous
    @Published public var subrangeStartText = "91"
    @Published public var subrangeStopText = "271"
    @Published public var targetAddressText = "00"
    @Published public var password = defaultPassword
    @Published public var manualTelegram = ""
    @Published public private(set) var isOpen = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var status = "Disconnected."
    public private(set) var scannerUnreachable = false
    public private(set) var canTryAnotherPort = false
    @Published public private(set) var transcript: [SetupTranscriptEntry] = []
    @Published public private(set) var lastProfile: B0ScanProfile?
    @Published public private(set) var validProfileCount = 0
    @Published public private(set) var lastProfileElapsedMilliseconds: UInt64?
    @Published public private(set) var profileRateHz: Double?
    @Published public private(set) var lastRequestedOperatingMode: String?
    @Published public private(set) var verifiedScannerConnection: VerifiedScannerConnection?
    /// Wird erst gesetzt, nachdem der Setup-Port tatsächlich geschlossen ist;
    /// die App übernimmt den Endpunkt daraufhin automatisch in ihren RX-Pfad.
    @Published public private(set) var pendingMonitorHandoff: VerifiedScannerConnection?

    private let opener: ActiveControlSerialPortOpener
    private var lastObservedBaudRate: SerialPortBaudRate?
    private let ioQueue = DispatchQueue(label: "de.sick.pls.setup.serial")
    private var port: ActiveControlSerialPort?
    private var parser = StreamParser()
    private var connectionGeneration = 0
    private var nextEntryID = 0
    private var recentProfileTimesMilliseconds: [UInt64] = []
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private let safeTransitionAbort = CommissioningAbortToken()

    public func abortSafeTransition() { safeTransitionAbort.requestAbort() }

    public init(opener: ActiveControlSerialPortOpener = DarwinActiveControlSerialPortOpener()) {
        self.opener = opener
    }

    deinit {
        port?.close()
    }

    public func refreshPorts() {
        ports = SerialPortEnumeration.availablePortPaths()
        append(.system, "Port list refreshed; no connection opened.")
    }

    public func openSelectedPort() {
        guard !selectedPort.isEmpty else {
            status = "Select a port first."
            return
        }
        guard selectedPort.hasPrefix("/dev/cu.") else {
            status = "Only /dev/cu.* is allowed."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        status = "Detecting scanner state and preparing the app connection…"
        let path = selectedPort
        let rate = selectedBaudRate
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.port?.close()
            do {
                let opened = try self.opener.open(atPath: path, baudRate: rate)
                self.port = opened
                self.parser = StreamParser()
                self.connectionGeneration += 1
                let generation = self.connectionGeneration
                DispatchQueue.main.async {
                    self.resetMeasurementPresentation()
                    self.isOpen = true
                    self.isBusy = false
                    self.status = "Connected: \(rate.rawValue) Baud, 8E1."
                    self.append(.system, "Port opened: \(path), \(rate.rawValue) Baud, 8E1.")
                }
                self.readNext(generation: generation)
            } catch {
                self.port = nil
                DispatchQueue.main.async {
                    self.isOpen = false
                    self.isBusy = false
                    self.status = "Could not open port."
                    self.append(.system, "Port open failed.")
                }
            }
        }
    }

    public func closePort() {
        guard !isBusy else { return }
        isBusy = true
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.connectionGeneration += 1
            self.port?.close()
            self.port = nil
            let finalFrames = self.parser.finish()
            DispatchQueue.main.async {
                self.appendDecoded(finalFrames)
                self.isOpen = false
                self.isBusy = false
                self.status = "Disconnected."
                self.append(.system, "Port closed.")
            }
        }
    }

    public func consumeMonitorHandoff() {
        pendingMonitorHandoff = nil
    }

    public func reconnectAtSelectedBaud() {
        let targetRate = baudSwitchTarget
        selectedBaudRate = targetRate
        guard !isBusy else { return }
        isBusy = true
        let path = selectedPort
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.connectionGeneration += 1
            self.port?.close()
            self.port = nil
            do {
                let opened = try self.opener.open(atPath: path, baudRate: targetRate)
                self.port = opened
                self.parser = StreamParser()
                self.connectionGeneration += 1
                let generation = self.connectionGeneration
                DispatchQueue.main.async {
                    self.resetMeasurementPresentation()
                    self.isOpen = true
                    self.isBusy = false
                    self.status = "Connected: \(targetRate.rawValue) Baud, 8E1."
                    self.append(.system, "Port at \(targetRate.rawValue) baud reopened.")
                }
                self.readNext(generation: generation)
            } catch {
                DispatchQueue.main.async {
                    self.isOpen = false
                    self.isBusy = false
                    self.status = "Reconnection at \(targetRate.rawValue) baud failed."
                    self.append(.system, "Reconnection at \(targetRate.rawValue) baud failed.")
                }
            }
        }
    }

    public func reconnectAt38400() {
        baudSwitchTarget = .baud38400
        reconnectAtSelectedBaud()
    }

    /// Erkennt den wirklichen Scannerzustand neu. Gespeicherte/UI-seitig
    /// gewählte Baudwerte gelten dabei nur als bevorzugter erster Kandidat,
    /// niemals als Beleg. Der Port bleibt nach der Diagnose geschlossen.
    public func detectScannerState() {
        guard let address = selectedTargetAddress(), !selectedPort.isEmpty else {
            status = "Specify port and target address."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        let path = selectedPort
        let preferred = selectedBaudRate
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.connectionGeneration += 1
            self.port?.close()
            self.port = nil
            let workflow = SafeScannerSetupWorkflow(opener: self.opener)
            do {
                let (rate, evidence) = try workflow.detectBaudRate(
                    portPath: path, address: address, preferredRate: preferred
                )
                DispatchQueue.main.async {
                    self.isOpen = false
                    self.isBusy = false
                    self.selectedBaudRate = rate
                    self.lastObservedBaudRate = rate
                    evidence.forEach { self.append(.system, $0) }
                    self.status = "Scanner at \(rate.rawValue) baud detected; port closed."
                }
            } catch {
                DispatchQueue.main.async {
                    self.isOpen = false
                    self.isBusy = false
                    self.status = "Scanner not detected at 500000, 38400 or 9600 baud."
                    self.append(.system, "State detection failed; no rate is assumed.")
                }
            }
        }
    }

    /// Führt Erkennung, Konfiguration, Host-Neuöffnung und Betriebsart-Beleg als
    /// eine Transaktion aus. Nach dem CRC-gültigen B0-Beleg wird der
    /// TX-fähige Setup-Port wirklich geschlossen und der Endpunkt automatisch
    /// an den normalen RX-Messpfad der App übergeben.
    @MainActor public func performSafeBaudTransition(
        measurementMode: ScannerMeasurementMode = .fullScan,
        completion: (@MainActor @Sendable (VerifiedScannerConnection?, ScannerMeasurementMode) -> Void)? = nil
    ) {
        canTryAnotherPort = false
        guard let address = selectedTargetAddress(), !selectedPort.isEmpty else {
            status = "Specify port and target address."
            completion?(nil, measurementMode)
            return
        }
        guard InstallationSecret(text: password) != nil else {
            status = "Scanner password must be exactly 8 bytes."
            completion?(nil, measurementMode)
            return
        }
        guard !isBusy else { completion?(nil, measurementMode); return }
        isBusy = true
        scannerUnreachable = false
        let edge = safeTransitionAbort.beginRunIfNeeded()
        let path = selectedPort
        let target = baudSwitchTarget
        let preferred = lastObservedBaudRate
        let secretText = password
        ioQueue.async { [weak self] in
            guard let self else { return }
            // Das nicht beobachtbare Geheimnis entsteht und endet auf der
            // einen I/O-Queue; nur der sendbare Bedienertext kreuzt die
            // Queue-Grenze.
            guard let secret = InstallationSecret(text: secretText) else { return }
            self.connectionGeneration += 1
            self.port?.close()
            self.port = nil
            let workflow = SafeScannerSetupWorkflow(opener: self.opener)
            do {
                let result = try workflow.transition(
                    portPath: path,
                    targetRate: target,
                    address: address,
                    secret: secret,
                    preferredRate: preferred,
                    measurementMode: measurementMode,
                    isAborted: { self.safeTransitionAbort.consumeIfRequested(for: edge) },
                    onModeEvidence: { text in DispatchQueue.main.async { self.append(.system, text) } }
                )
                result.port.close()
                self.port = nil
                self.parser = StreamParser()
                self.connectionGeneration += 1
                let verifiedRate = result.baudRate
                let evidence = result.evidence
                let verified = VerifiedScannerConnection(portPath: path, baudRate: verifiedRate)
                self.safeTransitionAbort.endRun(edge)
                DispatchQueue.main.async {
                    self.resetMeasurementPresentation()
                    self.selectedBaudRate = verifiedRate
                    self.lastObservedBaudRate = verifiedRate
                    self.verifiedScannerConnection = verified
                    self.isOpen = false
                    self.isBusy = false
                    evidence.forEach { self.append(.system, $0) }
                    self.status = "Scanner ready: \(verifiedRate.rawValue) baud, \(measurementMode.title) verified; app connection starts."
                    self.append(.system, "Setup port closed; verified connection starts in the scan input path.")
                    if let completion { completion(verified, measurementMode) }
                    else { self.pendingMonitorHandoff = verified }
                }
            } catch {
                let wasAborted = error as? ScannerSetupWorkflowError == .aborted
                    || self.safeTransitionAbort.consumeIfRequested(for: edge)
                let failureText = Self.safeTransitionFailure(wasAborted ? ScannerSetupWorkflowError.aborted : error)
                let observedRate = workflow.observedRate
                let observedPoints = workflow.observedPointCount
                let unreachable = !wasAborted && error as? ScannerSetupWorkflowError == .scannerNotFound && observedRate == nil
                let canTryAnother = observedRate == nil && !wasAborted
                self.safeTransitionAbort.endRun(edge)
                DispatchQueue.main.async {
                    self.isOpen = false
                    self.isBusy = false
                    self.verifiedScannerConnection = nil
                    self.pendingMonitorHandoff = nil
                    self.scannerUnreachable = unreachable
                    self.canTryAnotherPort = canTryAnother
                    if let observedRate {
                        self.selectedBaudRate = observedRate
                        self.lastObservedBaudRate = observedRate
                        let points = observedPoints.map { "\($0) points" } ?? "point count unknown"
                        self.status = "\(failureText) Scanner observed: \(points) at \(observedRate.rawValue) baud. Retry Connect."
                    } else if unreachable {
                        self.status = "Scanner unreachable: no CRC-valid telegram at 500000, 38400 or 9600 baud. Check the scanner connection."
                    } else {
                        self.status = "\(failureText) Retry Connect."
                    }
                    self.append(.system, "Setup port closed; no RX handoff without three matching profiles.")
                    completion?(nil, measurementMode)
                }
            }
        }
    }

    public func sendIdentity() {
        guard let address = selectedTargetAddress() else { return }
        send(CommissioningTelegram.identityRequest(address: address).encoded(), label: "Identity 31 @\(hexAddress(address))")
    }

    private static func safeTransitionFailure(_ error: Error) -> String {
        guard let failure = error as? ScannerSetupWorkflowError else { return "Measurement change failed while accessing the port." }
        switch failure {
        case .aborted: return "Measurement change aborted."
        case .measurementModeRejected: return "The scanner rejected the measurement mode."
        case .measurementPointCountMismatch: return "The new measurement stream has the wrong point count."
        case .measurementStreamNotConfirmed: return "No new measurement stream arrived."
        case .scannerNotFound: return "Scanner not found."
        case .streamDidNotStop: return "The measurement stream did not stop."
        case .identityNotConfirmed: return "Scanner identity unconfirmed."
        case .loginNotConfirmed: return "Scanner login unconfirmed."
        case .baudSwitchNotConfirmed: return "Baud switch unconfirmed."
        case .targetRateNotConfirmed: return "Target baud rate unconfirmed."
        }
    }

    public func sendVerificationIdentity() {
        // Verifikationsschritt nach Baudwechsel: Adresse fest auf 0x00 (Universaladresse).
        // Im manuellen Werkzeug unabhängig vom Produktrezept.
        let address = ConfirmedTargetAddress(rawValue: 0x00)!
        send(CommissioningTelegram.identityRequest(address: address).encoded(), label: "Verification 31 @\(hexAddress(address))")
    }

    public func sendSettingsMode() {
        guard let secret = InstallationSecret(text: password) else {
            status = "Scanner password must be exactly 8 bytes."
            append(.system, "Setup mode not sent: password is not exactly 8 bytes.")
            return
        }
        // Adresse für Einstellungsmodus ist fest auf 0x00 (Universaladresse).
        // Im manuellen Werkzeug unabhängig vom Produktrezept.
        let address = ConfirmedTargetAddress(rawValue: 0x00)!
        send(
            CommissioningTelegram.settingsMode(secret: secret, recipe: .r26, address: address).encoded(),
            label: "PLSIBS authorization / Setup mode (20 30 @\(hexAddress(address))); Password bytes masked",
            redactPassword: true
        )
    }

    public func sendLogin() {
        guard let address = selectedTargetAddress() else { return }
        guard let secret = InstallationSecret(text: password) else {
            status = "Scanner password must be exactly 8 bytes."
            append(.system, "Login not sent: password is not exactly 8 bytes.")
            return
        }
        send(
            CommissioningTelegram.login(secret: secret, recipe: .r26, address: address).encoded(),
            label: "Login 20 00 @\(hexAddress(address)); Password bytes masked",
            redactPassword: true
        )
    }

    public func sendBaudSwitch() {
        guard let address = selectedTargetAddress() else { return }
        let code: UInt8
        switch baudSwitchTarget {
        case .baud9600: code = 0x42
        case .baud38400: code = 0x40
        case .baud500000: code = 0x48
        }
        let frame = try! Frame.build(address: address.rawValue, payload: [0x20, code])
        send(
            frame.encoded(),
            label: "Baud switch 20 \(String(format: "%02X", code)) to \(baudSwitchTarget.rawValue) @\(hexAddress(address))"
        )
    }

    public func sendMeasurementMode() {
        guard let address = selectedTargetAddress() else { return }
        let payload: [UInt8]
        let label: String
        switch selectedMeasurementMode {
        case .minimumContinuous:
            payload = [0x20, 0x20]
            label = "Continuous MMK 20 20"
        case .requestOnly:
            payload = [0x20, 0x25]
            label = "Measurements on request / Stream stop 20 25"
        case .centered90Degrees, .centered120Degrees, .customSubrange:
            guard let range = selectedSubrange() else { return }
            payload = [
                0x20, 0x27,
                UInt8(range.lowerBound & 0xFF), UInt8(range.lowerBound >> 8),
                UInt8(range.upperBound & 0xFF), UInt8(range.upperBound >> 8),
            ]
            label = "Subrange 20 27, indices \(range.lowerBound)…\(range.upperBound) (experimental)"
        }
        let frame = try! Frame.build(address: address.rawValue, payload: payload)
        lastRequestedOperatingMode = selectedMeasurementMode.title
        send(frame.encoded(), label: "\(label) @\(hexAddress(address))")
    }

    public var liveConnectionSummary: String {
        guard isOpen else { return "Port closed" }
        guard let profile = lastProfile else {
            return "Port open at \(selectedBaudRate.rawValue) baud · no valid scanner profile yet"
        }
        let rate = profileRateHz.map { String(format: "%.2f Hz", $0) } ?? "measuring"
        return "Connected at \(selectedBaudRate.rawValue) baud · B0 scan stream · \(profile.measurements.count) points · \(rate)"
    }

    private func selectedSubrange() -> ClosedRange<UInt16>? {
        if let fixed = selectedMeasurementMode.fixedRange { return fixed }
        guard let start = UInt16(subrangeStartText), let stop = UInt16(subrangeStopText),
              (1...361).contains(Int(start)), (1...361).contains(Int(stop)), start <= stop else {
            status = "Invalid subrange: start and end must be ascending in 1…361."
            append(.system, "Subrange not sent: invalid indices.")
            return nil
        }
        return start...stop
    }

    public func sendManualTelegram() {
        switch HexTelegramInput.parse(manualTelegram) {
        case .success(let bytes):
            send(
                bytes,
                label: "manual CRC-valid telegram @\(String(format: "%02X", bytes[1]))",
                redactPassword: Self.containsPasswordField(bytes)
            )
        case .failure(let error):
            status = Self.describe(error)
        }
    }

    public func clearTranscript() {
        transcript.removeAll()
    }

    public var exportText: String {
        (["SICK PLS Setup – Live transcript", "Guided password bytes are masked.", ""]
            + transcript.map(\.line)).joined(separator: "\n") + "\n"
    }

    private func send(_ bytes: [UInt8], label: String, redactPassword: Bool = false) {
        guard isOpen else {
            status = "Open the port first."
            append(.system, "Not sent: \(label); port is closed.")
            return
        }
        guard !isBusy else {
            status = "Not sent: the previous operation is still running."
            append(.system, "Not sent: \(label); previous operation is still running.")
            return
        }
        isBusy = true
        ioQueue.async { [weak self] in
            guard let self, let port = self.port else { return }
            do {
                try port.write(bytes)
                let shown = redactPassword ? Self.redactedPasswordFrame(bytes) : Self.hex(bytes)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = "Sent: \(label)."
                    self.append(.transmit, "\(label) | \(shown)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = "Send failed."
                    self.append(.system, "Send failed: \(label).")
                }
            }
        }
    }

    private func readNext(generation: Int) {
        guard generation == connectionGeneration, let port else { return }
        let outcome = port.read(timeoutMilliseconds: 100)
        switch outcome {
        case .bytes(let bytes) where !bytes.isEmpty:
            let frames = parser.feed(bytes)
            DispatchQueue.main.async { [weak self] in
                self?.append(.receive, Self.hex(bytes))
                self?.appendDecoded(frames)
            }
        case .bytes, .timeout:
            break
        case .closed:
            let frames = parser.finish()
            self.port = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.appendDecoded(frames)
                self.isOpen = false
                self.isBusy = false
                self.status = "The serial connection was closed."
                self.append(.system, "Serial connection ended.")
            }
            return
        }
        ioQueue.async { [weak self] in self?.readNext(generation: generation) }
    }

    private func appendDecoded(_ frames: [Frame]) {
        for frame in frames {
            let command = frame.payload.first.map { String(format: "%02X", $0) } ?? "--"
            append(
                .frame,
                "CRC-valid: source \(String(format: "%02X", frame.address)), "
                    + "Command \(command), Payload \(frame.payload.count) Byte"
            )
            if case .success(let profile) = B0ScanProfile.decode(from: frame.payload) {
                lastProfile = profile
                validProfileCount += 1
                let now = elapsedMilliseconds
                lastProfileElapsedMilliseconds = now
                recentProfileTimesMilliseconds.append(now)
                if recentProfileTimesMilliseconds.count > 100 {
                    recentProfileTimesMilliseconds.removeFirst(recentProfileTimesMilliseconds.count - 100)
                }
                if let first = recentProfileTimesMilliseconds.first,
                   let last = recentProfileTimesMilliseconds.last,
                   last > first {
                    profileRateHz = Double(recentProfileTimesMilliseconds.count - 1) * 1_000.0
                        / Double(last - first)
                }
            }
        }
    }

    private func selectedTargetAddress() -> ConfirmedTargetAddress? {
        guard let address = TargetAddressInput.parse(targetAddressText) else {
            status = "Invalid target address. Enter hex 00–FF; 81 is the reply address."
            append(.system, "Not sent: invalid target address.")
            return nil
        }
        return address
    }

    private func resetMeasurementPresentation() {
        lastProfile = nil
        validProfileCount = 0
        lastProfileElapsedMilliseconds = nil
        profileRateHz = nil
        recentProfileTimesMilliseconds.removeAll(keepingCapacity: true)
    }

    private func hexAddress(_ address: ConfirmedTargetAddress) -> String {
        String(format: "%02X", address.rawValue)
    }

    private func append(_ direction: SetupTranscriptEntry.Direction, _ message: String) {
        let elapsed = elapsedMilliseconds
        transcript.append(
            SetupTranscriptEntry(
                id: nextEntryID, elapsedMilliseconds: elapsed,
                direction: direction, message: message
            )
        )
        nextEntryID += 1
    }

    private var elapsedMilliseconds: UInt64 {
        (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func redactedPasswordFrame(_ bytes: [UInt8]) -> String {
        // Header 0...3, Kommando/Modus 4...5, Kennwort 6...13, CRC 14...15.
        guard bytes.count >= 16 else { return "<password telegram masked>" }
        return hex(Array(bytes.prefix(6))) + " ** ** ** ** ** ** ** ** " + hex(Array(bytes.suffix(2)))
    }

    private static func containsPasswordField(_ bytes: [UInt8]) -> Bool {
        guard case .success(let frame) = Frame.decodeExact(from: bytes), frame.payload.count == 10 else {
            return false
        }
        return frame.payload[0] == CommissioningRecipe.r26.configurationCommandByte
            && (frame.payload[1] == CommissioningRecipe.r26.settingsModeByte
                || frame.payload[1] == CommissioningRecipe.r26.loginModeByte)
    }

    private static func describe(_ error: HexTelegramInputError) -> String {
        switch error {
        case .empty: return "Enter a complete telegram as hex bytes."
        case .invalidToken(let token): return "Invalid hex byte: \(token)."
        case .notACompleteFrame: return "This is not a complete CRC-valid SICK telegram."
        case .wrongTargetAddress(let address):
            return "Target address \(String(format: "%02X", address)) is blocked; 81 is scanner→host only."
        }
    }
}
