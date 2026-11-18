/// Validierte Konfiguration eines ``ControlValuePredictor``
/// (SICK-015-Auftrag 1.2: „Konfiguration muss validiert sein ... Keine
/// stillen Default-Korrekturen ungültiger Konfiguration").
///
/// Alle Zeitangaben sind **Sekunden auf derselben monotonen Zeitbasis**,
/// die auch `ControlValuePredictor.observe(value:atTime:)` und
/// `ControlValuePredictor.estimate(at:)` verwenden -- siehe den
/// Zeitbasis-Vertrag im Kopfkommentar von ``ControlValuePredictor``.
public struct ControlValuePredictorConfiguration: Equatable, Sendable {
    /// Positionsglättung des Alpha-Beta-Schätzers, `0 < alpha <= 1`:
    /// Anteil des Residuums, der sofort auf die geschätzte Position
    /// angewendet wird. `1.0` heißt „der echten Messung voll folgen",
    /// kleinere Werte glätten stärker.
    public let alpha: Double
    /// Geschwindigkeitsglättung, `0 < beta <= 1`. Bewusst enger
    /// begrenzt als die allgemeine Alpha-Beta-Stabilitätsbedingung
    /// (`beta < 4 - 2*alpha`) es verlangen würde: für jedes zulässige
    /// `alpha <= 1` gilt `4 - 2*alpha >= 2 > 1 >= beta`, die Bedingung
    /// ist damit strukturell immer erfüllt, ohne sie zur Laufzeit
    /// nachrechnen zu müssen.
    public let beta: Double
    /// Kurzer Vorhersagehorizont in Sekunden, `> 0`. Über diesen
    /// Abstand zur letzten echten Beobachtung hinaus wird **nicht**
    /// weiter extrapoliert (siehe ``ControlValuePredictor/estimate(at:)``).
    public let predictionHorizonSeconds: Double
    /// Abstand zur letzten echten Beobachtung, ab dem der Ausgang
    /// zwingend inaktiv wird, `> 0` und `>= predictionHorizonSeconds`.
    public let staleTimeoutSeconds: Double
    /// Betragsgrenze des Innovations-/Residuums (`Messwert − Vorhersage`),
    /// `> 0`. Wird sie überschritten, gilt die Beobachtung als Sprung
    /// und der Zustand wird mit der **echten** Beobachtung und
    /// Geschwindigkeit `0` neu initialisiert (SICK-015-Auftrag 1.4).
    public let outlierThreshold: Double

    private init(
        alpha: Double,
        beta: Double,
        predictionHorizonSeconds: Double,
        staleTimeoutSeconds: Double,
        outlierThreshold: Double
    ) {
        self.alpha = alpha
        self.beta = beta
        self.predictionHorizonSeconds = predictionHorizonSeconds
        self.staleTimeoutSeconds = staleTimeoutSeconds
        self.outlierThreshold = outlierThreshold
    }

    /// Fehler bei der validierenden Konstruktion über
    /// ``build(alpha:beta:predictionHorizonSeconds:staleTimeoutSeconds:outlierThreshold:)``.
    public enum BuildError: Error, Equatable, Sendable {
        /// `alpha` liegt nicht in `(0, 1]` oder ist nicht endlich.
        case alphaOutOfRange(Double)
        /// `beta` liegt nicht in `(0, 1]` oder ist nicht endlich.
        case betaOutOfRange(Double)
        /// Der Vorhersagehorizont ist nicht positiv/endlich.
        case predictionHorizonNotPositive(Double)
        /// Die Stale-Grenze ist nicht positiv/endlich.
        case staleTimeoutNotPositive(Double)
        /// Der Vorhersagehorizont liegt über der Stale-Grenze -- eine
        /// Vorhersage jenseits des Zeitpunkts, ab dem der Ausgang
        /// ohnehin inaktiv ist, wäre nie erreichbar und damit ein
        /// Konfigurationsfehler, keine stillschweigend zu kürzende
        /// Angabe.
        case predictionHorizonExceedsStaleTimeout(horizon: Double, staleTimeout: Double)
        /// Der Ausreißergrenzwert ist nicht positiv/endlich.
        case outlierThresholdNotPositive(Double)
    }

    /// Öffentliche, validierende Fabrik (Muster wie `Frame.build`/
    /// `B0ScanProfile.build`/`Zone.build`) -- eine
    /// ``ControlValuePredictorConfiguration`` mit ungültigen Werten
    /// lässt sich strukturell nicht erzeugen, und kein ungültiger Wert
    /// wird still auf einen Default zurückgesetzt.
    public static func build(
        alpha: Double,
        beta: Double,
        predictionHorizonSeconds: Double,
        staleTimeoutSeconds: Double,
        outlierThreshold: Double
    ) throws -> ControlValuePredictorConfiguration {
        guard alpha.isFinite, alpha > 0, alpha <= 1 else {
            throw BuildError.alphaOutOfRange(alpha)
        }
        guard beta.isFinite, beta > 0, beta <= 1 else {
            throw BuildError.betaOutOfRange(beta)
        }
        guard predictionHorizonSeconds.isFinite, predictionHorizonSeconds > 0 else {
            throw BuildError.predictionHorizonNotPositive(predictionHorizonSeconds)
        }
        guard staleTimeoutSeconds.isFinite, staleTimeoutSeconds > 0 else {
            throw BuildError.staleTimeoutNotPositive(staleTimeoutSeconds)
        }
        guard predictionHorizonSeconds <= staleTimeoutSeconds else {
            throw BuildError.predictionHorizonExceedsStaleTimeout(
                horizon: predictionHorizonSeconds,
                staleTimeout: staleTimeoutSeconds
            )
        }
        guard outlierThreshold.isFinite, outlierThreshold > 0 else {
            throw BuildError.outlierThresholdNotPositive(outlierThreshold)
        }

        return ControlValuePredictorConfiguration(
            alpha: alpha,
            beta: beta,
            predictionHorizonSeconds: predictionHorizonSeconds,
            staleTimeoutSeconds: staleTimeoutSeconds,
            outlierThreshold: outlierThreshold
        )
    }

    /// Dokumentierter **Startwert**, keine abgeleitete Gerätewahrheit
    /// und kein eingemessenes Optimum (SICK-015-Auftrag 1.6/4.3):
    ///
    /// - `predictionHorizonSeconds = 0,06` -- Mitte des in der
    ///   SICK-008a-Owner-Leitplanke vorgegebenen Startbereichs
    ///   40–80 ms.
    /// - `staleTimeoutSeconds = 0,35` -- so gewählt, dass der bei
    ///   ≈ 4 Hz real beobachtete Abstand echter Profile (≈ 250 ms,
    ///   SICK-012-Mitschnitt) den Ausgang **nicht** abschaltet, ein
    ///   tatsächlich abreißender Strom aber innerhalb einer knappen
    ///   halben Sekunde inaktiv wird. Das ist eine Eigenschaft dieser
    ///   Konfiguration, **keine** Behauptung über eine Profilrate des
    ///   Geräts -- für andere Abstände (etwa die in der externen
    ///   Windows-Evidenz dokumentierten ≈ 12,5 Hz) ist der Wert
    ///   ausdrücklich zu konfigurieren, nicht fest verdrahtet.
    /// - `alpha = 0,5` / `beta = 0,1` -- moderate Positionsglättung bei
    ///   zurückhaltender Geschwindigkeitsnachführung; bewusst
    ///   konservativ, nicht eingemessen. **`alpha` glättet seit SICK-026
    ///   ausschließlich den Filterzustand, nicht den Ausgang**: Der
    ///   Ausgang von `estimate(at:)` verankert immer an der echten
    ///   Messung. `alpha` musste deshalb nicht auf `1` gezogen werden,
    ///   um den Rücksprung aus Befund H1 (`review-sick-025.md`) zu
    ///   beseitigen -- die Glättung bleibt erhalten, ohne hörbar zu
    ///   werden.
    /// - `outlierThreshold = 0,5` -- ein halber Vollausschlag Residuum.
    ///   Das Residuum ist der Abstand zur bereits
    ///   geschwindigkeits-korrigierten Vorhersage, nicht zum letzten
    ///   Messwert: eine gleichmäßige, auch schnelle Bewegung erzeugt
    ///   deshalb ein kleines Residuum, ein echter Sprung (andere
    ///   Fläche, Zonenwiedereintritt) ein großes.
    public static let startingPoint: ControlValuePredictorConfiguration = {
        // `try!` ist hier vertretbar und nicht die öffentliche Tür:
        // ausschließlich die oben dokumentierten, festen Literale --
        // schlägt es fehl, ist die Validierung selbst defekt, und das
        // soll sofort und laut auffallen statt still zu einem anderen
        // Wert zu werden.
        try! ControlValuePredictorConfiguration.build(
            alpha: 0.5,
            beta: 0.1,
            predictionHorizonSeconds: 0.06,
            staleTimeoutSeconds: 0.35,
            outlierThreshold: 0.5
        )
    }()
}
