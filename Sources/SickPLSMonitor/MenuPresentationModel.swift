import Combine
import Foundation
import SickPLSMonitorKit
import PlanariumApplication
import PlanariumDomain

/// Only menu-visible state crosses into Commands. A profile/status/clock tick
/// can trigger a comparison, but cannot invalidate the scene or menu graph.
@MainActor final class MenuPresentationModel: ObservableObject {
    struct Value: Equatable {
        var undoTitle: String
        var redoTitle: String
        var canUndo: Bool
        var canRedo: Bool
        var locked: Bool
        var receivingClock: Bool
        var mode: WorkspaceLayout.Mode
        var visibility: WorkspaceLayout.Visibility
        var buttonLabels: Bool
    }
    @Published private(set) var value: Value
    private var subscriptions: [AnyCancellable] = []
    init(instrument: SpatialInstrumentRuntimeModel, workspace: WorkspaceControlModel) {
        func snapshot() -> Value {
            .init(undoTitle: instrument.undoMenuTitle, redoTitle: instrument.redoMenuTitle,
                  canUndo: instrument.canUndo, canRedo: instrument.canRedo,
                  locked: instrument.canvas.isPerformanceLocked, receivingClock: instrument.isReceivingClock,
                  mode: workspace.mode, visibility: workspace.preferences.visibility, buttonLabels: workspace.preferences.buttonLabels)
        }
        value = snapshot()
        // Published fires in willSet; compare after the entire synchronous edit,
        // including history, mode and canvas lock, has reached its final state.
        Publishers.Merge3(instrument.objectWillChange, instrument.canvas.objectWillChange, workspace.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let next = snapshot()
                if self.value != next { self.value = next }
            }.store(in: &subscriptions)
    }
}
