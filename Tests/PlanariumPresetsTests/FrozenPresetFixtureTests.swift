@testable import LegacyPresetTestSupport
import PlanariumDomain
import XCTest
import Foundation
import SickPLSCore
import SickPLSControlCore
import SickPLSMonitorKit
@testable import PlanariumPresets

/// M-0a: Dieser Test wird rot, wenn eine Migration die gespeicherte Zahl
/// still als neue Adresse deutet. Nicht `decode(encode(x)) == x` ist der
/// Beleg, sondern der physische Treffer auf dem 361-Punkt-Raster.
final class FrozenPresetFixtureTests: XCTestCase {

    private let paintedCell = PolarMetricGridCell(ring: 2, angularIndex: 8)

    // MARK: - E1: Der Beleg ist lesbar und unverändert

    func testE1_frozenPresetDecodesViaProductionPath() throws {
        let data = Data(FrozenPresetFixtures.polarVersion3.utf8)
        let preset = try PresetCodec.decode(data)

        XCTAssertEqual(preset.formatVersion, 3,
            "E1: Erwartet Formatversion 3.")

        guard let workspace = preset.spatialWorkspace else {
            XCTFail("E1: spatialWorkspace fehlt im dekodierten Preset.")
            return
        }
        XCTAssertEqual(workspace.grid.cellSizeMeters, 0.5,
            "E1: Erwartet grid.cellSizeMeters == 0.5.")

        let allPolarCells = workspace.layers.flatMap { $0.polarCells }
        XCTAssertEqual(allPolarCells.count, 1,
            "E1: Erwartet genau eine bemalte Polarzelle, erhalten \(allPolarCells.count).")
        XCTAssertEqual(Set(allPolarCells), [paintedCell],
            "E1: Die bemalte Zelle muss (ring: 2, angularIndex: 8) sein.")
    }

    // MARK: - E2: Die eine Zellaktion ist erhalten

    func testE2_cellActionIsPreserved() throws {
        let data = Data(FrozenPresetFixtures.polarVersion3.utf8)
        let preset = try PresetCodec.decode(data)

        guard let workspace = preset.spatialWorkspace else {
            XCTFail("E2: spatialWorkspace fehlt.")
            return
        }

        var foundActions: [SpatialCellAction] = []
        for layer in workspace.layers {
            if let actions = layer.polarCellOverrides[paintedCell] {
                foundActions.append(contentsOf: actions)
            }
        }

        XCTAssertEqual(foundActions.count, 1,
            "E2: Erwartet genau eine Aktion an der bemalten Zelle, erhalten \(foundActions.count).")

        guard let action = foundActions.first else { return }

        guard case .midiNote(let channel) = action.target else {
            XCTFail("E2: Erwartet midiNote-Ziel, erhalten: \(action.target)")
            return
        }
        XCTAssertEqual(channel, 0, "E2: Erwartet Kanal 0, erhalten \(channel).")

        guard case .note(let number, let velocity) = action.value else {
            XCTFail("E2: Erwartet note-Wert, erhalten: \(action.value)")
            return
        }
        XCTAssertEqual(number, 60, "E2: Erwartet MIDI-Note 60, erhalten \(number).")
        XCTAssertEqual(velocity, 100, "E2: Erwartet Velocity 100, erhalten \(velocity).")
    }

    // MARK: - E3: Physische Trefferwartung über den heutigen Adressweg

    private struct TableRow {
        let tick: Int
        let rawCentimeters: UInt16
        let expectedHit: Bool
    }

    private let table: [TableRow] = [
        .init(tick: 180, rawCentimeters: 100, expectedHit: true),
        .init(tick: 224, rawCentimeters: 149, expectedHit: true),
        .init(tick: 179, rawCentimeters: 120, expectedHit: false),
        .init(tick: 225, rawCentimeters: 120, expectedHit: false),
        .init(tick: 200, rawCentimeters: 99, expectedHit: false),
        // 151 statt 150: der Rohwert 150 liegt *genau* auf der Ringgrenze, und
        // dort adressiert der alte Weg falsch — siehe den Befundtest darunter.
        .init(tick: 200, rawCentimeters: 151, expectedHit: false),
    ]

    func testE3_physicalHitExpectation() throws {
        let data = Data(FrozenPresetFixtures.polarVersion3.utf8)
        let preset = try PresetCodec.decode(data)
        try assertHitTable(for: preset, label: "E3")
    }

    /// **Befund, am 28.09.2026 gemessen:** Der alte Adressweg entscheidet an der
    /// Ringgrenze per Gleitkomma falsch.
    ///
    /// Eine Messung von genau 150 cm bei Tick 200 müsste in Ring 3 liegen
    /// (`150 / 50 == 3`). Der Weg führt aber über einen kartesischen Punkt: aus
    /// `sin/cos` und `hypot` kommt `1.49999999999999978` zurück, und
    /// `floor(2.99999999999999956)` ergibt **2**. Die Messung landet also im
    /// Nachbarring.
    ///
    /// Dieser Test segnet den Fehler nicht ab — er nagelt ihn fest. Er ist die
    /// empirische Begründung des Ganzzahlgitters (`ROADMAP.md` Abschnitt 8b):
    /// `ring = rawCentimeters / 5` kennt diesen Grenzfall nicht. Nach dem Cutover
    /// muss dieser Test **umgeschrieben** werden, weil die Fehlwirkung dann
    /// verschwunden ist; verschwindet er still, ist der Beleg verloren.
    func testTheOldAddressPathMisplacesTheExactRingBoundary() throws {
        let data = Data(FrozenPresetFixtures.polarVersion3.utf8)
        let preset = try PresetCodec.decode(data)
        let workspace = try XCTUnwrap(preset.spatialWorkspace)
        let grid = workspace.grid

        let profile = try Self.makeProfile(tick: 200, rawCentimeters: 150)
        let point = try XCTUnwrap(MetricScanProjection().project(profile).first?.point)

        // Ganzzahlig wäre Ring 3. Der alte Weg liefert Ring 2.
        XCTAssertEqual(150 / 50, 3, "Ganzzahlig gehört 150 cm bei 50-cm-Ringen in Ring 3")
        XCTAssertEqual(PolarMetricGridCell(point: point, grid: grid).ring, 2,
                       "Gleitkomma verschiebt die Grenzmessung in den Nachbarring")
    }

    // MARK: - E5: Die Altform wird umgewandelt, nicht abgewiesen

    func testE5_cartesianPresetIsConvertedNotRejected() throws {
        let data = Data(FrozenPresetFixtures.cartesianVersion3.utf8)
        let preset = try PresetCodec.decode(data)

        XCTAssertEqual(preset.formatVersion, 3,
            "E5: Erwartet Formatversion 3.")

        guard let workspace = preset.spatialWorkspace else {
            XCTFail("E5: spatialWorkspace fehlt im dekodierten Preset.")
            return
        }
        XCTAssertEqual(workspace.grid.cellSizeMeters, 0.5,
            "E5: Erwartet grid.cellSizeMeters == 0.5.")
        XCTAssertEqual(workspace.coordinateMode, .polar,
            "E5: Erwartet coordinateMode == .polar.")

        let allPolarCells = workspace.layers.flatMap { $0.polarCells }
        XCTAssertEqual(allPolarCells.count, 1,
            "E5: Erwartet genau eine Polarzelle, erhalten \(allPolarCells.count).")
    }

    // MARK: - E6: Sie landet an der nachgemessenen Adresse

    func testE6_cartesianCellLandsAtExpectedPolarAddress() throws {
        let data = Data(FrozenPresetFixtures.cartesianVersion3.utf8)
        let preset = try PresetCodec.decode(data)

        guard let workspace = preset.spatialWorkspace else {
            XCTFail("E6: spatialWorkspace fehlt.")
            return
        }

        let allPolarCells = workspace.layers.flatMap { $0.polarCells }
        XCTAssertEqual(Set(allPolarCells), [paintedCell],
            "E6: Die migrierte Zelle muss (ring: 2, angularIndex: 8) sein, erhalten \(allPolarCells).")
    }

    // MARK: - E7: Die Zellaktion übersteht die Umwandlung

    func testE7_cellActionSurvivesCartesianMigration() throws {
        let data = Data(FrozenPresetFixtures.cartesianVersion3.utf8)
        let preset = try PresetCodec.decode(data)

        guard let workspace = preset.spatialWorkspace else {
            XCTFail("E7: spatialWorkspace fehlt.")
            return
        }

        var foundActions: [SpatialCellAction] = []
        for layer in workspace.layers {
            if let actions = layer.polarCellOverrides[paintedCell] {
                foundActions.append(contentsOf: actions)
            }
        }

        XCTAssertEqual(foundActions.count, 1,
            "E7: Erwartet genau eine Aktion an der migrierten Zelle, erhalten \(foundActions.count).")

        guard let action = foundActions.first else { return }

        guard case .midiNote(let channel) = action.target else {
            XCTFail("E7: Erwartet midiNote-Ziel, erhalten: \(action.target)")
            return
        }
        XCTAssertEqual(channel, 0, "E7: Erwartet Kanal 0, erhalten \(channel).")

        guard case .note(let number, let velocity) = action.value else {
            XCTFail("E7: Erwartet note-Wert, erhalten: \(action.value)")
            return
        }
        XCTAssertEqual(number, 60, "E7: Erwartet MIDI-Note 60, erhalten \(number).")
        XCTAssertEqual(velocity, 100, "E7: Erwartet Velocity 100, erhalten \(velocity).")
    }

    /// M-0: Der vollständige kartesische Bestand und seine Zellaktion erreichen das
    /// neue SpatialDocument ohne stillen Verlust.
    func testM0_cartesianFixtureImportsIntoSpatialDocument() throws {
        let preset = try PresetCodec.decode(Data(FrozenPresetFixtures.cartesianVersion3.utf8))
        let migratedData = try PresetCodec.encode(preset)
        guard case .success(let compatibility) = CompatibilityImporter.read(migratedData) else {
            return XCTFail("M-0: Kompatibilitätsimport muss erfolgreich sein")
        }
        guard case .success(let imported) = SpatialDocumentImporter.document(from: compatibility),
              let document = imported.document else {
            return XCTFail("M-0: SpatialDocument muss vorhanden sein")
        }
        XCTAssertTrue(imported.findings.isEmpty)
        XCTAssertEqual(document.layers.count, 1)
        XCTAssertEqual(document.layers[0].cells.count, 2250)
        XCTAssertEqual(document.layers[0].cellOverrides.count, 2250)
        XCTAssertEqual(document.layers[0].id, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let expected = SpatialCellAction(
            target: .midiNote(channel: 0), value: .note(number: 60, velocity: 100)
        )
        XCTAssertTrue(document.layers[0].cellOverrides.values.allSatisfy { $0 == [expected] })
        XCTAssertEqual(document.selectedLayerID, document.layers[0].id)
    }

    // MARK: - M-1b-c2: historische Format- und Raumachsen

    func testHistoricalV1BuildsTheSupervisorRoleStacksInFixedOrder() throws {
        let preset = try PresetCodec.decode(Data(FrozenPresetFixtures.historicalVersion1.utf8))

        XCTAssertEqual(preset.formatVersion, 3)
        XCTAssertEqual(preset.layers.map(\.role), ["pitch", "volume", "filter", "effectSend", "gate"])
        XCTAssertEqual(preset.layers.map(\.targetKind), ["discrete", "continuous", "discrete", "continuous", "gate"])
        XCTAssertEqual(preset.layers.map(\.zoneIDs), [
            [UUID(uuidString: "11111111-1111-1111-1111-111111111111")!],
            [UUID(uuidString: "22222222-2222-2222-2222-222222222222")!],
            [UUID(uuidString: "33333333-3333-3333-3333-333333333333")!],
            [],
            [UUID(uuidString: "44444444-4444-4444-4444-444444444444")!]
        ])
        XCTAssertEqual(preset.layers.map(\.mixRule), Array(repeating: "firstActive", count: 5))
        XCTAssertNil(preset.spatialWorkspace)
    }

    func testHistoricalV2StacksRemainUnchangedAndOtherContentMatchesV1() throws {
        let v1 = try PresetCodec.decode(Data(FrozenPresetFixtures.historicalVersion1.utf8))
        let v2 = try PresetCodec.decode(Data(FrozenPresetFixtures.historicalVersion2.utf8))

        XCTAssertEqual(v2, v1)
        XCTAssertEqual(v2.layers.map(\.role), ["pitch", "volume", "filter", "effectSend", "gate"])
        XCTAssertEqual(v2.layers.map(\.targetKind), ["discrete", "continuous", "discrete", "continuous", "gate"])
        XCTAssertNil(v2.spatialWorkspace)
    }

    func testHistoricalV1AndV2ReachCompatibilityAsNoSpatialInventory() throws {
        for (label, fixture) in [
            ("v1", FrozenPresetFixtures.historicalVersion1),
            ("v2", FrozenPresetFixtures.historicalVersion2)
        ] {
            let preset = try PresetCodec.decode(Data(fixture.utf8))
            let migratedData = try PresetCodec.encode(preset)
            let migratedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: migratedData) as? [String: Any])
            XCTAssertEqual(migratedJSON["formatVersion"] as? Int, 3, "\(label): keine Versionsmutation des Fixtures")
            XCTAssertNil(migratedJSON["spatialWorkspace"], "\(label): Raumfeld darf nicht erfunden werden")

            let imported = try CompatibilityImporter.read(migratedData).get()
            XCTAssertNil(imported.document, "\(label): kein Workspace bedeutet keinen Dokumentwert")
            XCTAssertEqual(imported.layers.count, 0, "\(label): kein räumlicher Bestand")
            XCTAssertEqual(imported.findings, [.noSpatialInventory], "\(label): erwarteter Status")
        }
    }

    func testHistoricalV1IsDeterministicAcrossTwoReads() throws {
        let data = Data(FrozenPresetFixtures.historicalVersion1.utf8)
        let first = try PresetCodec.decode(data)
        let second = try PresetCodec.decode(data)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try PresetCodec.encode(first), try PresetCodec.encode(second))
    }

    // MARK: - E8: Beide Belege beschreiben dieselbe physische Fläche

    /// E9: Dieser Test wird rot, wenn eine spätere Migration kartesische
    /// Altpresets verwirft, sie über eine andere Regel als den Mittelpunkt
    /// abbildet oder ihre Aktionen verliert.
    func testE8_cartesianPresetSatisfiesSameHitTable() throws {
        let data = Data(FrozenPresetFixtures.cartesianVersion3.utf8)
        let preset = try PresetCodec.decode(data)
        try assertHitTable(for: preset, label: "E8")
    }

    // MARK: - Hilfsfunktion

    /// Prüft die Trefferwartungstabelle gegen die bemalte Zelle, die aus dem
    /// dekodierten Dokument stammt. Die Zelle wird nicht aus einer Konstante
    /// genommen, sondern aus `spatialWorkspace.layers` extrahiert.
    private func assertHitTable(for preset: InstrumentPreset, label: String) throws {
        guard let workspace = preset.spatialWorkspace else {
            XCTFail("\(label): spatialWorkspace fehlt.")
            return
        }
        let grid = workspace.grid
        let projection = MetricScanProjection()

        let allPolarCells = workspace.layers.flatMap { $0.polarCells }
        guard allPolarCells.count == 1 else {
            XCTFail("\(label): Erwartet genau eine bemalte Zelle, erhalten \(allPolarCells.count).")
            return
        }
        let painted = allPolarCells.first!

        for row in table {
            let profile = try Self.makeProfile(tick: row.tick, rawCentimeters: row.rawCentimeters)
            let projected = projection.project(profile)

            XCTAssertEqual(projected.count, 1,
                "\(label): Tick \(row.tick), \(row.rawCentimeters) cm — erwartet genau 1 projizierten Punkt, erhalten \(projected.count).")

            guard let point = projected.first?.point else {
                XCTFail("\(label): Tick \(row.tick), \(row.rawCentimeters) cm — kein Punkt projiziert.")
                continue
            }

            let addressed = PolarMetricGridCell(point: point, grid: grid)
            let hit = (addressed == painted)

            if row.expectedHit {
                XCTAssertTrue(hit,
                    "\(label): Tick \(row.tick), \(row.rawCentimeters) cm — erwartet Treffer auf \(painted), erhalten \(addressed).")
            } else {
                XCTAssertFalse(hit,
                    "\(label): Tick \(row.tick), \(row.rawCentimeters) cm — erwartet KEIN Treffer, aber \(addressed) == \(painted).")
            }
        }
    }

    /// Baut ein 361-Punkt-Profil mit genau einer brauchbaren Messung
    /// am gegebenen Tick; alle anderen Positionen tragen Rohwert 0.
    private static func makeProfile(tick: Int, rawCentimeters: UInt16) throws -> B0ScanProfile {
        let count = 361
        var measurements: [B0ScanProfile.Measurement] = []
        measurements.reserveCapacity(count)
        for i in 0..<count {
            let value: UInt16 = (i == tick) ? rawCentimeters : 0
            measurements.append(try B0ScanProfile.Measurement.build(value: value, fieldFlags: 0))
        }
        return try B0ScanProfile.build(partialScanIndex: 0, measurements: measurements)
    }
}
