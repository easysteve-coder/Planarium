import XCTest
import SickPLSCore
@testable import SickPLSControlCore

/// SICK-030c: der reine Learn-Accumulator, ausschließlich mit
/// synthetischen Profilen — kein Gerät, keine Uhr, kein Thread.
///
/// **Das Szenario aller Tests:** ein ruhiger Hintergrund bei Rohwert
/// `3000`, davor eine „Hand" als Wertsenke (deutlich kleinerer Rohwert)
/// über einige benachbarte Indizes. Das entspricht der
/// Richtungsannahme, die `Zone.evaluate` ohnehin trifft („kleinster
/// Rohwert gewinnt", Befund N1) — der Accumulator selbst reagiert
/// richtungsneutral, was ein eigener Test belegt.
final class ZoneLearningAccumulatorTests: XCTestCase {

    private let pointCount = 24
    private let background: UInt16 = 3000

    // MARK: - Profilbau

    private func profile(_ values: [UInt16]) throws -> B0ScanProfile {
        try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: try values.map { try B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0) }
        )
    }

    /// Ruhiger Hintergrund; `overrides` setzt einzelne Punktindizes.
    private func scene(_ overrides: [Int: UInt16] = [:], count: Int? = nil) throws -> B0ScanProfile {
        let n = count ?? pointCount
        var values = Array(repeating: background, count: n)
        for (index, value) in overrides { values[index] = value }
        return try profile(values)
    }

    private func configuration(
        baselineProfileCount: Int = 3,
        minimumPersistenceProfiles: Int = 2,
        minimumClusterPoints: Int = 3,
        maximumIndexGap: Int = 1,
        movementDelta: UInt16 = 40,
        indexPaddingPoints: Int = 1,
        valuePadding: UInt16 = 20,
        backgroundClearance: UInt16 = 30,
        ambiguityToleranceFactor: Double = 1.25
    ) throws -> ZoneLearningConfiguration {
        try ZoneLearningConfiguration.build(
            baselineProfileCount: baselineProfileCount,
            minimumPersistenceProfiles: minimumPersistenceProfiles,
            minimumClusterPoints: minimumClusterPoints,
            maximumIndexGap: maximumIndexGap,
            movementDelta: movementDelta,
            indexPaddingPoints: indexPaddingPoints,
            valuePadding: valuePadding,
            backgroundClearance: backgroundClearance,
            ambiguityToleranceFactor: ambiguityToleranceFactor
        )
    }

    /// Ein vollständiger Lauf: Grundprofile, dann Bewegungsprofile, dann
    /// abschließen.
    private func run(
        baseline: [B0ScanProfile],
        movement: [B0ScanProfile],
        role: ZoneRole = .gate,
        configuration: ZoneLearningConfiguration
    ) -> ZoneLearningAccumulator {
        var accumulator = ZoneLearningAccumulator(role: role, configuration: configuration)
        for profile in baseline + movement { accumulator.ingest(profile) }
        accumulator.finish()
        return accumulator
    }

    private func learnedZone(
        _ accumulator: ZoneLearningAccumulator,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Zone {
        guard case .candidate(let zone) = accumulator.state else {
            XCTFail("Erwartet: Kandidat, bekommen: \(accumulator.state)", file: file, line: line)
            throw XCTSkip("siehe vorherigen Fehlschlag")
        }
        return zone
    }

    // MARK: - Fortschritt ist profilbasiert

    func testAFreshAccumulatorIsArmingAndHasSeenNothing() throws {
        let accumulator = ZoneLearningAccumulator(role: .pitch, configuration: try configuration())

        XCTAssertEqual(accumulator.state, .arming)
        XCTAssertEqual(accumulator.profilesSeen, 0)
        XCTAssertNil(accumulator.fixedPointCount)
        XCTAssertNil(accumulator.candidate)
        XCTAssertTrue(accumulator.isCollecting)
    }

    func testTheStateReportsBaselineThenMovementProgressInProfiles() throws {
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: try configuration())

        accumulator.ingest(try scene())
        XCTAssertEqual(accumulator.state, .collectingBaseline(profilesSeen: 1, required: 3))
        accumulator.ingest(try scene())
        XCTAssertEqual(accumulator.state, .collectingBaseline(profilesSeen: 2, required: 3))
        accumulator.ingest(try scene())
        XCTAssertEqual(
            accumulator.state,
            .collectingMovement(profilesSeen: 3, changedIndexCount: 0, persistentIndexCount: 0),
            "Sobald das Fenster voll ist, sammelt der Vorgang Bewegung -- ohne Zwischenschritt"
        )

        accumulator.ingest(try scene([10: 500, 11: 500, 12: 500]))
        XCTAssertEqual(
            accumulator.state,
            .collectingMovement(profilesSeen: 4, changedIndexCount: 3, persistentIndexCount: 0),
            "Nach einem Bewegungsprofil ist noch kein Index persistent"
        )
        accumulator.ingest(try scene([10: 500, 11: 500, 12: 500]))
        XCTAssertEqual(
            accumulator.state,
            .collectingMovement(profilesSeen: 5, changedIndexCount: 3, persistentIndexCount: 3)
        )
    }

    /// Es gibt **keinen** automatischen Abschluss — beliebig viele
    /// Profile beenden den Vorgang nicht von selbst.
    func testCollectingNeverEndsOnItsOwn() throws {
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: try configuration())
        for _ in 0..<200 { accumulator.ingest(try scene([10: 500, 11: 500, 12: 500])) }

        XCTAssertTrue(accumulator.isCollecting, "Kein Timeout, keine Profilobergrenze")
        XCTAssertNil(accumulator.candidate)
    }

    // MARK: - Das Grundprofil ist ein Fenster, nicht der letzte Frame

    /// Der Hintergrund schwankt über das Fenster zwischen 2900 und 3100.
    /// Ein Wert von 2950 liegt **innerhalb** dieser Hüllkurve und ist
    /// deshalb keine Bewegung — obwohl er vom *letzten* Grundframe (3100)
    /// um 150 abweicht.
    func testMovementIsMeasuredAgainstTheWholeBaselineWindowNotTheLastFrame() throws {
        let configuration = try configuration(movementDelta: 40)
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: configuration)

        accumulator.ingest(try scene([10: 2900, 11: 2900, 12: 2900]))
        accumulator.ingest(try scene([10: 3000, 11: 3000, 12: 3000]))
        accumulator.ingest(try scene([10: 3100, 11: 3100, 12: 3100]))

        for _ in 0..<5 { accumulator.ingest(try scene([10: 2950, 11: 2950, 12: 2950])) }
        accumulator.finish()

        XCTAssertEqual(
            accumulator.state,
            .refused(.insufficientMotion(largestClusterPoints: 0, required: 3)),
            "2950 liegt in der Hüllkurve 2900...3100 — gegen den letzten Frame allein wäre es „Bewegung\""
        )
    }

    func testAValueOutsideTheEnvelopeByLessThanTheDeltaIsNotMovement() throws {
        let configuration = try configuration(movementDelta: 100)
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: configuration)
        for _ in 0..<3 { accumulator.ingest(try scene()) }
        for _ in 0..<5 { accumulator.ingest(try scene([10: 2950, 11: 2950, 12: 2950])) }
        accumulator.finish()

        XCTAssertEqual(accumulator.state, .refused(.insufficientMotion(largestClusterPoints: 0, required: 3)))
    }

    /// Richtungsneutral (Befund **N1**): auch ein Wert **über** der
    /// Hüllkurve ist Bewegung.
    func testMovementIsDetectedInBothDirections() throws {
        let configuration = try configuration()
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: configuration)
        for _ in 0..<3 { accumulator.ingest(try scene()) }
        for _ in 0..<5 { accumulator.ingest(try scene([10: 5000, 11: 5000, 12: 5000])) }

        guard case .collectingMovement(_, let changed, let persistent) = accumulator.state else {
            return XCTFail("Erwartet: Bewegungssammlung, bekommen: \(accumulator.state)")
        }
        XCTAssertEqual(changed, 3)
        XCTAssertEqual(persistent, 3)
    }

    // MARK: - Ungültige Messwerte

    /// `0` und `8191` zählen weder in die Hüllkurve noch als Bewegung.
    func testZeroAndMaximumAreIgnoredInBaselineAndMovement() throws {
        let configuration = try configuration()
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: configuration)

        // Index 5 hat im Grundfenster **nur** ungültige Werte -> keine
        // Hüllkurve -> er kann nie ein Treffer werden.
        for _ in 0..<3 { accumulator.ingest(try scene([5: 0])) }
        // Index 7 bekommt ungültige „Bewegung", Index 10...12 echte.
        for _ in 0..<5 {
            accumulator.ingest(try scene([5: 8191, 7: 0, 10: 500, 11: 500, 12: 500]))
        }

        guard case .collectingMovement(_, let changed, _) = accumulator.state else {
            return XCTFail("Erwartet: Bewegungssammlung, bekommen: \(accumulator.state)")
        }
        XCTAssertEqual(changed, 3, "Nur 10, 11 und 12 — nicht 5 (keine Hüllkurve) und nicht 7 (Wert 0)")
    }

    func testAnIndexWithoutAnyValidBaselineValueNeverBecomesAHit() throws {
        let configuration = try configuration(minimumClusterPoints: 1)
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: configuration)
        for _ in 0..<3 { accumulator.ingest(try scene([9: 0])) }
        for _ in 0..<5 { accumulator.ingest(try scene([9: 500])) }
        accumulator.finish()

        XCTAssertEqual(
            accumulator.state, .refused(.insufficientMotion(largestClusterPoints: 0, required: 1)),
            "Ohne Hüllkurve gibt es nichts, wogegen 500 „verändert\" wäre"
        )
    }

    // MARK: - Persistenz

    /// Eine einzelne Rauschspitze erreicht die Persistenzschwelle nicht.
    func testASingleNoiseSpikeNeverBecomesACandidate() throws {
        let configuration = try configuration(minimumPersistenceProfiles: 3)
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: configuration)
        for _ in 0..<3 { accumulator.ingest(try scene()) }
        // Jedes Profil eine Spitze an einem **anderen** Index.
        for index in 6...14 { accumulator.ingest(try scene([index: 400])) }
        accumulator.finish()

        XCTAssertEqual(
            accumulator.state, .refused(.insufficientMotion(largestClusterPoints: 0, required: 3)),
            "Neun Einzeltreffer sind kein Kandidat"
        )
    }

    func testPersistentMovementCountsAndTheThresholdIsInclusive() throws {
        let configuration = try configuration(minimumPersistenceProfiles: 3)
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: configuration)
        for _ in 0..<3 { accumulator.ingest(try scene()) }

        for profileIndex in 1...3 {
            accumulator.ingest(try scene([10: 500, 11: 500, 12: 500]))
            guard case .collectingMovement(_, _, let persistent) = accumulator.state else {
                return XCTFail("Erwartet: Bewegungssammlung")
            }
            XCTAssertEqual(
                persistent, profileIndex == 3 ? 3 : 0,
                "Genau ab dem dritten Treffer brauchbar, nicht davor"
            )
        }
    }

    // MARK: - Cluster

    func testClustersBridgeExactlyTheConfiguredGapAndNoMore() {
        XCTAssertEqual(
            ZoneLearningAccumulator.clusters(of: [3, 4, 5], maximumIndexGap: 0), [[3, 4, 5]]
        )
        XCTAssertEqual(
            ZoneLearningAccumulator.clusters(of: [3, 5], maximumIndexGap: 0), [[3], [5]],
            "Ein fehlender Index trennt bei Lückentoleranz 0"
        )
        XCTAssertEqual(
            ZoneLearningAccumulator.clusters(of: [3, 5], maximumIndexGap: 1), [[3, 5]],
            "Ein fehlender Index wird bei Toleranz 1 überbrückt"
        )
        XCTAssertEqual(
            ZoneLearningAccumulator.clusters(of: [3, 6], maximumIndexGap: 1), [[3], [6]],
            "Zwei fehlende Indizes nicht mehr"
        )
        XCTAssertEqual(ZoneLearningAccumulator.clusters(of: [], maximumIndexGap: 1), [])
        XCTAssertEqual(ZoneLearningAccumulator.clusters(of: [7], maximumIndexGap: 1), [[7]])
    }

    func testAClusterSmallerThanTheMinimumIsRefused() throws {
        let configuration = try configuration(minimumClusterPoints: 4)
        let baseline = try (0..<3).map { _ in try scene() }
        let movement = try (0..<5).map { _ in try scene([10: 500, 11: 500, 12: 500]) }

        let accumulator = run(baseline: baseline, movement: movement, configuration: configuration)

        XCTAssertEqual(
            accumulator.state, .refused(.insufficientMotion(largestClusterPoints: 3, required: 4))
        )
    }

    /// Zwei gleich starke Cluster werden **verweigert**, nicht nach Index
    /// entschieden.
    func testTwoEquallyStrongClustersAreRefusedAsAmbiguous() throws {
        let configuration = try configuration()
        let baseline = try (0..<3).map { _ in try scene() }
        let movement = try (0..<5).map { _ in
            try scene([4: 500, 5: 500, 6: 500, 16: 500, 17: 500, 18: 500])
        }

        let accumulator = run(baseline: baseline, movement: movement, configuration: configuration)

        XCTAssertEqual(
            accumulator.state, .refused(.ambiguousCandidates(strongestHits: 15, runnerUpHits: 15))
        )
    }

    /// Ein deutlich schwächerer zweiter Cluster ist **keine**
    /// Mehrdeutigkeit.
    func testAClearlyWeakerSecondClusterDoesNotBlockTheCandidate() throws {
        let configuration = try configuration(ambiguityToleranceFactor: 1.25)
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: configuration)
        for _ in 0..<3 { accumulator.ingest(try scene()) }
        // Starker Cluster: 5 Profile x 4 Indizes = 20 Treffer.
        // Schwacher: 3 Profile x 3 Indizes = 9 Treffer. 9 * 1,25 < 20.
        for profileIndex in 0..<5 {
            var overrides: [Int: UInt16] = [4: 500, 5: 500, 6: 500, 7: 500]
            if profileIndex < 3 {
                overrides[16] = 500; overrides[17] = 500; overrides[18] = 500
            }
            accumulator.ingest(try scene(overrides))
        }
        accumulator.finish()

        let zone = try learnedZone(accumulator)
        XCTAssertLessThan(zone.indexRange.upperBound, 0.5, "Der starke Cluster liegt links")
    }

    // MARK: - Punktzahl

    func testTheFirstAcceptedProfileFixesThePointCount() throws {
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: try configuration())
        accumulator.ingest(try scene(count: 24))

        XCTAssertEqual(accumulator.fixedPointCount, 24)
    }

    func testADifferentPointCountEndsTheRunVisiblyAndLeavesItUnchanged() throws {
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: try configuration())
        for _ in 0..<3 { accumulator.ingest(try scene(count: 24)) }
        for _ in 0..<3 { accumulator.ingest(try scene([10: 500, 11: 500, 12: 500], count: 24)) }
        let before = accumulator

        accumulator.ingest(try scene(count: 36))

        XCTAssertEqual(accumulator.state, .failed(.pointCountChanged(expected: 24, received: 36)))
        XCTAssertEqual(accumulator.profilesSeen, before.profilesSeen, "Das Profil wurde nicht gezählt")
        XCTAssertFalse(accumulator.isCollecting)
    }

    func testAnEmptyProfileEndsTheRun() throws {
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: try configuration())
        accumulator.ingest(try profile([]))

        XCTAssertEqual(accumulator.state, .failed(.emptyProfile))
    }

    func testProfilesAfterTheEndAreIgnored() throws {
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: try configuration())
        accumulator.ingest(try profile([]))
        let ended = accumulator

        accumulator.ingest(try scene())
        accumulator.finish()
        accumulator.cancel(.operatorCancelled)

        XCTAssertEqual(accumulator, ended, "Ein gefallenes Ergebnis wird nie überschrieben")
    }

    // MARK: - Abbruch

    func testCancelRecordsItsReasonAndStopsCollecting() throws {
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: try configuration())
        accumulator.ingest(try scene())
        accumulator.cancel(.zoneRemoved)

        XCTAssertEqual(accumulator.state, .cancelled(.zoneRemoved))
        XCTAssertFalse(accumulator.isCollecting)
    }

    func testFinishingBeforeTheBaselineIsCompleteIsRefusedNotGuessed() throws {
        var accumulator = ZoneLearningAccumulator(role: .gate, configuration: try configuration())
        accumulator.ingest(try scene())
        accumulator.finish()

        XCTAssertEqual(accumulator.state, .refused(.baselineIncomplete(seen: 1, required: 3)))
    }

    // MARK: - Der Kandidat

    func testASuccessfulRunProducesAValidZoneWithTheArmedRole() throws {
        let configuration = try configuration()
        let baseline = try (0..<3).map { _ in try scene() }
        let movement = try (0..<5).map { _ in try scene([10: 500, 11: 500, 12: 500]) }

        let accumulator = run(
            baseline: baseline, movement: movement, role: .volume, configuration: configuration
        )
        let zone = try learnedZone(accumulator)

        XCTAssertEqual(zone.role, .volume, "Die beim Armieren festgelegte Rolle")
        XCTAssertLessThan(zone.indexRange.lowerBound, zone.indexRange.upperBound)
        XCTAssertLessThan(zone.valueRange.lowerBound, zone.valueRange.upperBound)
        XCTAssertGreaterThanOrEqual(zone.indexRange.lowerBound, 0)
        XCTAssertLessThanOrEqual(zone.indexRange.upperBound, 1)
        XCTAssertEqual(accumulator.candidate, zone)
    }

    /// Die Indexgrenzen folgen dem Cluster plus Puffer — und benutzen
    /// **dieselbe** Formel wie `Zone.evaluate` (Befund **M5**).
    func testTheIndexBoundsFollowTheClusterPlusPaddingUsingTheSharedFormula() throws {
        let configuration = try configuration(indexPaddingPoints: 1)
        let baseline = try (0..<3).map { _ in try scene() }
        let movement = try (0..<5).map { _ in try scene([10: 500, 11: 500, 12: 500]) }

        let zone = try learnedZone(
            run(baseline: baseline, movement: movement, configuration: configuration)
        )

        XCTAssertEqual(
            zone.indexRange.lowerBound,
            Zone.indexFraction(forIndex: 9, count: pointCount), accuracy: 1e-12
        )
        XCTAssertEqual(
            zone.indexRange.upperBound,
            Zone.indexFraction(forIndex: 13, count: pointCount), accuracy: 1e-12
        )
    }

    func testTheIndexPaddingIsClampedAtBothEndsOfTheProfile() throws {
        let configuration = try configuration(indexPaddingPoints: 3)
        let baseline = try (0..<3).map { _ in try scene() }
        let movement = try (0..<5).map { _ in try scene([0: 500, 1: 500, 2: 500]) }

        let zone = try learnedZone(
            run(baseline: baseline, movement: movement, configuration: configuration)
        )

        XCTAssertEqual(zone.indexRange.lowerBound, 0, "Kein Index unter 0")
    }

    func testTheValueBoundsFollowTheObservedMovementPlusPadding() throws {
        let configuration = try configuration(valuePadding: 20, backgroundClearance: 30)
        let baseline = try (0..<3).map { _ in try scene() }
        let movement = try [UInt16(500), 600, 550, 700, 520].map {
            try scene([10: $0, 11: $0, 12: $0])
        }

        let zone = try learnedZone(
            run(baseline: baseline, movement: movement, configuration: configuration)
        )

        XCTAssertEqual(zone.valueRange.lowerBound, 480, "500 - 20")
        XCTAssertEqual(zone.valueRange.upperBound, 720, "700 + 20, unter 3000 - 30")
    }

    // MARK: - Auflage D1

    /// Die Wertobergrenze wird unter den kleinsten gültigen Grundwert im
    /// Indexbereich geklemmt.
    func testTheUpperValueBoundIsClampedBelowTheBackgroundMinimum() throws {
        let configuration = try configuration(valuePadding: 500, backgroundClearance: 30)
        let baseline = try (0..<3).map { _ in try scene() }
        let movement = try (0..<5).map { _ in try scene([10: 2800, 11: 2800, 12: 2800]) }

        let zone = try learnedZone(
            run(baseline: baseline, movement: movement, configuration: configuration)
        )

        XCTAssertEqual(
            zone.valueRange.upperBound, 2970,
            "2800 + 500 wäre 3300 und läge über dem Hintergrund — geklemmt auf 3000 - 30"
        )
    }

    /// **Die Kernbedingung von D1:** Der Kandidat ist gegen **jedes**
    /// Profil des Grundfensters inaktiv, geprüft mit der echten
    /// Auswertung.
    func testTheCandidateIsInactiveAgainstEveryBaselineProfile() throws {
        let configuration = try configuration()
        // Ein Hintergrund, der über das Fenster schwankt.
        let baseline = try [UInt16(2900), 3000, 3100].map { value in
            try profile(Array(repeating: value, count: pointCount))
        }
        let movement = try (0..<5).map { _ in try scene([10: 500, 11: 500, 12: 500]) }

        let accumulator = run(baseline: baseline, movement: movement, configuration: configuration)
        let zone = try learnedZone(accumulator)

        for (index, baselineProfile) in baseline.enumerated() {
            XCTAssertEqual(
                zone.evaluate(against: baselineProfile), .inactive,
                "Grundprofil \(index) darf die gelernte Zone nicht aktivieren"
            )
        }
    }

    /// Steht der Hintergrund im Indexbereich **näher** als die Bewegung
    /// (Tischkante, Stativ), lässt sich keine sichere Zone bilden — und
    /// es wird keine gebaut.
    func testABackgroundCloserThanTheMovementIsRefused() throws {
        let configuration = try configuration()
        // Index 11 hat einen dauerhaft sehr nahen Hintergrundpunkt.
        let baseline = try (0..<3).map { _ in try scene([11: 200]) }
        let movement = try (0..<5).map { _ in try scene([10: 500, 12: 500, 13: 500]) }

        let accumulator = run(baseline: baseline, movement: movement, configuration: configuration)

        XCTAssertEqual(accumulator.state, .refused(.backgroundInsideZone))
        XCTAssertNil(accumulator.candidate, "Lieber keine Zone als eine dauerhaft aktive")
    }

    /// Ein ungültiger Grundpunkt (`0`) im Indexbereich zählt zwar nicht in
    /// die Statistik, **würde** die Zone im Betrieb aber aktivieren —
    /// `Zone.evaluate` kennt „ungültig" nicht. Genau dafür läuft die
    /// Nachbedingung über die echte Auswertung.
    func testABaselinePointInsideTheZoneIsCaughtByThePostcondition() throws {
        let configuration = try configuration(valuePadding: 600)
        let baseline = try (0..<3).map { _ in try scene([11: 1]) }
        let movement = try (0..<5).map { _ in try scene([10: 500, 12: 500, 13: 500]) }

        let accumulator = run(baseline: baseline, movement: movement, configuration: configuration)

        XCTAssertEqual(
            accumulator.state, .refused(.backgroundInsideZone),
            "Wertuntergrenze 500-600 -> 0; der brauchbare Grundpunkt 1 liegt in der Zone"
        )
    }

    // MARK: - SICK-030c1: Wertgrenzen nur aus dem gewählten Cluster

    /// Ein starker Cluster (fünf Profile × drei Indizes bei `500`) und ein
    /// klar schwächerer, deshalb **zulässiger** zweiter Cluster (drei
    /// Profile × drei Indizes bei `2500`): Der Kandidat gehört dem starken
    /// Cluster — und seine **Wertgrenzen** dürfen ausschließlich aus
    /// dessen Bewegungswerten kommen.
    ///
    /// Vorher sammelte der Accumulator Minimum und Maximum **global** über
    /// alle Treffer; der Kandidat war dann im Indexraum präzise, im
    /// Werteraum aber durch die verworfene Bewegung bis `2520`
    /// aufgeweitet. Für Pitch und Volume ist das der Unterschied zwischen
    /// einem brauchbaren und einem beliebigen Lernergebnis.
    func testValueBoundsComeOnlyFromTheSelectedCluster() throws {
        let configuration = try configuration()
        let baseline = try (0..<3).map { _ in try scene() }
        // 3 × 5 = 15 Treffer gegen 3 × 3 = 9 — mit Toleranzfaktor 1,25
        // erreicht der Zweite den Ersten nicht, also kein Gleichstand.
        let strong = try (0..<5).map { _ in try scene([4: 500, 5: 500, 6: 500]) }
        let weak = try (0..<3).map { _ in try scene([16: 2500, 17: 2500, 18: 2500]) }

        let accumulator = run(
            baseline: baseline, movement: strong + weak, configuration: configuration
        )
        let zone = try learnedZone(accumulator)

        XCTAssertEqual(zone.valueRange.lowerBound, 480, "500 − Puffer 20")
        XCTAssertEqual(
            zone.valueRange.upperBound, 520,
            "500 + Puffer 20 — der verworfene Cluster bei 2500 weitet nichts auf"
        )
        // Und der Indexraum gehört unverändert dem starken Cluster:
        // Punkte 4...6 plus je ein Polsterpunkt.
        XCTAssertEqual(zone.indexRange.lowerBound, Zone.indexFraction(forIndex: 3, count: pointCount))
        XCTAssertEqual(zone.indexRange.upperBound, Zone.indexFraction(forIndex: 7, count: pointCount))
    }

    /// Dieselbe Lage, aber die schwache Bewegungsgruppe liegt **dicht am
    /// Hintergrund** (`2900` gegen `3000`). Mit der alten globalen
    /// Sammlung reichte der Kandidat bis `2920` — knapp unter den
    /// Sicherheitsabstand und damit an D1 vorbei, ohne ihn formal zu
    /// verletzen. Die Wertgrenzen bleiben jetzt beim gewählten Cluster,
    /// und die Nachbedingung gilt unverändert.
    func testAWeakMovementGroupOutsideTheClusterDoesNotStretchTowardsTheBackground() throws {
        let configuration = try configuration()
        let baseline = try (0..<3).map { _ in try scene() }
        let strong = try (0..<5).map { _ in try scene([4: 500, 5: 500, 6: 500]) }
        let weak = try (0..<3).map { _ in try scene([16: 2900, 17: 2900, 18: 2900]) }

        let accumulator = run(
            baseline: baseline, movement: strong + weak, configuration: configuration
        )
        let zone = try learnedZone(accumulator)

        XCTAssertEqual(zone.valueRange.upperBound, 520)
        XCTAssertLessThan(
            Int(zone.valueRange.upperBound), 2900 - Int(configuration.backgroundClearance),
            "Die verworfene Gruppe zieht den Kandidaten nicht an den Hintergrund heran"
        )
        for (index, baselineProfile) in baseline.enumerated() {
            XCTAssertEqual(
                zone.evaluate(against: baselineProfile), .inactive,
                "Grundprofil \(index): die D1-Nachbedingung gilt unverändert"
            )
        }
    }

    /// Auch ein **nicht persistenter** Index darf nichts beitragen — nicht
    /// einmal einer, der mitten im Cluster liegt.
    ///
    /// Index 11 hat genau einen Treffer bei `2500` und verfehlt die
    /// Persistenzschwelle; die Lückentoleranz überbrückt ihn beim
    /// Gruppieren trotzdem, er gehört also zum **Indexbereich** des
    /// Clusters, aber nicht zu seinen persistenten Indizes. Für die
    /// Wertgrenzen zählen ausschließlich Letztere.
    func testANonPersistentIndexInsideTheClusterSpanContributesNoValues() throws {
        let configuration = try configuration()
        let baseline = try (0..<3).map { _ in try scene() }
        var movement = [try scene([10: 500, 11: 2500, 12: 500, 13: 500, 14: 500])]
        movement += try (0..<4).map { _ in try scene([10: 500, 12: 500, 13: 500, 14: 500]) }

        let accumulator = run(baseline: baseline, movement: movement, configuration: configuration)
        let zone = try learnedZone(accumulator)

        XCTAssertEqual(zone.valueRange.lowerBound, 480)
        XCTAssertEqual(
            zone.valueRange.upperBound, 520,
            "Der einmalige Treffer bei 2500 hat die Persistenzschwelle nicht erreicht"
        )
        XCTAssertEqual(
            zone.indexRange.lowerBound, Zone.indexFraction(forIndex: 9, count: pointCount),
            "Der Indexbereich überbrückt Index 11 weiterhin"
        )
        XCTAssertEqual(zone.indexRange.upperBound, Zone.indexFraction(forIndex: 15, count: pointCount))
    }

    /// Der schwächere Cluster **bleibt** eine erkannte Bewegung — er wird
    /// nur nicht gewählt. Kehrt man die Stärken um, gewinnt er, und dann
    /// kommen die Wertgrenzen aus **seinen** Werten.
    func testTheOtherClusterWinsWithItsOwnValuesWhenItIsTheStrongerOne() throws {
        let configuration = try configuration()
        let baseline = try (0..<3).map { _ in try scene() }
        let few = try (0..<3).map { _ in try scene([4: 500, 5: 500, 6: 500]) }
        let many = try (0..<5).map { _ in try scene([16: 2500, 17: 2500, 18: 2500]) }

        let accumulator = run(
            baseline: baseline, movement: few + many, configuration: configuration
        )
        let zone = try learnedZone(accumulator)

        XCTAssertEqual(zone.valueRange.lowerBound, 2480, "2500 − Puffer 20")
        XCTAssertEqual(zone.valueRange.upperBound, 2520, "2500 + Puffer 20, nicht 520")
        XCTAssertEqual(zone.indexRange.lowerBound, Zone.indexFraction(forIndex: 15, count: pointCount))
        XCTAssertEqual(zone.indexRange.upperBound, Zone.indexFraction(forIndex: 19, count: pointCount))
    }
}
