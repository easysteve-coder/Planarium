import SickPLSCore

/// Warum **kein** Kandidat angeboten wird, obwohl der Vorgang sauber
/// gelaufen ist. Eine Verweigerung ist ein **Ergebnis**, kein Fehler:
/// Der Accumulator hat gerechnet und festgestellt, dass die Zone nicht
/// sicher wäre.
public enum ZoneLearningRefusal: Equatable, Sendable {
    /// Es wurde zu früh abgeschlossen -- das Grundfenster ist noch nicht
    /// vollständig.
    case baselineIncomplete(seen: Int, required: Int)
    /// Kein Index hat die Persistenzschwelle erreicht, oder der stärkste
    /// Cluster ist kleiner als ``ZoneLearningConfiguration/minimumClusterPoints``.
    case insufficientMotion(largestClusterPoints: Int, required: Int)
    /// Zwei Cluster liegen innerhalb des Toleranzfaktors gleichauf.
    /// **Bewusst keine Auswahl nach Index** -- geraten wäre schlimmer als
    /// gefragt.
    case ambiguousCandidates(strongestHits: Int, runnerUpHits: Int)
    /// Der Hintergrund liegt im Wertebereich, den der Kandidat bräuchte:
    /// Das Objekt war nicht näher als der Hintergrund, oder der
    /// Sicherheitsabstand lässt keine Zone mit fachlicher Mindestspanne
    /// übrig. **Auflage D1** -- lieber keine Zone als eine dauerhaft
    /// aktive.
    case backgroundInsideZone
    /// Die geklammerten Grenzen ergaben keine gültige `Zone`.
    /// Struktureller Sicherheitsnetz-Fall.
    case candidateNotBuildable
}

/// Warum ein Lernvorgang **abgebrochen** wurde -- von außen, nicht durch
/// die Daten.
public enum ZoneLearningCancellation: Equatable, Sendable {
    /// Der Bedienende hat abgebrochen.
    case operatorCancelled
    /// Die Zielzone wurde entfernt.
    case zoneRemoved
    /// Die Rolle der Zielzone hat sich geändert.
    case zoneRoleChanged
    /// Die Zielzone wurde ein- oder ausgeschaltet.
    case zoneActivationChanged
    /// Die Scanner-Verbindung endete.
    case disconnected
}

/// Warum ein Lernvorgang durch die **Eingangsdaten** unbrauchbar wurde.
///
/// Getrennt von ``ZoneLearningRefusal``, weil beides verschiedene
/// Handgriffe verlangt: Eine Verweigerung heißt „anders hinstellen und
/// nochmal", ein Fehlschlag heißt „die Profile passen nicht zum Vorgang".
public enum ZoneLearningFailure: Equatable, Sendable {
    /// Die Punktzahl hat sich gegenüber dem ersten akzeptierten Profil
    /// geändert. Der Vorgang endet **sichtbar** -- die Indizes zweier
    /// Punktzahlen bedeuten nicht dasselbe.
    case pointCountChanged(expected: Int, received: Int)
    /// Ein Profil ohne Messpunkte kann weder Grundlage noch Bewegung sein.
    case emptyProfile
}

/// Der öffentliche Zustand eines Lernvorgangs. Der Fortschritt ist
/// **ausschließlich profilbasiert** -- keine versteckte Uhr, keine
/// Nebenläufigkeit, keine globale Variable.
public enum ZoneLearningState: Equatable, Sendable {
    /// Armiert, aber noch kein Profil gesehen.
    case arming
    /// Das Grundfenster wird gefüllt. `profilesSeen` ist hier immer
    /// **kleiner** als `required`: Sobald das Fenster voll ist, wechselt
    /// der Zustand sofort auf ``collectingMovement(profilesSeen:changedIndexCount:persistentIndexCount:)``
    /// -- „Grundprofil vollständig" ist kein eigener Wartezustand.
    case collectingBaseline(profilesSeen: Int, required: Int)
    /// Bewegung wird gesammelt. `persistentIndexCount` zählt die Indizes,
    /// die die Persistenzschwelle bereits erreicht haben.
    case collectingMovement(profilesSeen: Int, changedIndexCount: Int, persistentIndexCount: Int)
    /// Ein geprüfter Kandidat liegt vor. **Er ist noch nirgends
    /// geschrieben** -- das tut erst eine ausdrückliche Übernahme.
    case candidate(Zone)
    case refused(ZoneLearningRefusal)
    case cancelled(ZoneLearningCancellation)
    case failed(ZoneLearningFailure)
}

/// Leitet aus echten B0-Profilen eine Kandidatenzone ab (SICK-030c,
/// Befund **M6** und Auflage **D1** aus `review-sick-030-ui-delta.md`).
///
/// ## Was dieser Typ ist -- und was nicht
///
/// Ein **reiner Wert**: kein Scannerzugriff, keine Uhr, kein Timer, kein
/// Thread, keine globale Variable, kein Audio, kein Gate, kein MIDI, kein
/// SwiftUI. Profile werden **hineingereicht**; derselbe Vorgang mit
/// denselben Profilen ergibt immer dasselbe Ergebnis.
///
/// Er **schaltet nie eine Zone ein** und schreibt nie irgendwo hin. Sein
/// bestmögliches Ergebnis ist ein `Zone`-Wert im Zustand
/// ``ZoneLearningState/candidate(_:)`` — was damit geschieht, entscheidet
/// ausschließlich die Bedienung.
///
/// ## Der Ablauf
///
/// 1. **Grundfenster:** die ersten `baselineProfileCount` Profile bilden
///    je Index eine Hüllkurve aus Minimum und Maximum **aller gültigen**
///    Werte. Die Profile selbst werden aufgehoben, weil die
///    D1-Nachbedingung sie am Ende noch einmal braucht.
/// 2. **Bewegung:** ein Messwert zählt, wenn er gültig ist und die
///    Hüllkurve seines Index um mindestens `movementDelta` verlässt --
///    nach unten **oder** oben (richtungsneutral, Befund **N1**).
/// 3. **Persistenz und Cluster:** ein Index wird erst ab
///    `minimumPersistenceProfiles` Treffern brauchbar; brauchbare Indizes
///    werden mit `maximumIndexGap` zu Clustern gruppiert, der stärkste
///    nach Trefferzahl gewinnt, ein naher Gleichstand wird **verweigert**.
/// 4. **Kandidat:** Indexgrenzen aus dem Cluster plus Puffer,
///    Wertgrenzen aus den Bewegungswerten **an den persistenten Indizes
///    genau dieses Clusters** plus Puffer (SICK-030c1 -- ein verworfener
///    schwächerer Cluster weitet den Wertebereich nicht auf), Obergrenze
///    unter den kleinsten gültigen Grundwert im Bereich geklemmt -- und am
///    Ende die Nachbedingung.
///
/// ## Ungültige Messwerte und Flags
///
/// `0` und `8191` sind für Hüllkurve **und** Bewegungsstatistik ungültig
/// und werden ignoriert (die CLI zählt sie seit SICK-010 gesondert; ihre
/// physikalische Bedeutung ist offen). `fieldFlags` werden unverändert
/// mitgeführt und **nirgends gedeutet** -- ihre Bedeutung ist ⚪ offen,
/// und eine Deutung wäre eine Annahme über das Gerät.
///
/// ## Die D1-Nachbedingung, und warum sie über `Zone.evaluate` läuft
///
/// Ein fertiger Kandidat wird gegen **jedes** Profil des Grundfensters
/// mit dem **echten** ``Zone/evaluate(against:)`` geprüft und nur
/// angeboten, wenn er überall `.inactive` ist. Bewusst kein Nachbau der
/// Prüfung: `evaluate` kennt den Begriff „ungültiger Messwert" nicht --
/// ein `0`-Punkt im Indexbereich **würde** die Zone im Betrieb aktivieren,
/// obwohl die Statistik ihn ignoriert hat. Genau solche Fälle soll die
/// Nachbedingung fangen, und das kann sie nur, wenn sie dieselbe Funktion
/// benutzt, die später wirklich läuft.
public struct ZoneLearningAccumulator: Equatable, Sendable {

    public let configuration: ZoneLearningConfiguration
    /// Die Rolle, die ein Kandidat bekommt -- beim Armieren festgelegt.
    public let role: ZoneRole

    public private(set) var state: ZoneLearningState

    /// Die Punktzahl, die das erste akzeptierte Profil festgelegt hat.
    public private(set) var fixedPointCount: Int?

    /// Wie viele Profile insgesamt angenommen wurden (Grundfenster **und**
    /// Bewegung).
    public private(set) var profilesSeen = 0

    /// Die aufgehobenen Grundprofile -- begrenzt durch
    /// `baselineProfileCount`, gebraucht für die D1-Nachbedingung.
    private var baselineProfiles: [B0ScanProfile] = []
    /// Hüllkurve je Index; `nil` an Indizes ohne einen einzigen gültigen
    /// Grundwert.
    private var baselineEnvelope: [ClosedRange<UInt16>?] = []

    private var hitsByIndex: [Int: Int] = [:]
    /// Beobachtete Bewegungswerte **je Punktindex** (SICK-030c1).
    ///
    /// Bewusst nicht eine globale Spanne über alle Treffer: Gewinnt ein
    /// Cluster, während ein deutlich schwächerer -- und damit zu Recht
    /// nicht mehrdeutiger -- zweiter Cluster ganz andere Rohwerte trägt,
    /// wäre der Kandidat im Indexraum präzise, im Werteraum aber durch
    /// eine verworfene Bewegung aufgeweitet. Für Pitch und Volume ist das
    /// der Unterschied zwischen einem brauchbaren und einem beliebigen
    /// Lernergebnis.
    private var movementEnvelopeByIndex: [Int: ClosedRange<UInt16>] = [:]

    public init(role: ZoneRole, configuration: ZoneLearningConfiguration = .default) {
        self.role = role
        self.configuration = configuration
        self.state = .arming
    }

    /// Ob der Vorgang noch Profile annimmt.
    public var isCollecting: Bool {
        switch state {
        case .arming, .collectingBaseline, .collectingMovement: return true
        case .candidate, .refused, .cancelled, .failed: return false
        }
    }

    // MARK: - Profile hineinreichen

    /// Nimmt **ein vollständiges** echtes Profil an.
    ///
    /// Ein Profil in einem bereits beendeten Vorgang ist wirkungslos --
    /// ein einmal gefallenes Ergebnis wird nie stillschweigend
    /// überschrieben.
    public mutating func ingest(_ profile: B0ScanProfile) {
        guard isCollecting else { return }

        let count = profile.measurements.count
        guard count > 0 else {
            state = .failed(.emptyProfile)
            return
        }
        if let fixed = fixedPointCount {
            guard count == fixed else {
                state = .failed(.pointCountChanged(expected: fixed, received: count))
                return
            }
        } else {
            fixedPointCount = count
            baselineEnvelope = Array(repeating: nil, count: count)
        }

        profilesSeen += 1

        if baselineProfiles.count < configuration.baselineProfileCount {
            absorbIntoBaseline(profile)
        } else {
            absorbAsMovement(profile)
        }
        refreshCollectingState()
    }

    private mutating func absorbIntoBaseline(_ profile: B0ScanProfile) {
        for (index, measurement) in profile.measurements.enumerated() {
            guard Self.isValid(measurement.value) else { continue }
            if let existing = baselineEnvelope[index] {
                let lower = Swift.min(existing.lowerBound, measurement.value)
                let upper = Swift.max(existing.upperBound, measurement.value)
                baselineEnvelope[index] = lower...upper
            } else {
                baselineEnvelope[index] = measurement.value...measurement.value
            }
        }
        baselineProfiles.append(profile)
    }

    private mutating func absorbAsMovement(_ profile: B0ScanProfile) {
        for (index, measurement) in profile.measurements.enumerated() {
            guard Self.isValid(measurement.value) else { continue }
            // Ohne Hüllkurve gibt es an diesem Index nichts zu
            // vergleichen -- er kann deshalb nie ein Treffer werden.
            guard let envelope = baselineEnvelope[index] else { continue }
            guard isMovement(measurement.value, against: envelope) else { continue }

            hitsByIndex[index, default: 0] += 1
            if let existing = movementEnvelopeByIndex[index] {
                let lower = Swift.min(existing.lowerBound, measurement.value)
                let upper = Swift.max(existing.upperBound, measurement.value)
                movementEnvelopeByIndex[index] = lower...upper
            } else {
                movementEnvelopeByIndex[index] = measurement.value...measurement.value
            }
        }
    }

    /// Richtungsneutral, gegen die **gesamte** Hüllkurve des Fensters --
    /// nicht gegen einen zufälligen letzten Frame.
    private func isMovement(_ value: UInt16, against envelope: ClosedRange<UInt16>) -> Bool {
        let delta = Int(configuration.movementDelta)
        return Int(value) < Int(envelope.lowerBound) - delta
            || Int(value) > Int(envelope.upperBound) + delta
    }

    private mutating func refreshCollectingState() {
        if baselineProfiles.count < configuration.baselineProfileCount {
            state = .collectingBaseline(
                profilesSeen: baselineProfiles.count,
                required: configuration.baselineProfileCount
            )
        } else {
            state = .collectingMovement(
                profilesSeen: profilesSeen,
                changedIndexCount: hitsByIndex.count,
                persistentIndexCount: persistentIndices.count
            )
        }
    }

    // MARK: - Abschließen

    /// Beendet das Sammeln und berechnet das Ergebnis.
    ///
    /// **Es gibt keinen automatischen Abschluss** -- kein Timeout, keine
    /// Profilobergrenze. Ein Vorgang endet nur, weil jemand ihn beendet,
    /// abbricht, oder weil die Daten nicht mehr passen.
    public mutating func finish() {
        guard isCollecting else { return }
        state = evaluateCandidate()
    }

    /// Bricht den Vorgang mit benanntem Grund ab. Ein bereits gefallenes
    /// Ergebnis bleibt stehen.
    public mutating func cancel(_ reason: ZoneLearningCancellation) {
        guard isCollecting else { return }
        state = .cancelled(reason)
    }

    /// Der Kandidat, falls einer vorliegt -- sonst `nil`.
    public var candidate: Zone? {
        if case .candidate(let zone) = state { return zone }
        return nil
    }

    // MARK: - Die Rechnung

    /// Indizes, die die Persistenzschwelle erreicht haben, aufsteigend.
    private var persistentIndices: [Int] {
        hitsByIndex
            .filter { $0.value >= configuration.minimumPersistenceProfiles }
            .keys
            .sorted()
    }

    private func evaluateCandidate() -> ZoneLearningState {
        guard baselineProfiles.count >= configuration.baselineProfileCount else {
            return .refused(.baselineIncomplete(
                seen: baselineProfiles.count, required: configuration.baselineProfileCount
            ))
        }

        let clusters = Self.clusters(
            of: persistentIndices, maximumIndexGap: configuration.maximumIndexGap
        )
        let ranked = clusters
            .map { (indices: $0, hits: $0.reduce(0) { $0 + (hitsByIndex[$1] ?? 0) }) }
            .sorted { $0.hits > $1.hits }

        guard let strongest = ranked.first else {
            return .refused(.insufficientMotion(
                largestClusterPoints: 0, required: configuration.minimumClusterPoints
            ))
        }
        if ranked.count > 1 {
            let runnerUp = ranked[1]
            // Gleichauf heißt: Der Zweite erreicht mit dem Toleranzfaktor
            // den Ersten. Dann wird verweigert, **nie** nach Index geraten.
            if Double(runnerUp.hits) * configuration.ambiguityToleranceFactor >= Double(strongest.hits) {
                return .refused(.ambiguousCandidates(
                    strongestHits: strongest.hits, runnerUpHits: runnerUp.hits
                ))
            }
        }
        guard strongest.indices.count >= configuration.minimumClusterPoints else {
            return .refused(.insufficientMotion(
                largestClusterPoints: strongest.indices.count,
                required: configuration.minimumClusterPoints
            ))
        }
        // **SICK-030c1:** Die Wertgrenzen kommen ausschließlich aus den
        // Bewegungswerten an den persistenten Indizes **dieses** Clusters
        // -- nicht aus einer globalen Spanne über alle Treffer. Die
        // Polsterindizes tragen bewusst nichts bei: Sie haben die
        // Persistenzschwelle nicht erreicht und gehören deshalb nicht zur
        // gewählten Bewegung.
        guard
            let observed = movementEnvelope(overIndices: strongest.indices),
            let pointCount = fixedPointCount
        else {
            return .refused(.insufficientMotion(
                largestClusterPoints: strongest.indices.count,
                required: configuration.minimumClusterPoints
            ))
        }

        // --- Indexgrenzen: Cluster plus Puffer, in Punktindizes geklammert.
        let lowerPoint = Swift.max(0, (strongest.indices.first ?? 0) - configuration.indexPaddingPoints)
        let upperPoint = Swift.min(
            pointCount - 1, (strongest.indices.last ?? 0) + configuration.indexPaddingPoints
        )
        // **Die geteilte Formel** (Befund M5) -- dieselbe, die
        // `Zone.evaluate` benutzt. Keine zweite Indexrechnung.
        let indexLower = Zone.indexFraction(forIndex: lowerPoint, count: pointCount)
        let indexUpper = Zone.indexFraction(forIndex: upperPoint, count: pointCount)

        // --- Wertgrenzen: beobachtete Bewegung plus Puffer.
        let padding = Int(configuration.valuePadding)
        var valueLower = Swift.max(0, Int(observed.lowerBound) - padding)
        var valueUpper = Swift.min(Int(Zone.maxRawMeasurementValue), Int(observed.upperBound) + padding)

        // --- Auflage D1, erste Hälfte: unter den kleinsten gültigen
        // Grundwert im Indexbereich klemmen. Gibt es dort überhaupt
        // keinen gültigen Grundwert, ist nichts zu unterbieten.
        if let backgroundMinimum = baselineMinimum(fromPoint: lowerPoint, toPoint: upperPoint) {
            let ceiling = Int(backgroundMinimum) - Int(configuration.backgroundClearance)
            guard ceiling > valueLower else { return .refused(.backgroundInsideZone) }
            valueUpper = Swift.min(valueUpper, ceiling)
        }
        guard valueUpper > valueLower else { return .refused(.backgroundInsideZone) }
        // Fachliche Mindestspanne des Rohwertbereichs.
        if valueUpper - valueLower < 1 {
            valueLower = Swift.max(0, valueUpper - 1)
            guard valueUpper > valueLower else { return .refused(.backgroundInsideZone) }
        }

        guard let zone = try? Zone.build(
            indexLowerBound: indexLower,
            indexUpperBound: indexUpper,
            valueLowerBound: UInt16(valueLower),
            valueUpperBound: UInt16(valueUpper),
            role: role
        ) else {
            return .refused(.candidateNotBuildable)
        }

        // --- Auflage D1, zweite Hälfte: die Nachbedingung gegen **jedes**
        // Grundprofil, mit der echten Auswertung.
        for profile in baselineProfiles where zone.evaluate(against: profile) != .inactive {
            return .refused(.backgroundInsideZone)
        }

        return .candidate(zone)
    }

    /// Spanne der beobachteten Bewegungswerte über genau die übergebenen
    /// Punktindizes (SICK-030c1). `nil`, wenn dort keiner liegt --
    /// struktureller Sicherheitsnetz-Fall, denn ein persistenter Index hat
    /// mindestens einen Treffer und damit mindestens einen Wert.
    private func movementEnvelope(overIndices indices: [Int]) -> ClosedRange<UInt16>? {
        var lower: UInt16?
        var upper: UInt16?
        for index in indices {
            guard let envelope = movementEnvelopeByIndex[index] else { continue }
            lower = Swift.min(lower ?? envelope.lowerBound, envelope.lowerBound)
            upper = Swift.max(upper ?? envelope.upperBound, envelope.upperBound)
        }
        guard let lower, let upper else { return nil }
        return lower...upper
    }

    /// Kleinster gültiger Grundwert über **alle** Profile des Fensters in
    /// diesem Punktindexbereich.
    private func baselineMinimum(fromPoint lower: Int, toPoint upper: Int) -> UInt16? {
        var minimum: UInt16?
        for point in lower...upper {
            guard point < baselineEnvelope.count, let envelope = baselineEnvelope[point] else { continue }
            minimum = Swift.min(minimum ?? envelope.lowerBound, envelope.lowerBound)
        }
        return minimum
    }

    /// Gruppiert aufsteigende Indizes zu Clustern. `maximumIndexGap` ist
    /// die Zahl der **fehlenden** Indizes, die eine Gruppe noch
    /// überbrückt.
    static func clusters(of indices: [Int], maximumIndexGap: Int) -> [[Int]] {
        guard !indices.isEmpty else { return [] }
        var result: [[Int]] = []
        var current = [indices[0]]
        for index in indices.dropFirst() {
            let missing = index - (current.last ?? index) - 1
            if missing <= maximumIndexGap {
                current.append(index)
            } else {
                result.append(current)
                current = [index]
            }
        }
        result.append(current)
        return result
    }

    /// `0` und `8191` sind für jede Statistik dieses Vorgangs ungültig.
    static func isValid(_ value: UInt16) -> Bool {
        value != 0 && value != Zone.maxRawMeasurementValue
    }
}
