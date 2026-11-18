import PlanariumInput

/// Der eine sichtbare Zustand der **kompakten Verbindungsleiste**
/// (SICK-0330b, absorbiert SICK-0331).
///
/// ## Woraus er entsteht
///
/// Er ist eine **reine Ableitung** (``derive(run:stage:measurement:isAwaitingPortRelease:lastDisconnectedPort:)``)
/// aus vier Tatsachen, die das Verbindungsmodell hält: dem zuletzt
/// beobachteten ``StandardConnectionReport`` des Standardlaufs, der
/// Laufstufe des Modells, der redigierten RX-Kurzlage und der
/// Besitzwartephase. Er speichert nichts selbst und kennt weder Port,
/// Transport noch interne Laufzustände -- genau die Grenze, die
/// SICK-0330b verlangt: Die Leiste liest ausschließlich die
/// Fortschrittsgrenze des Laufs.
///
/// ## Ehrliche Gerätewirkung, keine Protokolldetails
///
/// Jeder Fall sagt, was am Gerät gerade geschieht (passiv beobachten,
/// Identität prüfen, umstellen, Messwerte anfordern, Port schließen),
/// aber nie Telegramm- oder Bauddetails. Der `switch` über die
/// Fortschrittsgrenze steht ohne `default`.
public enum ConnectionBarState: Equatable, Sendable {
    /// Nicht verbunden; noch nie oder nach einem abgeschlossenen Fehler.
    case disconnected
    /// Der Port ist offen; der Lauf beobachtet passiv auf einen
    /// vorhandenen Messstrom -- es geht nichts hinaus.
    case observing(portPath: String)
    /// Die eine harmlose Identitätsprobe ist unterwegs.
    case checkingIdentity(portPath: String)
    /// Der Scanner wird auf 38.400/Messwerte vorbereitet -- die Stufe
    /// nennt den aktiven Schritt.
    case preparing(portPath: String, stage: StandardConnectionCommissioningStage)
    /// Der Messstrom ist belegt; der TX-fähige Port wird jetzt wirklich
    /// geschlossen, bevor RX beginnt.
    case closingTransmitPort(portPath: String)
    /// Der Schluss des TX-Ports schlug fehl; der Port bleibt belegt, bis
    /// ein ausdrücklicher erneuter Schließversuch gelingt.
    case transmitPortStillHeld(portPath: String)
    /// Die RX-Sitzung wird geöffnet.
    case openingMeasurement(portPath: String)
    /// RX-Port offen, noch kein Profil -- ein offener Port ist kein
    /// Betriebsbeleg.
    case awaitingFirstProfile(portPath: String)
    /// Bereit: Messstrom steht, mit Punktzahl; Rate liegt separat in der Telemetrie.
    case ready(portPath: String, pointCount: Int)
    /// Der Strom ist während RX verloren gegangen oder RX ließ sich nicht
    /// öffnen; `message` ist der bereits redigierte Sitzungstext.
    case streamLost(portPath: String, message: String)
    /// Getrennt, das tatsächliche Schließen steht noch aus.
    case disconnecting(portPath: String)
    /// Getrennt -- der Scanner kann weiter senden.
    case disconnectedScannerMaySend(portPath: String)
    /// Der Standardlauf endete ohne Messstrom; `failure` nennt den
    /// redigierten Grund, `nextAction` die konkrete nächste Handlung.
    case failed(portPath: String, failure: StandardConnectionFailure)
    case inputIsSimulation(serviceName: String)

    /// Die Laufstufe des Verbindungsmodells -- **nur** die Frage, ob und
    /// welcher blockierende Aufruf gerade im Hintergrund läuft.
    public enum RunStage: Equatable, Sendable {
        case idle
        case connecting
        case releasingTransmitPort
        case retryingClose
    }

    /// Die eine Ableitungsregel. Reihenfolge ist Vertrag:
    ///
    /// 1. Ein laufender oder porthaltender Standardlauf dominiert.
    /// 2. Danach die RX-Kurzlage.
    /// 3. Danach die Besitzwartephase und das ausdrückliche Trennen.
    /// 4. Sonst ein abgeschlossener Fehlschlag oder „nicht verbunden".
    public static func derive(
        run: StandardConnectionReport?,
        runPortPath: String?,
        stage: RunStage,
        measurement: MeasurementSessionStatus,
        isAwaitingPortRelease: Bool,
        lastDisconnectedPort: String?
    ) -> ConnectionBarState {
        if let run, let portPath = runPortPath, let running = describeRun(run, portPath: portPath, stage: stage) {
            return running
        }
        if run == nil, stage == .connecting, let portPath = runPortPath {
            // Eingeplant, aber noch kein Bericht: der Lauf beginnt passiv.
            return .observing(portPath: portPath)
        }

        switch measurement {
        case .simulation(let simulation):
            switch simulation {
            case .opening(let service), .openWithoutProfile(let service), .streaming(let service, _):
                return .inputIsSimulation(serviceName: service)
            case .failed(let service, let message):
                return .streamLost(portPath: "iPhone-Simulation \(service)", message: message)
            }
        case .opening(let portPath):
            return .openingMeasurement(portPath: portPath)
        case .openWithoutProfile(let portPath):
            return .awaitingFirstProfile(portPath: portPath)
        case .streaming(let portPath, let pointCount):
            return .ready(portPath: portPath, pointCount: pointCount)
        case .failed(let portPath, let message):
            return .streamLost(portPath: portPath, message: message)
        case .idle:
            break
        }

        if isAwaitingPortRelease, let portPath = lastDisconnectedPort {
            return .disconnecting(portPath: portPath)
        }
        if let portPath = lastDisconnectedPort {
            return .disconnectedScannerMaySend(portPath: portPath)
        }
        if let run, let portPath = runPortPath, case .failed(let failure) = run.phase {
            return .failed(portPath: portPath, failure: failure)
        }
        return .disconnected
    }

    /// Der Anteil, den ein Standardlauf beiträgt -- `nil`, sobald er
    /// abgeschlossen ist und den Port nicht mehr hält (dann entscheiden
    /// RX-Lage bzw. der Fehlerfall unten).
    private static func describeRun(
        _ report: StandardConnectionReport, portPath: String, stage: RunStage
    ) -> ConnectionBarState? {
        switch report.phase {
        case .idle:
            return stage == .connecting ? .observing(portPath: portPath) : nil
        case .observingPassively:
            return .observing(portPath: portPath)
        case .checkingIdentityAtTargetRate:
            return .checkingIdentity(portPath: portPath)
        case .runningCommissioning(let stage, _):
            return .preparing(portPath: portPath, stage: stage)
        case .ready:
            // Erfolg mit gehaltenem Port: der Schluss steht an oder läuft.
            return report.isPortHeld ? .closingTransmitPort(portPath: portPath) : nil
        case .failed(.portCloseFailed):
            return report.isPortHeld ? .transmitPortStillHeld(portPath: portPath) : nil
        case .failed:
            // Ein Fehlschlag mit noch gehaltenem Port ist strukturell
            // immer `.portCloseFailed` (Dominanzregel K1-3); alle anderen
            // Fehlschläge sind portfrei und werden unten dargestellt.
            return nil
        }
    }
}
