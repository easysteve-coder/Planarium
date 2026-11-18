/// Polares Geräteraster `polarDeviceV2` in reiner Ganzzahlarithmetik.
///
/// Eine Zelladresse ist ein validiertes Paar `(ring, sector)`:
/// - Ring ist der unveränderte brauchbare Rohwert in Zentimetern.
/// - Sektor ist der Messstrahl-Tick 0…360, in jedem Ring.
///
/// Rohwert 0 bleibt unbrauchbar. Es gibt keine winkelabhängige
/// Vorzusammenfassung: Jeder Messstrahl behält seine eigene Zielzelle.
public struct PolarDeviceLattice: Equatable, Hashable, Sendable {

    /// Ringhöhe in Zentimetern (ein 1-cm-Quant).
    public static let ringQuantumCentimeters: Int = 1

    /// Größter Messpunktindex (361 Punkte: 0…360).
    public static let maxTick: Int = 360

    /// Größter Ring aus dem zulässigen Rohwertbereich.
    public static let maxRing: Int = Int(UsableRawDistance.highestRawValue) / ringQuantumCentimeters

    /// Ringindex `0…maxRing`.
    public let ring: Int

    /// Messstrahl-Tick `0…360`.
    public let sector: Int

    /// Erzeugt eine Adresse aus Messpunktindex und Rohdistanz.
    public init?(tick: Int, rawCentimeters: UInt16) {
        guard UsableRawDistance.contains(rawCentimeters),
              tick >= 0, tick <= Self.maxTick
        else { return nil }

        let ring = Int(rawCentimeters) / Self.ringQuantumCentimeters
        guard let value = Self.init(ring: ring, sector: tick) else { return nil }
        self = value
    }

    /// Erzeugt eine Adresse direkt aus Ring und Messstrahl-Tick.
    public init?(ring: Int, sector: Int) {
        guard ring >= 0, ring <= Self.maxRing,
              sector >= 0, sector <= Self.maxTick
        else { return nil }
        self.ring = ring
        self.sector = sector
    }

    /// Anzahl der Sektoren in jedem Ring.
    public static func sectorCount(forRing ring: Int) -> Int? {
        guard ring >= 0, ring <= maxRing else { return nil }
        return maxTick + 1
    }

    /// Ringindex für einen Zentimeterrohwert; `nil` bei unbrauchbarem Wert.
    public static func ring(forRawCentimeters raw: UInt16) -> Int? {
        guard UsableRawDistance.contains(raw) else { return nil }
        return Int(raw) / ringQuantumCentimeters
    }

    /// Sektorindex ist in v2 identisch mit dem Messstrahl-Tick.
    public static func sector(forTick tick: Int, inRing ring: Int) -> Int? {
        guard Self.init(ring: ring, sector: tick) != nil else { return nil }
        return tick
    }

    /// Peilung in Grad für Darstellung (Tick 0 = −90°, Tick 180 = 0°, Tick 360 = +90°).
    /// Keine Adressierung — reine Anzeige.
    public static func bearingDegrees(forTick tick: Int) -> Double {
        -90.0 + Double(tick) * 0.5
    }
}

extension PolarDeviceLattice: Codable {
    private enum CodingKeys: String, CodingKey { case ring, sector }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ring = try container.decode(Int.self, forKey: .ring)
        let sector = try container.decode(Int.self, forKey: .sector)
        guard let value = PolarDeviceLattice(ring: ring, sector: sector) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sector,
                in: container,
                debugDescription: "Cell (\(ring), \(sector)) is outside the device lattice"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ring, forKey: .ring)
        try container.encode(sector, forKey: .sector)
    }
}
