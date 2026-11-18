/// Pure geometry. Tabs share a slot; stacked layouts account for width per row.
public struct WorkspaceLayout: Equatable, Sendable {
    public enum Area: String, CaseIterable, Sendable { case setup, field, layers, cell, channelStrip }
    public enum Mode: String, Sendable { case edit, perform }
    public enum InspectorTab: String, Sendable { case layers, cell }
    public enum Arrangement: Equatable, Sendable { case sideBySide, tabs, stacked }
    public struct Region: Equatable, Sendable {
        public let visible: Bool
        public let width: Double
        public let row: Int
        public let x: Double
    }
    public struct Row: Equatable, Sendable {
        public let areas: [Area]
        public let trailingSpace: Double
    }
    public struct Visibility: Equatable, Sendable {
        public var setup: Bool
        public var layers: Bool
        public var cell: Bool
        public var channelStrip: Bool
        public init(setup: Bool = true, layers: Bool = true, cell: Bool = true, channelStrip: Bool = true) {
            self.setup = setup; self.layers = layers; self.cell = cell; self.channelStrip = channelStrip
        }
        public subscript(_ area: Area) -> Bool {
            get {
                switch area {
                case .setup: return setup
                case .field: return true
                case .layers: return layers
                case .cell: return cell
                case .channelStrip: return channelStrip
                }
            }
            set {
                switch area {
                case .setup: setup = newValue
                case .field: break
                case .layers: layers = newValue
                case .cell: cell = newValue
                case .channelStrip: channelStrip = newValue
                }
            }
        }
    }
    public static let setupWidth: Double = 300
    public static let layersWidth: Double = 300
    public static let cellWidth: Double = 220
    public static let channelStripWidth: Double = 72
    public static let centerMinimumWidth: Double = 520
    public let arrangement: Arrangement
    public let usesInspectorTabs: Bool
    public let mode: Mode
    public let rows: [Row]
    private let regions: [Area: Region]
    public subscript(_ area: Area) -> Region { regions[area]! }

    public static func forAvailableWidth(_ availableWidth: Double,
        visibility: Visibility = .init(), mode: Mode = .edit,
        selectedTab: InspectorTab = .layers, channelCount: Int = 1) -> Self {
        let width = availableWidth.isFinite ? max(centerMinimumWidth, availableWidth) : centerMinimumWidth
        // Includes the sum strip. Narrow mixers scroll within their slot.
        let mixerWidth = channelStripWidth * Double(min(8, max(0, channelCount)) + 1)
        if mode == .perform {
            let stripWidth = min(mixerWidth, max(channelStripWidth, width - centerMinimumWidth))
            let totalWidth = max(width, centerMinimumWidth + stripWidth)
            let regions = Dictionary(uniqueKeysWithValues: Area.allCases.map { area in
                (area, Region(visible: area == .field || area == .channelStrip,
                    width: area == .field ? totalWidth - stripWidth : area == .channelStrip ? stripWidth : 0,
                    row: 0, x: area == .channelStrip ? totalWidth - stripWidth : 0))
            })
            return Self(arrangement: .sideBySide, usesInspectorTabs: false, mode: mode,
                rows: [Row(areas: [.field, .channelStrip], trailingSpace: 0)], regions: regions)
        }
        let setup = visibility.setup ? setupWidth : 0
        var strip = visibility.channelStrip ? min(mixerWidth, width) : 0
        let inspectors = (visibility.layers ? layersWidth : 0) + (visibility.cell ? cellWidth : 0)
        let tabs = visibility.layers && visibility.cell && width - setup - strip - inspectors < centerMinimumWidth
        let inspectorWidth = tabs ? layersWidth : inspectors
        let stacked = width - setup - strip - inspectorWidth < centerMinimumWidth
        if stacked && visibility.channelStrip {
            // Keep the mixer at the right of the secondary row. Its contents
            // scroll instead of pushing an eight-channel mixer below the UI.
            strip = min(strip, max(channelStripWidth, width - setup - inspectorWidth))
        }
        var regions = Dictionary(uniqueKeysWithValues: Area.allCases.map {
            ($0, Region(visible: false, width: 0, row: 0, x: 0))
        })
        var rows: [Row] = []
        var areas: [Area] = []
        var x: Double = 0
        var row = 0
        func place(_ area: Area, _ size: Double) {
            guard size > 0 else { return }
            regions[area] = Region(visible: true, width: size, row: row, x: x)
            areas.append(area); x += size
        }
        if stacked {
            place(.field, width)
            rows.append(Row(areas: areas, trailingSpace: 0))
            row = 1; areas = []; x = 0
        }
        place(.setup, setup)
        if !stacked { place(.field, width - setup - strip - inspectorWidth) }
        if tabs { place(selectedTab == .layers ? .layers : .cell, inspectorWidth) }
        else {
            place(.layers, visibility.layers ? layersWidth : 0)
            place(.cell, visibility.cell ? cellWidth : 0)
        }
        place(.channelStrip, strip)
        // Below the one-row minimum, wrap secondary slots as needed.
        if x > width {
            let pending = areas
            areas = []; x = 0
            for area in pending {
                let size = regions[area]!.width
                if x + size > width {
                    rows.append(Row(areas: areas, trailingSpace: width - x))
                    row += 1; areas = []; x = 0
                }
                place(area, size)
            }
        }
        rows.append(Row(areas: areas, trailingSpace: width - x))
        return Self(arrangement: stacked ? .stacked : tabs ? .tabs : .sideBySide,
            usesInspectorTabs: tabs, mode: mode, rows: rows, regions: regions)
    }
}
