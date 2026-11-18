import SickPLSActiveControl
import SickPLSMacTransport

/// Die **geschlossene** Parameterkombination des Commissioning-Ablaufs
/// (SICK-030a, Auflage **A4** aus `review-sick-030-architecture.md`).
///
/// ## Warum ein Rezept und kein Satz Regler
///
/// Die Beleglage aus `SICK Doku/integration/active-sequences.md` zeigt
/// **zwei** Login-Varianten, deren Zieladresse und Modusbyte **paarweise
/// zusammengehören**: Nur die eine erlaubt danach einen Baudwechsel, die
/// andere wird beim Baudtelegramm in jeder Beobachtung abgelehnt. Ein
/// freier Adress- oder Moduswähler ließe den Bedienenden genau die
/// Kombination einstellen, von der belegt ist, dass sie **nicht**
/// funktioniert — und die Fehlersuche stünde danach vor einem
/// Parameterraum statt vor einem Befund.
///
/// Ebenso beim Baudcode: Nur **ein** Zielwert wurde je mit ACK
/// beantwortet. Andere Raten wurden abgelehnt oder blieben unbeantwortet;
/// ob das grundsätzlich gilt oder an jenem Aufbau lag, ist offen. Deshalb
/// gibt es in diesem Rezept **keine** Baudratenauswahl. Der Transporttyp
/// kennt inzwischen zusätzlich die separat über RS-422 belegte Rate 500000;
/// das geschlossene R26-Rezept bleibt davon unberührt bei 9600 → 38400.
///
/// **Es gibt genau ein Rezept (``r26``) und keinen öffentlichen
/// Initialisierer.** Wer eine andere Kombination braucht, braucht zuerst
/// einen Beleg — und dann einen Slice, nicht einen Regler.
///
/// ## Was hier bewusst nicht steht
///
/// Keine vollständigen Rohtelegramme und **kein Geheimnis** (Auflage
/// A5). Die Kommando- und Modusbytes sind Protokollstruktur, kein
/// Geheimnis; das Geheimnisfeld kommt ausschließlich aus
/// ``InstallationSecret`` und wird erst im Encoder eingesetzt.
public struct CommissioningRecipe: Equatable, Sendable {

    // MARK: - Der belegte Weg

    /// Die Rate, bei der der Ablauf beginnt.
    ///
    /// Belegt als Ausgangszustand nach einem Geräteneustart — und
    /// **unabhängig davon** die einzige Rate, bei der dieses Projekt je
    /// eine echte Antwort gesehen hat (SICK-012, Identitätsprobe auf
    /// macOS, während ein Messstrom lief).
    public let startingBaudRate: SerialPortBaudRate

    /// Die Zielrate des überwachten Wechsels.
    public let targetBaudRate: SerialPortBaudRate

    /// Zieladresse für die adressierten Telegramme des Einrichtungshelfers
    /// (Login, Baudwechsel, Messmodus).
    ///
    /// Der Owner hat für den realen Scanner Adresse 1 verbindlich
    /// festgelegt. Login, Baudwechsel und Messmodus verwenden Adresse 1.
    public let configurationAddress: ConfirmedTargetAddress

    /// Zieladresse für die Verifikations-Identitätsprobe **nach dem
    /// Baudwechsel bei 38400**. Belegt durch C7/C10 als Universaladresse `0x00`.
    public let verificationAddress: ConfirmedTargetAddress

    /// Zieladresse für den **vorgeschalteten Eintritt in den
    /// Einstellungsmodus (PLSIBS-Autorisierung)**. Belegt durch C7/C10 als Universaladresse `0x00`.
    public let settingsModeAddress: ConfirmedTargetAddress

    /// Kommandobyte der Konfigurationstelegramme (Login, Baudwechsel,
    /// Messmodus teilen es sich; unterschieden wird über das folgende
    /// Byte).
    public let configurationCommandByte: UInt8

    /// Modusbyte für den vorgeschalteten Einstellungsmodus.
    public let settingsModeByte: UInt8

    /// Modusbyte des Logins. **Nur in Verbindung mit
    /// ``configurationAddress`` belegt.**
    public let loginModeByte: UInt8

    /// Modusbyte, das den Baudwechsel auf ``targetBaudRate`` anfordert.
    /// Der einzige je mit ACK beantwortete Zielwert.
    public let baudSwitchModeByte: UInt8

    /// Selected continuous mode. Its success requires a new CRC-valid B0
    /// profile with the expected point count; an ACK alone is insufficient.
    public var measurementModeByte: UInt8 { measurementMode.commandByte }
    public private(set) var measurementMode: ScannerMeasurementMode = .mmk

    public func selectingMeasurementMode(_ mode: ScannerMeasurementMode) -> Self {
        var copy = self
        copy.measurementMode = mode
        return copy
    }

    // MARK: - Fristen und Wiederholungen

    /// Harte, monotone Gesamtfrist je gesendetem Telegramm.
    ///
    /// Belegte Antwortlatenzen liegen weit darunter; die Frist
    /// entspricht dem beobachteten Lesefenster. **Gesamtfrist ab dem
    /// Sendezeitpunkt**, nicht je Leseversuch neu — dasselbe Muster wie
    /// `BaudProbe.probeOnce` seit SICK-011a, sonst verlängerte
    /// fortlaufendes Rauschen einen Versuch unbegrenzt.
    public let responseTimeoutMilliseconds: Int64

    /// Antwortfrist je adressiertem Login-Versuch. Das aktiv erfolgreiche
    /// Referenzprogramm verwendete das volle 2-Sekunden-Lesefenster.
    /// `ACKResponseTimeout=500` aus `Plsibs.ini` ist kein belegter
    /// Gesamtwert dieses Fensters und wird deshalb nicht umgedeutet.
    public let loginResponseTimeoutMilliseconds: Int64

    /// Harte, monotone Gesamtfrist für den MMK-Stromnachweis nach der
    /// Anforderung „Messwerte minimal kontinuierlich" (SICK-0330a-0).
    ///
    /// **Eine eigene, längere Frist als ``responseTimeoutMilliseconds``**
    /// — die einzige reale Beobachtung zu diesem Schritt hatte keine
    /// zuverlässig lesbare unmittelbare Quittung, aber danach echten
    /// B0-Strom bei 38400. Ein gemeinsamer, kürzerer Vorgabewert hätte
    /// genau diesen belegten Verlauf riskiert, als Fehlschlag zu enden,
    /// bevor der Strom überhaupt einsetzen konnte.
    ///
    /// **Absolute Gesamtfrist ab dem Sendezeitpunkt**, nicht je
    /// Leseversuch neu — dasselbe Muster wie
    /// ``responseTimeoutMilliseconds``. Kein öffentlicher freier Regler:
    /// Der Wert steht ausschließlich in ``r26``.
    public let measurementStreamTimeoutMilliseconds: Int64

    /// **Genau zwei** identische Wiederholungen des Logins nach
    /// abgelaufener Frist; das entspricht `RepeatCounter=2` der
    /// Windows-Referenz.
    ///
    /// Die ersten Login-Versuche blieben in den Windows-Beobachtungen
    /// wiederholt unbeantwortet; spätestens der dritte identische Versuch
    /// brachte das ACK. Ein Ablauf ohne diese Wiederholungen
    /// meldete nach Beleglage immer Zeitüberschreitung; einer, der sie
    /// dem Bedienenden als zweiten Klick überließe, machte aus einem
    /// dokumentierten Protokollmerkmal eine Fehlbedienungsquelle.
    ///
    /// **Maximum ist 2.** Für jedes andere Telegramm gilt **null**
    /// Wiederholungen.
    public let loginRetryCount: Int

    /// Obergrenze für ``loginRetryCount`` — strukturell, nicht als
    /// Empfehlung. Ein Wiederholungssturm auf ein Konfigurations-
    /// telegramm ist keine Variante, die dieses Modell anbieten darf.
    public static let maximumLoginRetryCount = 2

    private init(
        startingBaudRate: SerialPortBaudRate,
        targetBaudRate: SerialPortBaudRate,
        configurationAddress: ConfirmedTargetAddress,
        verificationAddress: ConfirmedTargetAddress,
        settingsModeAddress: ConfirmedTargetAddress,
        configurationCommandByte: UInt8,
        settingsModeByte: UInt8,
        loginModeByte: UInt8,
        baudSwitchModeByte: UInt8,
        responseTimeoutMilliseconds: Int64,
        loginResponseTimeoutMilliseconds: Int64,
        measurementStreamTimeoutMilliseconds: Int64,
        loginRetryCount: Int
    ) {
        self.startingBaudRate = startingBaudRate
        self.targetBaudRate = targetBaudRate
        self.configurationAddress = configurationAddress
        self.verificationAddress = verificationAddress
        self.settingsModeAddress = settingsModeAddress
        self.configurationCommandByte = configurationCommandByte
        self.settingsModeByte = settingsModeByte
        self.loginModeByte = loginModeByte
        self.baudSwitchModeByte = baudSwitchModeByte
        self.responseTimeoutMilliseconds = responseTimeoutMilliseconds
        self.loginResponseTimeoutMilliseconds = loginResponseTimeoutMilliseconds
        self.measurementStreamTimeoutMilliseconds = measurementStreamTimeoutMilliseconds
        self.loginRetryCount = loginRetryCount
    }

    /// Das einzige Rezept: die einmal real reproduzierte Kombination.
    ///
    /// Benannt nach der Beobachtungsrunde, in der sie gelang — damit im
    /// Code steht, **woher** die Werte kommen, und nicht nur, dass sie
    /// dort stehen. Die Beobachtung stammt aus einem anderen Aufbau
    /// (anderes Betriebssystem, andere Verkabelung); auf macOS ist von
    /// diesem Weg bisher **nur** die Identitätsprobe real ausgeführt
    /// worden.
    public static let r26 = CommissioningRecipe(
        startingBaudRate: .baud9600,
        targetBaudRate: .baud38400,
        configurationAddress: ConfirmedTargetAddress(rawValue: 0x01)!,
        verificationAddress: ConfirmedTargetAddress(rawValue: 0x00)!,
        settingsModeAddress: ConfirmedTargetAddress(rawValue: 0x00)!,
        configurationCommandByte: 0x20,
        settingsModeByte: 0x30,
        loginModeByte: 0x00,
        baudSwitchModeByte: 0x40,
        responseTimeoutMilliseconds: 2_000,
        loginResponseTimeoutMilliseconds: 2_000,
        measurementStreamTimeoutMilliseconds: 3_000,
        loginRetryCount: CommissioningRecipe.maximumLoginRetryCount
    )

    /// Wie oft das Login insgesamt gesendet wird: der erste Versuch plus
    /// die beiden belegten Wiederholungen.
    public var maximumLoginAttempts: Int { 1 + loginRetryCount }
}
