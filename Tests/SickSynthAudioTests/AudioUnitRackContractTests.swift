@testable import LegacyPresetTestSupport
import PlanariumDomain
// AudioUnitRackContractTests.swift
//
// SICK-019: der Auswahl- und Sicherheitsvertrag für das
// Audio-Unit-Effekt-Rack.
//
// Alles läuft gegen einen Fake-Katalog. Es wird **keine** Komponente
// geladen, instanziiert oder ausgeführt — das ist der Kern des
// Vertrags, nicht nur eine Testbequemlichkeit.

import AudioToolbox
import XCTest

@testable import PlanariumPresets

/// Ein vollständig gesteuerter Komponentenlieferant ohne System.
final class FakeAudioUnitComponentSource: AudioUnitComponentSource {
    var descriptions: [AudioUnitComponentDescription] = []
    var instrumentDescriptions: [AudioUnitComponentDescription] = []
    private(set) var queryCount = 0

    func effectComponentDescriptions() -> [AudioUnitComponentDescription] {
        queryCount += 1
        return descriptions
    }
    func instrumentComponentDescriptions() -> [AudioUnitComponentDescription] { instrumentDescriptions }
}

final class AudioUnitRackContractTests: XCTestCase {

    // MARK: - Hilfen

    private let effectType = AudioUnitIdentity.effectComponentType

    private func makeDescription(
        subType: String,
        manufacturer: String,
        name: String,
        manufacturerName: String,
        type: UInt32? = nil,
        isSandboxSafe: Bool = true
    ) -> AudioUnitComponentDescription {
        AudioUnitComponentDescription(
            componentType: type ?? effectType,
            componentSubType: FourCharacterCode.make(subType) ?? 0,
            componentManufacturer: FourCharacterCode.make(manufacturer) ?? 0,
            name: name,
            manufacturerName: manufacturerName,
            isSandboxSafe: isSandboxSafe
        )
    }

    /// Vier unterscheidbare, druckbare ASCII-Zeichen je Index.
    private static func distinctSubType(_ index: Int) -> String {
        String(format: "fx%02d", index)
    }

    private func makeIdentity(_ subType: String, _ manufacturer: String) throws
        -> AudioUnitIdentity
    {
        try AudioUnitIdentity.build(
            componentType: effectType,
            componentSubType: XCTUnwrap(FourCharacterCode.make(subType)),
            componentManufacturer: XCTUnwrap(FourCharacterCode.make(manufacturer))
        )
    }

    // MARK: - Vierbuchstabenkennungen

    func testFourCharacterCodeRoundTrips() {
        let code = FourCharacterCode.make("aufx")
        XCTAssertNotNil(code)
        XCTAssertEqual(FourCharacterCode.text(of: code!), "aufx")
    }

    func testFourCharacterCodeRejectsWrongLengthOrNonAscii() {
        XCTAssertNil(FourCharacterCode.make(""))
        XCTAssertNil(FourCharacterCode.make("auf"))
        XCTAssertNil(FourCharacterCode.make("aufxx"))
        XCTAssertNil(FourCharacterCode.make("auf\u{00E4}"))
    }

    func testUnprintableBytesAreShownSafelyInsteadOfLeakingRawBytes() {
        XCTAssertEqual(FourCharacterCode.text(of: 0x0000_0000), "????")
    }

    func testOurEffectTypeConstantMatchesApplesValue() {
        // Der Wertvertrag ist framework-frei und trägt die Kennung
        // deshalb als eigene Konstante. Dieser Test pinnt sie an Apples
        // Wert -- sonst könnte sie unbemerkt auseinanderlaufen.
        XCTAssertEqual(AudioUnitIdentity.effectComponentType, UInt32(kAudioUnitType_Effect))
        XCTAssertEqual(FourCharacterCode.text(of: AudioUnitIdentity.effectComponentType), "aufx")
    }

    func testInstrumentCatalogAcceptsOnlyMusicDevicesWithoutLoadingThem() throws {
        let source = FakeAudioUnitComponentSource()
        source.instrumentDescriptions = [
            makeDescription(subType: "syny", manufacturer: "appl", name: "Synth Y", manufacturerName: "Apple", type: UInt32(kAudioUnitType_MusicDevice)),
            makeDescription(subType: "dely", manufacturer: "appl", name: "Not an Instrument", manufacturerName: "Apple")
        ]

        let instruments = AudioUnitEffectCatalog(source: source).availableInstruments()
        XCTAssertEqual(AudioUnitInstrumentIdentity.componentType, UInt32(kAudioUnitType_MusicDevice))
        XCTAssertEqual(instruments.map(\.name), ["Synth Y"])
        XCTAssertEqual(instruments.first?.identity.displayCode, "aumu/syny/appl")
    }

    // MARK: - Identität

    func testValidEffectIdentityIsAccepted() throws {
        let identity = try makeIdentity("dely", "appl")

        XCTAssertEqual(identity.componentType, effectType)
        XCTAssertEqual(identity.displayCode, "aufx/dely/appl")
    }

    func testNonEffectComponentTypesAreRejected() throws {
        // Ein Musikeffekt (`aumf`) erwartet MIDI -- das gibt es hier
        // nicht, also wird er ausdrücklich abgelehnt statt so
        // aufgenommen, als könnten wir ihn bedienen.
        let musicEffect = try XCTUnwrap(FourCharacterCode.make("aumf"))
        let generator = try XCTUnwrap(FourCharacterCode.make("augn"))

        for type in [musicEffect, generator, UInt32(0)] {
            XCTAssertThrowsError(
                try AudioUnitIdentity.build(
                    componentType: type,
                    componentSubType: 1,
                    componentManufacturer: 1
                )
            ) { error in
                XCTAssertEqual(
                    error as? AudioUnitIdentity.BuildError,
                    .notAnEffectComponent(type)
                )
            }
        }
    }

    func testIncompleteIdentitiesAreRejected() {
        XCTAssertThrowsError(
            try AudioUnitIdentity.build(
                componentType: effectType,
                componentSubType: 0,
                componentManufacturer: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioUnitIdentity.BuildError,
                .incompleteIdentity(subType: 0, manufacturer: 1)
            )
        }
        XCTAssertThrowsError(
            try AudioUnitIdentity.build(
                componentType: effectType,
                componentSubType: 1,
                componentManufacturer: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioUnitIdentity.BuildError,
                .incompleteIdentity(subType: 1, manufacturer: 0)
            )
        }
    }

    // MARK: - Katalog: Filterung

    func testCatalogKeepsOnlyPureEffects() throws {
        let source = FakeAudioUnitComponentSource()
        source.descriptions = [
            makeDescription(subType: "dely", manufacturer: "appl", name: "Delay", manufacturerName: "Apple"),
            makeDescription(
                subType: "syn1", manufacturer: "abcd", name: "Synth", manufacturerName: "Abc",
                type: FourCharacterCode.make("aumu")
            ),
            makeDescription(
                subType: "mfx1", manufacturer: "abcd", name: "MidiFx", manufacturerName: "Abc",
                type: FourCharacterCode.make("aumf")
            )
        ]

        let catalog = AudioUnitEffectCatalog(source: source)
        let effects = catalog.availableEffects()

        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects.first?.name, "Delay")
        XCTAssertEqual(source.queryCount, 1)
    }

    func testCatalogDropsEntriesWithoutAUniqueIdentity() {
        let source = FakeAudioUnitComponentSource()
        source.descriptions = [
            makeDescription(subType: "dely", manufacturer: "appl", name: "Gut", manufacturerName: "Apple"),
            AudioUnitComponentDescription(
                componentType: effectType,
                componentSubType: 0,
                componentManufacturer: 1,
                name: "Ohne Subtyp",
                manufacturerName: "Apple",
                isSandboxSafe: true
            ),
            AudioUnitComponentDescription(
                componentType: effectType,
                componentSubType: 1,
                componentManufacturer: 0,
                name: "Ohne Hersteller",
                manufacturerName: "Apple",
                isSandboxSafe: true
            )
        ]

        let effects = AudioUnitEffectCatalog(source: source).availableEffects()

        // Ein einzelner unbrauchbarer Eintrag darf den Katalog nicht
        // leeren -- der brauchbare bleibt.
        XCTAssertEqual(effects.map(\.name), ["Gut"])
    }

    func testCatalogDropsDuplicateIdentitiesKeepingTheFirst() {
        let source = FakeAudioUnitComponentSource()
        source.descriptions = [
            makeDescription(subType: "dely", manufacturer: "appl", name: "Erster", manufacturerName: "Apple"),
            makeDescription(subType: "dely", manufacturer: "appl", name: "Zweiter", manufacturerName: "Apple")
        ]

        let effects = AudioUnitEffectCatalog(source: source).availableEffects()

        XCTAssertEqual(effects.map(\.name), ["Erster"])
    }

    func testAnEmptySystemIsAValidStateAndNotAnError() {
        let source = FakeAudioUnitComponentSource()
        source.descriptions = []

        XCTAssertEqual(AudioUnitEffectCatalog(source: source).availableEffects(), [])
    }

    // MARK: - Katalog: Sortierung

    func testCatalogSortsByManufacturerThenNameCaseInsensitively() {
        let descriptions = [
            makeDescription(subType: "c001", manufacturer: "zzzz", name: "Zeta", manufacturerName: "Zylinder"),
            makeDescription(subType: "c002", manufacturer: "aaaa", name: "beta", manufacturerName: "apfel"),
            makeDescription(subType: "c003", manufacturer: "bbbb", name: "Alpha", manufacturerName: "Apfel")
        ]

        let effects = AudioUnitEffectCatalog.candidates(from: descriptions)

        XCTAssertEqual(effects.map(\.name), ["Alpha", "beta", "Zeta"])
    }

    func testSortingIsStableForEqualKeys() {
        // Gleicher Hersteller **und** gleicher Name: die Reihenfolge der
        // Quelle muss erhalten bleiben. `Array.sort` sichert das in
        // Swift nicht zu -- deshalb sortiert der Katalog von Hand mit
        // mitgeführtem Ursprungsindex.
        let descriptions = (0..<12).map { index in
            makeDescription(
                subType: Self.distinctSubType(index),
                manufacturer: "same",
                name: "Gleicher Name",
                manufacturerName: "Gleicher Hersteller"
            )
        }

        let effects = AudioUnitEffectCatalog.candidates(from: descriptions)

        XCTAssertEqual(effects.count, descriptions.count)
        XCTAssertEqual(
            effects.map(\.identity.componentSubType),
            descriptions.map(\.componentSubType),
            "gleiche Schlüssel müssen die Reihenfolge der Quelle behalten"
        )
    }

    func testConversionCarriesTheMetadataThrough() throws {
        let descriptions = [
            makeDescription(
                subType: "dely", manufacturer: "appl",
                name: "AUDelay", manufacturerName: "Apple",
                isSandboxSafe: false
            )
        ]

        let candidate = try XCTUnwrap(AudioUnitEffectCatalog.candidates(from: descriptions).first)

        XCTAssertEqual(candidate.name, "AUDelay")
        XCTAssertEqual(candidate.manufacturerName, "Apple")
        XCTAssertFalse(candidate.isSandboxSafe, "Sandbox-Angabe wird roh durchgereicht")
        XCTAssertEqual(candidate.identity.displayCode, "aufx/dely/appl")
    }

    func testCatalogIsPureAndRepeatable() {
        let source = FakeAudioUnitComponentSource()
        source.descriptions = [
            makeDescription(subType: "c001", manufacturer: "aaaa", name: "B", manufacturerName: "M"),
            makeDescription(subType: "c002", manufacturer: "aaaa", name: "A", manufacturerName: "M")
        ]
        let catalog = AudioUnitEffectCatalog(source: source)

        XCTAssertEqual(catalog.availableEffects(), catalog.availableEffects())
    }

    // MARK: - Rack-Auswahl

    func testEmptySelectionIsTheNeutralStartingPoint() {
        let empty = EffectRackSelection.empty

        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.entries, [])
    }

    func testOrderedSelectionKeepsItsOrder() throws {
        let first = try makeIdentity("aaaa", "mfr1")
        let second = try makeIdentity("bbbb", "mfr1")
        let third = try makeIdentity("cccc", "mfr2")

        let selection = try EffectRackSelection.build(entries: [third, first, second])

        XCTAssertEqual(selection.entries, [third, first, second])
        XCTAssertEqual(selection.count, 3)
    }

    func testDuplicateEntriesAreRejected() throws {
        let identity = try makeIdentity("dely", "appl")
        let other = try makeIdentity("rvrb", "appl")

        XCTAssertThrowsError(
            try EffectRackSelection.build(entries: [identity, other, identity])
        ) { error in
            XCTAssertEqual(
                error as? EffectRackSelection.BuildError,
                .duplicateEntry(identity)
            )
        }
    }

    func testADeepRackIsAcceptedWithoutAnArbitrarySlotLimit() throws {
        let entries = try (0..<32).map { index in
            try makeIdentity(Self.distinctSubType(index), "mfr1")
        }
        let selection = try EffectRackSelection.build(entries: entries)
        XCTAssertEqual(selection.entries, entries)
        XCTAssertEqual(selection.count, 32)
    }

    // MARK: - Die Sicherheitsgrenze: Auswählen führt nichts aus








}
