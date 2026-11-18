import Foundation
import PlanariumDomain

/// Mac-local presentation preferences, intentionally outside the preset.
public struct WorkspacePreferences: Equatable, Codable, Sendable {
    public var collapsedLayerGroups: [String: Set<String>] = [:]
    public var setup = true
    public var layers = true
    public var cell = true
    public var channelStrip = true
    public var selectedTab = WorkspaceLayout.InspectorTab.layers.rawValue
    public var scannerFlagBits = false
    public var buttonLabels = true
    public var fieldToolbarLabels: Bool {
        get { buttonLabels }
        set { buttonLabels = newValue }
    }
    public var clockDirection: ClockDirection = .off
    public var clockSendEnabled: Bool {
        get { clockDirection == .send }
        set { clockDirection = newValue ? .send : .off }
    }
    public var clockSourceID: Int32?
    public var clockSourceName: String?
    public var clockTargetIDs: [Int32] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case collapsedLayerGroups, setup, layers, cell, channelStrip, selectedTab, scannerFlagBits, buttonLabels, clockDirection, clockSourceID, clockSourceName, clockTargetIDs }
    private enum LegacyKeys: String, CodingKey { case clockSendEnabled }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        collapsedLayerGroups = try values.decodeIfPresent([String: Set<String>].self, forKey: .collapsedLayerGroups) ?? [:]
        setup = try values.decode(Bool.self, forKey: .setup)
        layers = try values.decode(Bool.self, forKey: .layers)
        cell = try values.decode(Bool.self, forKey: .cell)
        channelStrip = try values.decode(Bool.self, forKey: .channelStrip)
        selectedTab = try values.decode(String.self, forKey: .selectedTab)
        scannerFlagBits = try values.decodeIfPresent(Bool.self, forKey: .scannerFlagBits) ?? false
        buttonLabels = try values.decodeIfPresent(Bool.self, forKey: .buttonLabels) ?? true
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        clockDirection = try values.decodeIfPresent(ClockDirection.self, forKey: .clockDirection)
            ?? ((try legacy.decodeIfPresent(Bool.self, forKey: .clockSendEnabled) ?? false) ? .send : .off)
        clockSourceID = try values.decodeIfPresent(Int32.self, forKey: .clockSourceID)
        clockSourceName = try values.decodeIfPresent(String.self, forKey: .clockSourceName)
        clockTargetIDs = try values.decodeIfPresent([Int32].self, forKey: .clockTargetIDs) ?? []
    }
    public var visibility: WorkspaceLayout.Visibility {
        .init(setup: setup, layers: layers, cell: cell, channelStrip: channelStrip)
    }
    public var inspectorTab: WorkspaceLayout.InspectorTab {
        WorkspaceLayout.InspectorTab(rawValue: selectedTab) ?? .layers
    }
}
public enum WorkspacePreferenceStore {
    public static let key = "de.planarium.workspace.v1.preferences"
    public static func load(from defaults: UserDefaults) -> WorkspacePreferences {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(WorkspacePreferences.self, from: data),
              WorkspaceLayout.InspectorTab(rawValue: value.selectedTab) != nil else { return .init() }
        return value
    }
    public static func save(_ value: WorkspacePreferences, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
