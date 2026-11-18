import PlanariumInput

/// Die feste Textabbildung der Verbindungsleiste (SICK-0330b).
///
/// **Der Text entsteht im Modell, nie in der Ansicht** -- dieselbe
/// Haltung wie ``StandardConnectionPresentation``. Kein Satz wird aus
/// einem I/O-Fehler, Byte oder Passwort interpoliert; der einzige
/// eingesetzte Fremdwert ist der vom Bedienenden selbst gewählte
/// Portpfad und der bereits redigierte Sitzungstext. Jeder `switch`
/// steht ohne `default`.
public struct ConnectionBarPresentation: Equatable, Sendable {
    /// Der Statussatz in Alltagssprache.
    public let statusText: String
    /// Die konkrete nächste Handlung, wo es eine gibt.
    public let nextActionText: String?
    /// Ob gerade Gerätewirkung läuft oder ein Port gehalten wird.
    public let isBusy: Bool
    /// Ob die primäre Schaltfläche „Trennen" (statt „Verbinden") zeigt.
    public let showsDisconnect: Bool
    /// Ob ein erneuter Schließversuch angeboten wird.
    public let offersCloseRetry: Bool

    public init(_ state: ConnectionBarState, profileRateHz: Double? = nil) {
        switch state {
        case .disconnected:
            statusText = "Not connected."
            nextActionText = nil
            isBusy = false
            showsDisconnect = false
            offersCloseRetry = false
        case .observing(let portPath):
            statusText = "Searching for scanner at \(portPath) – listening only."
            nextActionText = nil
            isBusy = true
            showsDisconnect = true
            offersCloseRetry = false
        case .checkingIdentity:
            statusText = "Checking identity."
            nextActionText = nil
            isBusy = true
            showsDisconnect = true
            offersCloseRetry = false
        case .preparing(_, let stage):
            statusText = Self.describe(stage)
            nextActionText = nil
            isBusy = true
            showsDisconnect = true
            offersCloseRetry = false
        case .closingTransmitPort:
            statusText = "Stream held – reopening port for measurement."
            nextActionText = nil
            isBusy = true
            showsDisconnect = false
            offersCloseRetry = false
        case .transmitPortStillHeld:
            statusText = StandardConnectionFailure.portCloseFailed.operatorSummary
            nextActionText = "Retry close."
            isBusy = true
            showsDisconnect = false
            offersCloseRetry = true
        case .openingMeasurement:
            statusText = "Opening measurement mode."
            nextActionText = nil
            isBusy = true
            showsDisconnect = true
            offersCloseRetry = false
        case .awaitingFirstProfile:
            statusText = "Port open – waiting for first profile."
            nextActionText = nil
            isBusy = true
            showsDisconnect = true
            offersCloseRetry = false
        case .ready(_, let pointCount):
            let rateText = profileRateHz.map { Self.format(rateHz: $0) } ?? "Rate being determined"
            statusText = "Ready – \(pointCount) points, \(rateText)."
            nextActionText = nil
            isBusy = true
            showsDisconnect = true
            offersCloseRetry = false
        case .streamLost(_, let message):
            statusText = "Stream lost: \(message)"
            nextActionText = "Reconnect."
            isBusy = false
            showsDisconnect = false
            offersCloseRetry = false
        case .disconnecting:
            statusText = "Disconnecting."
            nextActionText = nil
            isBusy = true
            showsDisconnect = false
            offersCloseRetry = false
        case .disconnectedScannerMaySend:
            statusText = "Disconnected – scanner may still be sending."
            nextActionText = nil
            isBusy = false
            showsDisconnect = false
            offersCloseRetry = false
        case .failed(_, let failure):
            statusText = failure.operatorSummary
            nextActionText = Self.nextAction(after: failure)
            isBusy = false
            showsDisconnect = false
            offersCloseRetry = false
        case .inputIsSimulation(let serviceName):
            statusText = "iPhone simulation \(serviceName) receiving measurements."
            nextActionText = nil
            isBusy = true
            showsDisconnect = true
            offersCloseRetry = false
        }
    }

    /// Was der Scanner in dieser Stufe gerade erfährt -- Gerätewirkung
    /// in Alltagssprache, ohne Telegrammdetails.
    static func describe(_ stage: StandardConnectionCommissioningStage) -> String {
        switch stage {
        case .adoptingConfirmedIdentity:
            return "Scanner detected – requesting measurements."
        case .checkingStartingRate:
            return "Searching for scanner at starting rate."
        case .respondingAtStartingRate:
            return "Scanner responding – preparing for fast transmission."
        case .loggingInAndSwitchingBaudRate:
            return "Logging in and switching baud rate."
        case .verifiedAtTargetRate:
            return "Switch confirmed – requesting measurements."
        case .awaitingMeasurementStream:
            return "Measurements requested – waiting for stream."
        case .runningRateDiagnostics:
            return "Checking connection."
        case .rateDiagnosticsFinished:
            return "Check complete."
        case .sessionFinished:
            return "Preparation complete."
        }
    }

    /// Die nächste Handlung je Fehlerfall -- fest je Fall, keine
    /// Interpolation.
    static func nextAction(after failure: StandardConnectionFailure) -> String? {
        switch failure {
        case .aborted:
            return nil
        case .invalidPort:
            return "Select a port."
        case .portOpenFailed:
            return "Port busy or unreachable – check cable and other programs, then reconnect."
        case .portReadFailed, .portWriteFailed:
            return "Check cable and reconnect."
        case .portCloseFailed:
            return "Retry close."
        case .missingOrUnusablePassword:
            return "Enter scanner password in Settings (⌘,), then reconnect."
        case .manualPreparationRequired:
            return "Open Support and follow the scanner setup steps."
        case .unexpectedEvent:
            return "Reconnect."
        case .startingRateSilent, .startingRateUnexpectedResponse, .startingRateAmbiguousResponse,
             .settingsModeRejected, .settingsModeUnanswered, .settingsModeAmbiguous:
            return "Power on the scanner and check the port, then reconnect."
        case .loginRejected:
            return "Check scanner password in Settings (⌘,)."
        case .loginUnanswered, .loginAmbiguous, .baudSwitchRejected, .baudSwitchUnanswered,
             .baudSwitchAmbiguous, .targetRateSilent, .targetRateUnexpectedResponse,
             .targetRateAmbiguousResponse:
            return "Power cycle the scanner, then reconnect."
        case .measurementModeRejected, .measurementStreamAbsent, .measurementPointCountMismatch:
            return "Reconnect; if it persists, power cycle the scanner."
        }
    }

    static func format(rateHz: Double) -> String {
        let tenths = (rateHz * 10).rounded()
        let whole = Int(tenths / 10)
        let fraction = Int(tenths) - whole * 10
        return "\(whole),\(fraction) Hz"
    }
}
