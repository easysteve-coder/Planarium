import SickPLSMacTransport

/// Was gesendet wurde — als benannte Handlung, nie als Bytes
/// (SICK-030a).
public enum CommissioningAction: Equatable, Sendable {
    /// Die harmlose Identitätsprobe bei der Ausgangsrate.
    case identityCheck(SerialPortBaudRate)
    /// Eintritt in den allgemeinen Einstellungsmodus vor dem Login.
    case settingsMode
    /// Das Login-Telegramm.
    case login
    /// Die Anforderung des Baudwechsels.
    case baudSwitchRequest
    /// Die Identitätsprobe am neu geöffneten Port bei der Zielrate —
    /// **das** Erfolgskriterium des Wechsels (Auflage A1).
    case verification(SerialPortBaudRate)
    /// Der experimentelle Messmodus-Schritt.
    case measurementModeRequest
    case fullScanMeasurementModeRequest
    /// Die Ratendiagnose nach einem Fehlschlag.
    case diagnosticProbe(SerialPortBaudRate)
}

/// Wie eine Sendung ausging (SICK-030a).
///
/// Bewusst nah an ``AcknowledgementOutcome`` und `IdentityProbeOutcome`,
/// aber ein eigener Typ: Ein Auditeintrag ist eine **Aufzeichnung**, und
/// die soll nicht an der Klassifikation kleben, die morgen einen Fall
/// mehr haben könnte.
public enum CommissioningAuditOutcome: Equatable, Sendable {
    /// Gesendet; die Antwort steht noch aus.
    case sent
    case acknowledged
    case rejected
    case timedOut
    /// Etwas kam an, war aber nicht auswertbar — fehlendes Statusbyte,
    /// unbekanntes Statusbyte, unerwartetes Kommandobyte, nicht
    /// decodierbare Bytes.
    case ambiguous
    /// Ein Messstrom wurde **beobachtet**. Nur Information, nie Erfolg
    /// (Auflage A1) — außer beim Messmodus-Schritt, wo er das
    /// Erfolgskriterium ist.
    case observedScanProfileStream
    /// Das Schreiben selbst schlug fehl; es ging nichts hinaus.
    case writeFailed
}

/// Die unmittelbare Antwort auf eine Sendung — getrennt von deren
/// späterer Wirkung (SICK-0330a-0-K1).
///
/// **Drei Fälle plus `nil`.** `nil` steht für „innerhalb des Fensters
/// keine unmittelbare Antwort" — die vierte, vom Auftrag verlangte
/// Kategorie braucht damit keinen eigenen Fall: Ein Optional dieses
/// geschlossenen Enums ist selbst eine geschlossene, vierwertige
/// Klassifikation, ohne ein leeres `.none` neben Swifts eigenem `nil`
/// zu führen.
///
/// **Redigiert, nie das Rohbyte.** `unreadable` fasst unlesbare,
/// unerwartete und unbekannte Antworten zusammen — zwei verschiedene
/// unbekannte Status- oder Kommandobytes ergeben denselben Fall
/// (Pflichtnachweis 3), dieselbe Haltung wie
/// ``CommissioningAuditOutcome/ambiguous``.
public enum CommissioningImmediateResponse: Equatable, Sendable {
    case acknowledged
    case rejected
    /// Unlesbar, unerwartet oder mit unbekanntem Status — nie das Byte
    /// selbst.
    case unreadable
}

/// Ein einzelner sichtbarer Schritt (SICK-030a, Auflage **A2**/N2).
///
/// **Trägt nie Bytes und nie das Geheimnis** — nur, *was* getan wurde,
/// *wann*, in welchem Versuch, an welche Adresse und *wie* es ausging.
/// Die Regel ist dieselbe wie bei `IdentityProbeAuditLog` (SICK-011);
/// neu sind der monotone Zeitpunkt und die Sendungsnummer.
public struct CommissioningAuditEntry: Equatable, Sendable {
    public let action: CommissioningAction
    /// `1` für die erste Sendung, `2` für die **eine** belegte
    /// Login-Wiederholung. Damit ist die Wiederholung im Protokoll
    /// sichtbar und nicht als zweiter, scheinbar eigenständiger Schritt
    /// getarnt (Auflage A2).
    public let attemptNumber: Int
    public let targetAddress: UInt8
    /// Zeitpunkt einer **monotonen** Uhr des Aufrufers, in Millisekunden
    /// — keine Wanduhrzeit, keine eigene Zeitabfrage. Dasselbe Muster
    /// wie `MonotonicClock` (SICK-011a) und `MonotonicTimeline`
    /// (SICK-027).
    public let monotonicMillis: Int64
    public private(set) var outcome: CommissioningAuditOutcome
    /// Die unmittelbare Antwort auf **diese** Sendung, getrennt von
    /// ``outcome`` (SICK-0330a-0-K1).
    ///
    /// **Zwei Fakten auf demselben Eintrag, die einander nie
    /// überschreiben:** ``outcome`` trägt die spätere Wirkung (Strom
    /// beobachtet, Frist abgelaufen, abgelehnt, ...); dieses Feld trägt
    /// ausschließlich, was innerhalb des Lesefensters unmittelbar
    /// zurückkam, bevor diese Wirkung feststand. Ein später beobachteter
    /// B0-Strom löscht ein zuvor vermerktes ACK/Unlesbar nicht, und ein
    /// früh vermerktes ACK verschluckt den späteren Stromerfolg nicht.
    public private(set) var immediateResponse: CommissioningImmediateResponse?

    init(
        action: CommissioningAction,
        attemptNumber: Int,
        targetAddress: UInt8,
        monotonicMillis: Int64,
        outcome: CommissioningAuditOutcome
    ) {
        self.action = action
        self.attemptNumber = attemptNumber
        self.targetAddress = targetAddress
        self.monotonicMillis = monotonicMillis
        self.outcome = outcome
    }

    mutating func complete(with outcome: CommissioningAuditOutcome) {
        self.outcome = outcome
    }

    /// Trägt die unmittelbare Antwort ein — **ohne** ``outcome``
    /// anzufassen (SICK-0330a-0-K1).
    mutating func recordImmediateResponse(_ response: CommissioningImmediateResponse) {
        immediateResponse = response
    }
}

/// Das fortlaufende, redigierte Protokoll eines Ablaufs (SICK-030a).
///
/// Reiner Wert ohne Uhr: Jeder Eintrag bekommt seinen Zeitpunkt vom
/// Aufrufer. Es gibt **keinen** öffentlichen Weg, einen Eintrag zu
/// schreiben — Einträge entstehen ausschließlich im Reducer, damit das
/// Protokoll nicht neben dem Ablauf her erfunden werden kann.
public struct CommissioningAudit: Equatable, Sendable {
    public private(set) var entries: [CommissioningAuditEntry] = []

    public init() {}

    /// Wie oft diese Handlung bereits gesendet wurde — die Grundlage der
    /// Sendungsnummer.
    func attemptCount(of action: CommissioningAction) -> Int {
        entries.filter { $0.action == action }.count
    }

    mutating func recordSend(
        _ action: CommissioningAction,
        attemptNumber: Int,
        targetAddress: UInt8,
        atMillis: Int64
    ) {
        entries.append(
            CommissioningAuditEntry(
                action: action,
                attemptNumber: attemptNumber,
                targetAddress: targetAddress,
                monotonicMillis: atMillis,
                outcome: .sent
            )
        )
    }

    /// Schließt den **zuletzt** eröffneten, noch offenen Eintrag ab.
    /// Ohne offenen Eintrag ein No-op — der Reducer soll an einer
    /// unerwarteten Antwort nicht abstürzen.
    mutating func completeLast(with outcome: CommissioningAuditOutcome) {
        guard let index = entries.lastIndex(where: { $0.outcome == .sent }) else { return }
        entries[index].complete(with: outcome)
    }

    /// Trägt die unmittelbare Antwort auf den **zuletzt eröffneten,
    /// noch offenen** Eintrag ein — ohne dessen ``outcome`` zu ändern
    /// (SICK-0330a-0-K1).
    ///
    /// **Dieselbe „noch offen"-Suche wie ``completeLast(with:)``**: Sie
    /// findet denselben Eintrag, solange dessen `outcome` noch `.sent`
    /// ist — also auch noch, nachdem diese Methode bereits einmal
    /// gelaufen ist. Ein No-op ohne offenen Eintrag, aus demselben Grund
    /// wie dort.
    mutating func recordImmediateResponse(_ response: CommissioningImmediateResponse) {
        guard let index = entries.lastIndex(where: { $0.outcome == .sent }) else { return }
        entries[index].recordImmediateResponse(response)
    }
}
