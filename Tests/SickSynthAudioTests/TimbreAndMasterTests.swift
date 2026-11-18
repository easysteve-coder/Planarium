@testable import LegacyPresetTestSupport
import PlanariumDomain
// TimbreAndMasterTests.swift
//
// SICK-030b3: die Klangfarbenauswahl und der Masterpegel.
//
// Alles ohne Audiogerät gegen `FakeAudioOutputHost`. Geprüft wird, was
// sich ohne Gerät ehrlich prüfen lässt: die Werte selbst, wohin sie
// gehen, wohin sie **nicht** gehen, und dass keiner der beiden Wege
// etwas startet.

import XCTest
@testable import PlanariumPresets

final class TimbreAndMasterTests: XCTestCase {

    // MARK: - Hilfen

    // MARK: - Der Klangfarbenvertrag

    // MARK: - Der Klangfarbenweg durch den Dienst

    // MARK: - Der Masterpegelvertrag

    /// Ungültige Pegel werden **sichtbar abgelehnt**, nicht still
    /// zurechtgebogen.
    func testTheMasterRejectsNonFiniteAndOutOfRangeValues() {
        for invalid in [Float.nan, .infinity, -.infinity, -0.1, 1.1, 42] {
            XCTAssertThrowsError(try MasterLevel.build(gain: invalid)) { error in
                guard case MasterLevel.BuildError.gainOutOfRange(let reported) = error else {
                    return XCTFail("Erwartet: gainOutOfRange, bekommen: \(error)")
                }
                if invalid.isNaN {
                    XCTAssertTrue(reported.isNaN)
                } else {
                    XCTAssertEqual(reported, invalid)
                }
            }
        }
    }

    func testTheMasterAcceptsTheWholeDocumentedRange() throws {
        for step in 0...100 {
            let gain = Float(step) / 100
            XCTAssertEqual(try MasterLevel.build(gain: gain).gain, gain)
        }
    }

    /// Der Startwert lässt bewusst Luft: Der Hauptmischer summiert
    /// trockenes Signal und beide Sends.
    func testTheStartingMasterLeavesHeadroom() {
        XCTAssertEqual(MasterLevel.startingPoint.gain, 0.8)
        XCTAssertLessThan(MasterLevel.startingPoint.gain, MasterLevel.unity.gain)
        XCTAssertEqual(MasterLevel.unity.gain, 1)
        XCTAssertTrue(MasterLevel.silent.isSilent)
        XCTAssertFalse(MasterLevel.startingPoint.isSilent)
    }

    /// Ein frischer Dienst reicht seinen Startpegel an den Host — ohne
    /// dabei irgendetwas zu starten.


    /// **Der Master geht an den Host und nirgendwo sonst hin.**
    ///
    /// Er darf den Stimmensnapshot nicht berühren: Dort läge er vor den
    /// Effekten und würde den Hall mitdämpfen, statt die Summe zu regeln
    /// — und er würde die Scannerlautstärke verfälschen.




    /// Ein Masterwechsel startet nichts — auch nicht in Serie.


    /// **Vor `start()` gesetzt heißt: beim Start wirksam.**


    /// Ein eingestellter Master überlebt Stopp und Neustart — wie die
    /// Effektwerte auch.


    /// Während laufender Ausgabe bleibt der Master eine reine
    /// Wertänderung: kein Umbau, kein Neustart, kein Stopp.


    // MARK: - Der Master liegt hinter allem (Graphplan)

    /// **Der Hauptmischer ist der Endpunkt — für jede Racklänge.**
    ///
    /// Damit ist belegt, wo der Masterpegel logisch liegt: Er sitzt auf
    /// dem einzigen Knoten, in den jeder Weg mündet, und damit hinter
    /// Stimme, externem Rack und beiden internen Sends. Ohne
    /// Audiogerät ist das die ehrlichste mögliche Aussage — geprüft wird
    /// die Topologie, nicht Apples Mischerarithmetik.


    /// Mit aktivem Rack liegt der Master hinter dessen letztem Eintrag:
    /// Die Kette führt in die Auffächerung, die Auffächerung in den
    /// Hauptmischer.

}
