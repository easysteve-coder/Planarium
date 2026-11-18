/// Zustandsbehaftete, aber reine Referenzmessung für einen gewählten Scanindex.
/// Ein Indexwechsel verwirft die bisherige Reihe ausdrücklich.
public struct ReferenceMeasurementModel: Equatable, Sendable {
    public enum ModelError: Error, Equatable, Sendable {
        case invalidIndex(Int)
    }

    public private(set) var selectedIndex: Int
    public private(set) var isRunning = false
    private var series: ReferenceIndexSeries

    public init(index: Int) throws {
        selectedIndex = try Self.validated(index)
        series = ReferenceIndexSeries(index: index)
    }

    public var statistics: ReferenceSeriesStatistics? {
        series.statistics()
    }

    public var profilesWithoutIndex: Int {
        series.profilesWithoutIndex
    }

    /// Startet eine neue Reihe; eine alte Reihe wird nie fortgesetzt.
    public mutating func start() {
        series = ReferenceIndexSeries(index: selectedIndex)
        isRunning = true
    }

    public mutating func stop() {
        isRunning = false
    }

    /// Wählt einen neuen Index und verwirft die bisherige Reihe.
    public mutating func selectIndex(_ index: Int) throws {
        selectedIndex = try Self.validated(index)
        series = ReferenceIndexSeries(index: index)
    }

    /// Einzige Prüfstelle des gültigen Indexbereichs; die Grenze selbst
    /// steht in `referenceIndexMaximum`.
    private static func validated(_ index: Int) throws -> Int {
        guard (0...referenceIndexMaximum).contains(index) else {
            throw ModelError.invalidIndex(index)
        }
        return index
    }

    public mutating func record(_ profile: B0ScanProfile) {
        guard isRunning else { return }
        series.record(profile)
    }
}
