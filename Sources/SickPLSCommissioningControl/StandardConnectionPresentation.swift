// StandardConnectionPresentation.swift
//
// SICK-0330a-K1 (K1-4) — die **feste, exhaustive** Nutzertextabbildung
// der öffentlichen Standardverbindungsfehler.
//
// ## Warum eine eigene Datei
//
// Zustandsgrenze und Textgrenze bleiben so getrennt lesbar:
// `StandardConnectionRun.swift` entscheidet, **was** gilt; hier steht,
// **wie es heißt**. Dieselbe Haltung wie `CommissioningFailure
// .operatorSummary` (SICK-032a3) und `ZoneLearningPresentation`
// (SICK-032c2): **Der Text entsteht im Modell, nie erst in der Ansicht**
// — SICK-0330b/0331 zeigt ihn an, formuliert ihn aber nicht.
//
// ## Die eine Regel
//
// **Kein Text wird aus einem I/O-Fehler interpoliert.** Es gibt hier
// keinen Adaptertext, keinen Pfad, kein Kommandobyte, keinen Fehlercode
// und kein Passwort — nur feste Sätze zu geschlossenen Fällen. Der
// `switch` steht **ohne `default`**: Ein neuer Fehlerfall muss sich
// einen eigenen Satz geben, statt unter „fehlgeschlagen" zu
// verschwinden.

/// Alltagssprache für die öffentlichen Ausgänge des
/// Standardverbindungslaufs.
extension StandardConnectionFailure {

    /// Was **konkret** schiefging, in einem festen Satz.
    ///
    /// **Ohne jede Nutzlast** — der Wortlaut hängt allein am Fall, nie an
    /// einem Wert aus fremder Hand.
    public var operatorSummary: String {
        switch self {
        case .aborted:
            return "Aborted."
        case .invalidPort:
            return "No valid connection is selected."
        case .portOpenFailed:
            return "The connection could not be opened."
        case .portReadFailed:
            return "The connection was lost while reading."
        case .portWriteFailed:
            return "Sending over the connection failed."
        case .portCloseFailed:
            return "The connection could not be closed and remains occupied for now. "
                + "Retrying may release it."
        case .missingOrUnusablePassword:
            return "No usable scanner password is stored. "
                + "Nothing was sent to the scanner."
        case .manualPreparationRequired:
            return "No measurement stream was detected. Please prepare the scanner step by step in the support area; this connection attempt sent nothing."
        case .unexpectedEvent:
            return "The process received a response that is not expected here."
        case .startingRateSilent:
            return "The scanner did not respond at 9600 baud."
        case .startingRateUnexpectedResponse:
            return "The scanner responded unexpectedly at 9600 baud."
        case .startingRateAmbiguousResponse:
            return "Only an unreadable response was received at 9600 baud."
        case .settingsModeRejected:
            return "The scanner rejected the switch to settings mode."
        case .settingsModeUnanswered:
            return "No response was received for the switch to settings mode."
        case .settingsModeAmbiguous:
            return "Only an unreadable response was received for the switch to settings mode."
        case .loginRejected:
            return "The scanner rejected the login. The scanner password is likely incorrect."
        case .loginUnanswered:
            return "No response was received for the login, even on the third attempt."
        case .loginAmbiguous:
            return "Only an unreadable response was received for the login, even on the third attempt."
        case .baudSwitchRejected:
            return "The scanner rejected the switch to 38400 baud."
        case .baudSwitchUnanswered:
            return "No response was received for the switch to 38400 baud."
        case .baudSwitchAmbiguous:
            return "Only an unreadable response was received for the switch to 38400 baud."
        case .targetRateSilent:
            return "After the switch, the scanner did not respond at 38400 baud. "
                + "The switch is therefore unconfirmed."
        case .targetRateUnexpectedResponse:
            return "After the switch, the scanner responded unexpectedly at 38400 baud. "
                + "The switch is therefore unconfirmed."
        case .targetRateAmbiguousResponse:
            return "After the switch, only an unreadable response was received at 38400 baud. "
                + "The switch is therefore unconfirmed."
        case .measurementModeRejected:
            return "The scanner rejected the continuous measurement values."
        case .measurementStreamAbsent:
            return "After requesting continuous measurement values, no new measurement stream arrived within the time limit."
        case .measurementPointCountMismatch:
            return "The new measurement stream has the wrong point count for the selected mode."
        }
    }
}
