import Combine
import Foundation
import PlanariumDomain
import PlanariumInput
import SickPLSMonitorKit
import PlanariumApplication
import PlanariumPresets

/// Shared production actions for menu commands and their keyboard equivalents.
/// The permission is checked before opening a panel or invoking a text responder.
@MainActor struct InstrumentMenuController {
    let instrument: SpatialInstrumentRuntimeModel
    let presets: PresetControlModel
    func save() { presets.requestSave() }
    func saveAs() { presets.beginSaveAs() }
    func duplicateLayer(_ focusedAction: (() -> Void)?) { authoring { focusedAction?() } }
    func authoring(_ action: () -> Void) {
        guard instrument.authorize(.edit) else { return }
        action()
    }
    func undo(textResponder: (() -> Void)? = nil) {
        authoring { if let textResponder { textResponder() } else { _ = instrument.undo() } }
    }
    func redo(textResponder: (() -> Void)? = nil) {
        authoring { if let textResponder { textResponder() } else { _ = instrument.redo() } }
    }
}

/// Presentation only. No document, port or output ownership.
@MainActor final class WorkspaceControlModel: ObservableObject {
    @Published private(set) var preferences: WorkspacePreferences
    @Published private(set) var mode: WorkspaceLayout.Mode = .edit
    @Published var editsDeviceFields = false
    let deviceFields: DeviceFieldControlModel
    private(set) var setupState: WorkspaceSetupState
    private let defaults: UserDefaults
    private var lastStatus: MeasurementSessionStatus?
    @Published private(set) var inputLost = false
    func togglePerformance(canvas: inout MetricCanvasInteractionState) {
        let next: WorkspaceLayout.Mode = mode == .edit ? .perform : .edit
        canvas.setPerformanceLocked(next == .perform)
        mode = next
    }
    func togglePerformance(canvas: CanvasSession) {
        let next: WorkspaceLayout.Mode = mode == .edit ? .perform : .edit
        canvas.setPerformanceLocked(next == .perform)
        mode = next
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        deviceFields = DeviceFieldControlModel(defaults: defaults)
        let value = WorkspacePreferenceStore.load(from: defaults)
        preferences = value; setupState = .init(visible: value.setup)
    }
    func setVisible(_ area: WorkspaceLayout.Area, _ visible: Bool) {
        guard mode == .edit else { return }
        guard area != .field else { return }
        if area == .setup { setupState = setupState.applying(.manual(visible: visible)) }
        var value = preferences
        switch area {
        case .setup: value.setup = visible
        case .layers: value.layers = visible
        case .cell: value.cell = visible
        case .channelStrip: value.channelStrip = visible
        case .field: return
        }
        update(value)
    }
    func selectTab(_ tab: WorkspaceLayout.InspectorTab) {
        guard mode == .edit else { return }
        var value = preferences; value.selectedTab = tab.rawValue; update(value)
    }
    func setScannerFlagBits(_ enabled: Bool) {
        var value = preferences; value.scannerFlagBits = enabled; update(value)
    }
    func setButtonLabels(_ enabled: Bool) {
        var value = preferences; value.buttonLabels = enabled; update(value)
    }
    func setFieldToolbarLabels(_ enabled: Bool) {
        var value = preferences; value.fieldToolbarLabels = enabled; update(value)
    }
    func setClockSendEnabled(_ enabled: Bool) {
        var value = preferences; value.clockSendEnabled = enabled; update(value)
    }
    func setClockDirection(_ direction: ClockDirection) {
        var value = preferences; value.clockDirection = direction; update(value)
    }
    func setClockSource(_ id: Int32?, name: String? = nil) {
        var value = preferences; value.clockSourceID = id; value.clockSourceName = name; update(value)
    }
    func applyClockPreferences(to instrument: SpatialInstrumentRuntimeModel) {
        instrument.configureClock(direction: preferences.clockDirection, targets: Set(preferences.clockTargetIDs),
                                  sourceID: preferences.clockSourceID, sourceName: preferences.clockSourceName ?? "No source selected")
    }
    func setClockTarget(_ id: Int32, selected: Bool) {
        var value = preferences
        value.clockTargetIDs = Array(selected ? Set(value.clockTargetIDs).union([id]) : Set(value.clockTargetIDs).subtracting([id])).sorted()
        update(value)
    }
    func accept(_ status: MeasurementSessionStatus) {
        guard status != lastStatus else { return }
        let first = lastStatus == nil
        lastStatus = status
        let nextLost: Bool
        switch status {
        case .streaming, .simulation(.streaming): nextLost = false
        case .idle, .failed, .simulation(.failed), .opening, .simulation(.opening), .openWithoutProfile, .simulation(.openWithoutProfile):
            nextLost = first ? inputLost : true
        }
        if inputLost != nextLost { inputLost = nextLost }
        guard mode == .edit else { return }
        switch status {
        case .idle:
            if !first { setupState = setupState.applying(.disconnected) }
        case .failed, .simulation(.failed):
            setupState = setupState.applying(.disconnected)
        case .opening(let port):
            setupState = setupState.applying(.disconnected).applying(.connection(session: "scanner:\(port)", connected: false))
        case .openWithoutProfile(let port):
            setupState = setupState.applying(.connection(session: "scanner:\(port)", connected: true))
        case .streaming(let port, _):
            let session = "scanner:\(port)"
            setupState = setupState.applying(.connection(session: session, connected: true)).applying(.profile(session: session))
        case .simulation(.opening(let service)):
            setupState = setupState.applying(.disconnected).applying(.connection(session: "simulation:\(service)", connected: false))
        case .simulation(.openWithoutProfile(let service)):
            setupState = setupState.applying(.connection(session: "simulation:\(service)", connected: true))
        case .simulation(.streaming(let service, _)):
            let session = "simulation:\(service)"
            setupState = setupState.applying(.connection(session: session, connected: true)).applying(.profile(session: session))
        }
        var value = preferences; value.setup = setupState.visible; update(value)
    }
    private func update(_ value: WorkspacePreferences) {
        guard value != preferences else { return }
        var merged = value
        merged.collapsedLayerGroups = WorkspacePreferenceStore.load(from: defaults).collapsedLayerGroups
        preferences = merged; WorkspacePreferenceStore.save(merged, to: defaults)
    }
}
