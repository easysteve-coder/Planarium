import SwiftUI
import PlanariumApplication
import PlanariumDomain

/// Activation takes the runtime control path; authoring actions edit the document.
struct SceneBarView: View {
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    var compact = false
    @Environment(\.fieldToolbarLabels) private var showsLabels
    @State private var renaming: UUID?
    @State private var draft = ""
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 4) {
                    VStack(spacing: 3) {
                        Menu {
                            ForEach(instrument.canvas.workspace.scenes) { scene in
                                SelectionMenuItem(scene.name, selected: scene.id == instrument.canvas.workspace.currentSceneID) {
                                    instrument.selectScene(scene.id)
                                }
                                if !instrument.canvas.isPerformanceLocked {
                                    Menu("Edit \(scene.name)") { sceneContextMenu(scene) }
                                }
                            }
                        } label: {
                            Image(systemName: "square.stack.3d.up").frame(width: 24, height: 18)
                        }
                        .menuStyle(.borderedButton).fixedSize()
                        .accessibilityLabel("Scenes")
                        .help("A scene stores which layers play (M off) and which are muted. Current: \(instrument.canvas.workspace.scenes.first { $0.id == instrument.canvas.workspace.currentSceneID }?.name ?? "No scene").")
                        if showsLabels { Text("Scenes").font(.system(size: 10)).accessibilityHidden(true) }
                    }
                    if !instrument.canvas.isPerformanceLocked { addSceneButton }
                }
            } else { expandedBar }
        }
        .accessibilityIdentifier("workspace.scenes")
        .popover(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            HStack {
                TextField("Scene name", text: $draft).onSubmit { finishRename() }
                Button("Rename") { finishRename() }
            }.padding().frame(width: 280)
        }
    }
    private var addSceneButton: some View {
        IconActionButton("Add scene", symbol: "plus") { editScene(.add) }
            .help("New scene: store which layers play (M off) and which are muted.")
            .disabled(instrument.canvas.isPerformanceLocked)
    }
    private var expandedBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(instrument.canvas.workspace.scenes) { scene in
                        Button(scene.name) { instrument.selectScene(scene.id) }
                            .buttonStyle(.plain).padding(.horizontal, 10).frame(height: 28)
                            .background(scene.id == instrument.canvas.workspace.currentSceneID ? StageTheme.amber.opacity(0.4) : Color.white.opacity(0.08))
                            .cornerRadius(5).help("Activate \(scene.name).")
                            .onTapGesture(count: 2) { rename(scene) }
                            .contextMenu { sceneContextMenu(scene) }
                    }
                    if !instrument.canvas.isPerformanceLocked {
                        addSceneButton
                    }
                }
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
    }
    @ViewBuilder func sceneContextMenu(_ scene: SpatialScene) -> some View {
        if !instrument.canvas.isPerformanceLocked {
            Button("Rename…") { rename(scene) }
            Button("Update from current layers") { editScene(.update(scene.id)) }
                .help("Store the current M settings of all layers in this scene.")
            Button("Move left") { editScene(.move(scene.id, -1)) }
            Button("Move right") { editScene(.move(scene.id, 1)) }
            Button("Delete") { editScene(.delete(scene.id)) }
        }
    }
    func rename(_ scene: SpatialScene) {
        guard instrument.authorize(.edit) else { return }
        draft = scene.name; renaming = scene.id
    }
    private func finishRename() {
        if let renaming { editScene(.rename(renaming, draft)) }
        renaming = nil
    }
    func editScene(_ action: SceneAuthoringAction) {
        instrument.canvas.updateWorkspace(named: action.editName) { action.apply(to: &$0) }
    }
}

enum SceneAuthoringAction {
    case add, update(UUID), rename(UUID, String), move(UUID, Int), delete(UUID), membership(scene: UUID, layer: UUID)
    var editName: String {
        switch self {
        case .add: return "New scene"
        case .update: return "Update scene"
        case .rename: return "Rename scene"
        case .move: return "Move scene"
        case .delete: return "Delete scene"
        case .membership: return "Change scene membership"
        }
    }
    func apply(to workspace: inout SpatialInstrumentWorkspace) {
        switch self {
        case .add: _ = workspace.addScene()
        case .update(let id):
            workspace.updateScene(id)
        case .rename(let id, let name): workspace.renameScene(id, to: name)
        case .move(let id, let offset): workspace.moveScene(id: id, by: offset)
        case .delete(let id): workspace.deleteScene(id)
        case .membership(let scene, let layer):
            workspace.toggleSceneMembership(scene: scene, layer: layer)
        }
    }
}
