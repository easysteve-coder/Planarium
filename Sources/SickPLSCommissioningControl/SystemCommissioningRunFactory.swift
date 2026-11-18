import SickPLSActiveControl
import SickPLSCommissioning

/// Die **einzige Stelle dieses Ziels, die einen echten Lauf herstellt**
/// (SICK-032a, Bedienvertrag Punkt 5).
///
/// Sie erzeugt den realen Transport und den Executor — sonst niemand, und
/// die Oberfläche schon gar nicht. `CommissioningControlBoundaryTests`
/// verbietet `ActiveControlCommissioningTransport`,
/// `CommissioningExecutor` und `DarwinActiveControlSerialPortOpener` in
/// jeder anderen Datei dieses Ziels und im App-Ziel.
///
/// **Sie öffnet nichts.** Der Transport prüft im Initialisierer nur den
/// Pfad; geöffnet wird erst, wenn eine Direktive des Reducers es
/// verlangt, also frühestens innerhalb eines ausdrücklich bestätigten
/// `perform`.
///
/// Rezept und Uhr kommen aus den Vorgaben: ``CommissioningRecipe/r26``
/// (Auflage A4, nicht wählbar) und `DarwinMonotonicClock`. **Die
/// Oberfläche erzeugt keine Zeitquelle.**
///
/// ## Datenfreie Fehlergrenze (SICK-032a1)
///
/// Was hier schiefgehen kann, wird **einzeln benannt** oder als
/// ``CommissioningRunUnavailableReason/transportUnavailable``
/// weitergereicht. Es wird **kein** `Error` beschrieben, interpoliert
/// oder lokalisiert — ein fremder Opener könnte in seiner Beschreibung
/// Port-, Payload- oder Geheimnisdaten tragen, und diese Grenze soll
/// nicht davon abhängen, dass er es nicht tut.
public struct SystemCommissioningRunFactory: CommissioningRunProviding {

    /// Wie der Transport entsteht.
    ///
    /// **Eine interne Naht, kein Konfigurationspunkt.** Sie ist nötig,
    /// weil die reale Transportgrenze im Initialisierer ausschließlich
    /// den Pfad prüft — und den prüft diese Fabrik selbst schon davor.
    /// Ohne die Naht wäre der Fremdfehlerzweig unerreichbar und damit
    /// unbelegbar; genau das war der Zustand, den SICK-032a1 schließt.
    private let makeTransport: (String) throws -> CommissioningTransport

    public init(opener: ActiveControlSerialPortOpener = DarwinActiveControlSerialPortOpener()) {
        self.makeTransport = { portPath in
            try ActiveControlCommissioningTransport(portPath: portPath, opener: opener)
        }
    }

    /// Nur für die Nachweise: ein Transportbau, der beliebig fehlschlagen
    /// darf. **Nicht öffentlich** — von außen gibt es genau einen Weg.
    init(makeTransport: @escaping (String) throws -> CommissioningTransport) {
        self.makeTransport = makeTransport
    }

    public func makeRun(portPath: String) throws -> CommissioningRunning & CommissioningAborting {
        guard !portPath.isEmpty else {
            throw CommissioningRunUnavailableReason.noPortSelected
        }
        guard portPath.hasPrefix("/dev/cu.") else {
            // Dieselbe Grenze wie im Transport, hier nur früher und mit
            // einem Typ, den die Bedienung anzeigen kann. Der Transport
            // setzt sie unabhängig davon ein zweites Mal durch -- die
            // Antwort einer Bedienschicht ist keine Zusicherung.
            //
            // **Die Nutzlast ist unser eigener, gerade geprüfter Pfad**,
            // nicht die Beschreibung eines fremden Fehlers.
            throw CommissioningRunUnavailableReason.pathNotAllowed(portPath)
        }
        do {
            let transport = try makeTransport(portPath)
            return CommissioningExecutor(transport: transport)
        } catch let reason as CommissioningRunUnavailableReason {
            // Bereits typisiert und geprüft -- unverändert durchreichen,
            // statt den Grund ein zweites Mal zu bewerten.
            throw reason
        } catch {
            // **Alles andere verliert hier jede Nutzlast.** Kein
            // `String(describing:)`, kein `localizedDescription`, keine
            // Interpolation eines Fremdwerts: Wir wissen nicht, was in
            // dieser Beschreibung steht, und ein Wert, den wir nicht
            // weiterreichen, kann auch nicht in Hinweis, Audit oder
            // Debug-Ausgabe auftauchen.
            throw CommissioningRunUnavailableReason.transportUnavailable
        }
    }
}

/// Die **einzige Stelle, die einen echten Standardverbindungslauf
/// herstellt** (SICK-0330b) -- derselbe Transportbau und dieselbe
/// Pfadgrenze wie beim manuellen Einrichtungspfad oben, nur mit dem
/// abgenommenen ``StandardConnectionRun`` als Lauf.
///
/// **Sie öffnet nichts.** Der Transport prüft im Initialisierer nur den
/// Pfad; geöffnet wird erst innerhalb von `connect(portPath:)`, also
/// erst nach dem Klick auf `Verbinden`. Rezept und Uhr kommen aus den
/// Vorgaben (``CommissioningRecipe/r26``, `DarwinMonotonicClock`); das
/// Passwort liest der Lauf selbst erst unmittelbar vor Login/Baudwechsel
/// aus der injizierten Ablage -- diese Fabrik hält es nie.
public struct SystemStandardConnectionRunFactory: StandardConnectionRunProviding {

    private let makeTransport: (String) throws -> CommissioningTransport
    private let passwordStore: ScannerPasswordStoring
    private let allowsAutomaticCommissioning: Bool

    public init(
        passwordStore: ScannerPasswordStoring,
        allowsAutomaticCommissioning: Bool = true,
        opener: ActiveControlSerialPortOpener = DarwinActiveControlSerialPortOpener()
    ) {
        self.passwordStore = passwordStore
        self.allowsAutomaticCommissioning = allowsAutomaticCommissioning
        self.makeTransport = { portPath in
            try ActiveControlCommissioningTransport(portPath: portPath, opener: opener)
        }
    }

    public func makeRun(
        portPath: String,
        measurementMode: ScannerMeasurementMode = .mmk,
        onProgress: @escaping StandardConnectionProgressHandler
    ) throws -> StandardConnectionRun {
        guard !portPath.isEmpty else {
            throw CommissioningRunUnavailableReason.noPortSelected
        }
        guard portPath.hasPrefix("/dev/cu.") else {
            throw CommissioningRunUnavailableReason.pathNotAllowed(portPath)
        }
        do {
            let transport = try makeTransport(portPath)
            return StandardConnectionRun(
                transport: transport, passwordStore: passwordStore, measurementMode: measurementMode,
                allowsAutomaticCommissioning: allowsAutomaticCommissioning,
                onProgress: onProgress
            )
        } catch let reason as CommissioningRunUnavailableReason {
            throw reason
        } catch {
            // Dieselbe datenfreie Fehlergrenze wie oben (SICK-032a1).
            throw CommissioningRunUnavailableReason.transportUnavailable
        }
    }
}
