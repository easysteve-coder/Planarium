import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import PlanariumAudio
import PlanariumApplication
import SickPLSControlCore
import SickPLSMonitorKit
import PlanariumPresets
import PlanariumMIDI
import PlanariumDomain

private enum MusicalAssignment: String, CaseIterable {
    case singleNote, scale, random, chord

    var title: String {
        switch self {
        case .singleNote: return "Single note"
        case .scale: return "Scale"
        case .random: return "Random scale"
        case .chord: return "Chord"
        }
    }
}

private enum SpatialSteeringOption: Hashable {
    case notes
    case auParameter
    case allNotesOff
    case cc
    case programChange
    case pitchBend
    case pressure
    case channel

    static func options(for destination: SpatialRoutingDestination) -> [Self] {
        switch destination {
        case .audioUnit: return [.notes, .auParameter, .cc, .programChange, .pitchBend, .pressure, .channel, .allNotesOff]
        case .midi: return [.notes, .cc, .programChange, .pitchBend, .pressure, .channel, .allNotesOff]
        case .other: return []
        }
    }
}

/// Test-only observation point for the hosting harness. The counter is
/// injected only by tests; production construction leaves it `nil`.
@MainActor
final class InspectorEvaluationCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private struct LayerRowIdentity: Equatable, Sendable {
    let layer: SpatialInstrumentLayer
    let scenes: [SpatialScene]
    let isControl: Bool
    let renaming: Bool
    let choosingColor: Bool
    let canSolo: Bool
    let channelsAvailable: Bool
    let showsLabels: Bool
    let parameters: [AudioUnitParameterDescriptor]
}

/// Only document/catalog or local editing changes rebuild row contents.
/// Selection decoration lives outside this boundary: it cannot invalidate
/// scene membership buttons or native responders inside the row.
private struct StableLayerRow<Content: View>: View, Equatable {
    let identity: LayerRowIdentity
    let selection: CanvasLayerSelectionModel
    let content: () -> Content
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("layerRow.\(identity.layer.id)")
        LayerRowHostingSurface(identity: identity, selection: selection, content: content)
            .frame(maxWidth: .infinity).frame(height: identity.showsLabels ? 44 : 34)
    }
}

/// Icon rows use 34 points; visible captions need 44 points without clipping.
/// Each row's hosting boundary keeps selection decoration from invalidating the
/// native control layouts in every other row of the surrounding ScrollView.
private struct LayerRowHostingSurface<Content: View>: NSViewRepresentable {
    let identity: LayerRowIdentity
    let selection: CanvasLayerSelectionModel
    let content: () -> Content
    final class Coordinator {
        var identity: LayerRowIdentity
        init(_ identity: LayerRowIdentity) { self.identity = identity }
    }
    func makeCoordinator() -> Coordinator { Coordinator(identity) }
    private func root() -> LayerRowHostedContent<Content> {
        .init(selection: selection, layerIsActive: identity.layer.isActive, layerID: identity.layer.id, layerColor: identity.layer.color, content: content)
    }
    func makeNSView(context: Context) -> NSHostingView<LayerRowHostedContent<Content>> {
        NSHostingView(rootView: root())
    }
    func updateNSView(_ view: NSHostingView<LayerRowHostedContent<Content>>, context: Context) {
        guard context.coordinator.identity != identity else { return }
        context.coordinator.identity = identity
        view.rootView = root()
    }
}

private struct LayerRowHostedContent<Content: View>: View {
    let selection: CanvasLayerSelectionModel
    let layerIsActive: Bool
    let layerID: UUID
    let layerColor: SpatialLayerColor
    let content: () -> Content
    var body: some View {
        CanvasTimingProbe.measure("inspector.rowBody") { content() }
            .modifier(LayerSelectionDecoration(selection: selection, layerIsActive: layerIsActive))
            .overlay(alignment: .leading) {
                Rectangle().fill(Color(red: layerColor.red, green: layerColor.green, blue: layerColor.blue))
                    .frame(width: 4).opacity(layerIsActive ? 1 : 0.65)
                    .inspectorLayoutProbe("layer.colorStrip." + layerID.uuidString)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .foregroundColor(.white.opacity(0.9))
            .environment(\.colorScheme, .dark)
    }
}

/// The complete list stays mounted while selection changes its two leaves.
private struct StableLayerList<Content: View>: View, Equatable {
    let rows: [LayerRowIdentity]
    let collapsed: Set<String>
    let groups: [SpatialLayerGroup]
    let content: () -> Content
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.rows == rhs.rows && lhs.collapsed == rhs.collapsed && lhs.groups == rhs.groups }
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("inspector.layerList")
        content()
    }
}

private struct LayerSelectionDecoration: ViewModifier {
    @ObservedObject var selection: CanvasLayerSelectionModel
    let layerIsActive: Bool
    func body(content: Content) -> some View {
        let _ = ViewEvaluationProbe.current?.record("inspector.rowDecoration")
        content
            .background(selection.selected ? Color.accentColor.opacity(0.28) : Color(red: 0.16, green: 0.165, blue: 0.18))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                selection.active ? StageTheme.amber.opacity(0.9) : selection.selected ? Color.accentColor : .clear,
                lineWidth: 1))
            .opacity(layerIsActive || selection.selected ? 1 : 0.45)
            .cornerRadius(4)
    }
}

/// Subscribe only the sections whose visible input changes. The inspector
/// shell and its command environment retain their identities on selection.
private struct InspectorSelectionSection<Content: View>: View {
    @ObservedObject var inspector: CanvasInspectorModel
    let name: String
    let content: () -> Content
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("inspector.section." + name)
        CanvasTimingProbe.measure("inspector.section." + name) { content() }
    }
}

private struct InspectorLayerListSection<Content: View>: View {
    @ObservedObject var model: CanvasLayerListModel
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    let content: () -> Content
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("inspector.layerListInput")
        content()
    }
}

private struct InspectorDestinationMenuIdentity: Equatable, Sendable {
    let title: String
    let channelsAvailable: Bool
    let target: SpatialRoutingTarget?
    var channels: [InstrumentChannel] = []
}
private struct InspectorMIDIMenuIdentity: Equatable, Sendable {
    let target: InstrumentMIDITarget?
    let enabled: Bool
}
private struct InspectorSteeringMenuIdentity: Equatable, Sendable {
    let target: SpatialRoutingTarget
    let layers: [SpatialInstrumentLayer]
    let scenes: [SpatialScene]
    let parameters: [AudioUnitParameterDescriptor]
    let controller: UInt8
    var channels: [InstrumentChannel] = []
}
/// Native menus keep their widget and content inputs when a layer selection
/// changes only the inspected chord. Actions still read the live inspector.
private struct InspectorStableMenu<Identity: Equatable & Sendable, Content: View>: View, Equatable {
    let identity: Identity
    let name: String
    let content: () -> Content
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("inspector.menu." + name)
        content()
    }
}

/// Range-selection bookkeeping is read by event handlers, never by layout.
private final class LayerSelectionAnchor { var id: UUID? }

/// Der fachliche Inhalt des HELMUT-Inspectors: Ebenen statt eines zweiten
/// Kanalzugs. Änderungen betreffen ausschließlich den räumlichen
/// Instrumentzustand; Audio/MIDI werden hier weder gestartet noch gestoppt.
struct LayerInspectorView: View {
    let editor: CanvasSession
    private let inspector: CanvasInspectorModel
    private var state: MetricCanvasInteractionState {
        CanvasTimingProbe.measure("inspector.projection") { inspector.interaction }
    }
    @ObservedObject var audioUnits: AudioCatalogModel
    let midiOutput: MIDIPortOwner
    let spatialInstrument: SpatialInstrumentRuntimeModel
    let evaluationCounter: InspectorEvaluationCounter?
    private let workspaceDefaults: UserDefaults

    @State private var collapsedGroupsByInstrument: [String: Set<String>] = [:]
    private var collapsedGroups: Set<String> { collapsedGroupsByInstrument[instrumentPreferenceKey] ?? [] }
    @State private var outputChangeLossCount = 0
    @State private var midiChannel = 1
    @State private var transposeAmount = "0"
    @State private var importSource: InstrumentDocument?
    @State private var showingImport = false
    @State private var pending: SpatialPendingAssignment?
    @State private var assignmentKeyboardOctave: Int?
    @State private var programMemory = InspectorRetainedValue<SpatialProgramChange?>(nil)
    @State private var controlPreparation = InspectorControlPreparation()
    @State private var layerSelectionCache = InspectorLayerSelectionCache()
    @State private var musicalTransitionMemory = InspectorRetainedValue((tag: 1, canToggle: true))
    @State private var musicalMemory = InspectorRetainedValue(SpatialAssignmentDraft(target: .midiNote(channel: 0), kind: .chord))
    @State private var renamingLayerID: UUID?
    @State private var colorPaletteLayerID: UUID?
    @State private var layerSelectionAnchor = LayerSelectionAnchor()

    private let background = Color(red: 0.115, green: 0.118, blue: 0.130)
    private let row = Color(red: 0.16, green: 0.165, blue: 0.18)
    private let secondary = Color.white.opacity(0.58)
    /// Names yield space to the complete control group at narrow widths.
    @Environment(\.fieldToolbarLabels) private var buttonLabels

    init(editor: CanvasSession, audioUnits: AudioCatalogModel, midiOutput: MIDIPortOwner,
         spatialInstrument: SpatialInstrumentRuntimeModel, evaluationCounter: InspectorEvaluationCounter?, workspaceDefaults: UserDefaults = .standard) {
        self.workspaceDefaults = workspaceDefaults
        self.editor = editor; inspector = editor.inspector
        self.audioUnits = audioUnits; self.midiOutput = midiOutput
        self.spatialInstrument = spatialInstrument; self.evaluationCounter = evaluationCounter
    }

    var body: some View {
        CanvasTimingProbe.measure("inspector.body") { content }
    }

    @ViewBuilder private var content: some View {
        let _ = evaluationCounter?.record()
        let _ = ViewEvaluationProbe.current?.record("layers")
        let _ = controlPreparation.update(state.workspace)
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.1))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        InspectorLayerListSection(model: inspector.layerList, instrument: spatialInstrument) { layerRows }
                        InspectorSelectionSection(inspector: inspector, name: "footer") { layerListFooter }
                    }
                    InspectorSelectionSection(inspector: inspector, name: "assignment") {
                        VStack(alignment: .leading, spacing: 12) {
                        if effectiveSelectedLayerIDs.count > 1 {
                            Text("\(effectiveSelectedLayerIDs.count) layers selected · \(mixedLayerSummary)")
                                .font(.system(size: 10)).foregroundColor(.orange)
                            multiLayerProperties
                        }
                        SurfaceInspectorGate(model: spatialInstrument.surfaceEditor, legacy: AnyView(VStack(alignment: .leading, spacing: 12) {
                        pitchTools
                        assignmentEditor
                            .onChange(of: state.workspace.selectedLayerID) { _ in
                                if assignmentKeyboardOctave != nil { assignmentKeyboardOctave = nil }
                                if pending != nil { pending = nil }
                            }
                            .onChange(of: state.workspace.selectedLayer.routings.first?.program) { _ in
                                if assignmentKeyboardOctave != nil { assignmentKeyboardOctave = nil }
                            }
                        }))
                        }
                    }
                }
                .padding(8)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(background)
        .foregroundColor(.white.opacity(0.9))
        .accessibilityIdentifier("channel.inspector.layers")
        .environment(\.inspectorNumberSession, editor)
        .onAppear { collapsedGroupsByInstrument = WorkspacePreferenceStore.load(from: workspaceDefaults).collapsedLayerGroups }
        .onReceive(spatialInstrument.$outputChangeLossCount) { outputChangeLossCount = $0 }
        .alert("Change output?", isPresented: Binding(get: { outputChangeLossCount > 0 }, set: { if !$0 { spatialInstrument.cancelOutputChange() } })) {
            Button("Cancel", role: .cancel) { spatialInstrument.cancelOutputChange() }
            Button("Change anyway", role: .destructive) { spatialInstrument.confirmOutputChange() }
        } message: {
            Text("This change removes \(outputChangeLossCount) own cell values. Compatible values will be kept. You can undo the change.")
        }
        .onChange(of: renamingLayerID) { _ in editor.finishEditing() }
        .onChange(of: colorPaletteLayerID) { _ in editor.finishEditing() }
        .sheet(isPresented: $showingImport) {
            if let importSource { ImportPresetLayersSheet(instrument: spatialInstrument, source: importSource) }
        }
        .focusedSceneValue(\.duplicateLayer, duplicateLayerCommand)
        .onCopyCommand { layerProviders() }
        .onPasteCommand(of: [UTType(exportedAs: LayerClipboard.type.rawValue)]) { providers in
            pasteLayers(from: providers)
        }

    }

    private func selectionResponder(for layerID: UUID) -> some View {
        ScanFieldPointerEvents(
            onScroll: { _, _ in }, onPressedTwoFingerDrag: { _ in }, onMagnify: { _, _ in },
            onKeyCommand: { handleLayerSelectionKey($0) },
            onKeyRelease: { if $0.keyCode == 49 { editor.holdHand(false) } },
            onDoubleClick: { _ in
                beginLayerRename(layerID)
            },
            onFocusLost: { editor.holdHand(false) },
            onDeleteCommand: { editor.perform(.delete) },
            onSelectAllCommand: { editor.selectLayers(Set(state.workspace.layers.map(\.id))) },
            isDeleteCommandEnabled: { editor.isEnabled(.delete) },
            isSelectAllCommandEnabled: { !state.isPerformanceLocked && !state.workspace.layers.isEmpty },
            isKeyboardOnly: true,
            onKeyboardClick: { _ in selectLayerForInspection(layerID) }
        )
    }

    @discardableResult func handleLayerSelectionKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.option, .command, .control]) == .option,
           event.keyCode == 125 || event.keyCode == 126 {
            let amount = (event.modifierFlags.contains(.shift) ? 12 : 1) * (event.keyCode == 126 ? 1 : -1)
            _ = spatialInstrument.applyPitchOperation(.transpose(amount)); return true
        }

        if state.isPerformanceLocked, event.keyCode != 53, event.keyCode != 49 {
            _ = spatialInstrument.authorize(.edit)
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 { _ = editor.perform(.delete); return true }
        if !event.modifierFlags.contains(.command) {
            let key: MetricCanvasKey
            switch event.keyCode {
            case 53: key = .escape
            case 123: key = .left
            case 124: key = .right
            case 125: key = .down
            case 126: key = .up
            case 49: editor.holdHand(true); return true
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "v": key = .selectTool
                case "b": key = .paintTool
                case "e": key = .eraseTool
                case "h": key = .handTool
                case "p": key = .auditionTool
                default: return false
                }
            }
            _ = editor.handleKey(key, modifiers: event.modifierFlags.contains(.shift) ? .shift : [])
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "d": duplicateLayerCommand(); return true
        case "a": _ = editor.selectLayers(Set(state.workspace.layers.map(\.id))); return true
        case "c": LayerClipboard.copy(state.workspace.layers.filter { effectiveSelectedLayerIDs.contains($0.id) }); return true
        case "v":
            if let layers = LayerClipboard.pastedLayers() {
                editor.updateWorkspace(named: "Paste layers") { _ = $0.insertCopiedLayers(layers) }
            }
            return true
        case "z":
            let redo = event.modifierFlags.contains(.shift)
            let changed = redo ? spatialInstrument.redo() : spatialInstrument.undo()
            editor.noteHistoryCommand(changed, redo: redo)
            return true
        default: return false
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
            Text("LAYERS").font(.system(size: 12, weight: .bold)).fixedSize(horizontal: true, vertical: false)
            Spacer()
            iconButton("checklist", "Select all layers, so a setting such as the transition applies to every layer") {
                let ids = Set(state.workspace.layers.map(\.id))
                layerSelectionAnchor.id = state.workspace.layers.first?.id
                _ = editor.selectLayers(ids)
            }
            iconButton("square.and.arrow.down", "Import layers from preset") { chooseImportPreset() }
            iconButton("plus", "Add layer") {
                edit(named: "Add layer") { _ = $0.addLayer() }
            }
            iconButton("plus.square.on.square", "Duplicate selected layer") {
                duplicateLayerCommand()
            }
            iconButton("trash", "Delete layer") {
                edit(named: "Delete layer") { $0.deleteSelectedLayer() }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    private var layerRows: some View {
        let workspace = state.workspace
        let controls = workspace.controlLayerIDs
        let rows = workspace.layers.map { layer in
            ViewEvaluationProbe.current?.record("inspector.rowInput")
            return LayerRowIdentity(layer: layer, scenes: workspace.scenes, isControl: controls.contains(layer.id),
                renaming: renamingLayerID == layer.id, choosingColor: colorPaletteLayerID == layer.id,
                canSolo: workspace.layers.count >= 2, channelsAvailable: !spatialInstrument.document.channels.isEmpty,
                showsLabels: buttonLabels, parameters: audioUnits.parameters(for: layer.routings.first?.target.stripID ?? SpatialRoutingTarget.missingStripID))
        }
        let groups = SpatialLayerGroup.groups(workspace: workspace, document: spatialInstrument.document)
        return StableLayerList(rows: rows, collapsed: collapsedGroups, groups: groups) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(groups) { group in
                    groupHeader(group)
                    if !collapsedGroups.contains(group.id) {
                        ForEach(rows.filter { group.layerIDs.contains($0.layer.id) }, id: \.layer.id) { identity in
                            layerRow(identity)
                        }
                    }
                }
            }
        }.equatable()
    }

    private func layerRow(_ identity: LayerRowIdentity) -> some View {
        let layer = identity.layer
        return
                    StableLayerRow(identity: identity, selection: inspector.layerSelection(for: layer.id)) {
                        GeometryReader { proxy in
                        let rowLabels = identity.showsLabels && proxy.size.width >= 360 + CGFloat(identity.scenes.count) * 24
                        HStack(spacing: 6) {
                            Button {
                                guard spatialInstrument.authorize(.edit), state.workspace.layers.contains(where: { $0.id == layer.id }) else { return }
                                selectLayerForInspection(layer.id)
                                colorPaletteLayerID = layer.id
                            } label: {
                                Circle().fill(color(layer.color)).frame(width: 8, height: 8)
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).fixedSize()
                            .inspectorLayoutProbe("layer.colorPoint." + layer.id.uuidString)
                            .help("Layer color")
                            .accessibilityLabel("Layer color")
                            .popover(isPresented: Binding(
                                get: { colorPaletteLayerID == layer.id },
                                set: { if !$0 { colorPaletteLayerID = nil } }
                            )) {
                                LayerColorPalette(selected: layer.color, select: { value in
                                    selectLayerAndApply(layer.id) { $0.setSelectedLayerColor(value) }
                                }, close: { colorPaletteLayerID = nil })
                            }
                            if renamingLayerID == layer.id {
                                RenameEntryField(text: selectedName(for: layer.id), context: layer.id.uuidString)
                                    .font(.system(size: 13, weight: .regular))
                                    .frame(minWidth: 12, maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                    .textFieldStyle(.plain)
                                    .onSubmit { renamingLayerID = nil }
                                    .onExitCommand { renamingLayerID = nil }
                            } else {
                                Text(layer.name)
                                    .font(.system(size: 13, weight: .regular))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(minWidth: 12, maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                    .help(layer.name)
                                    .overlay(selectionResponder(for: layer.id))
                            }
                            // Scene membership is a separate, aligned column rather
                            // than visual punctuation attached to the layer name.
                            HStack(spacing: 4) {
                                if !identity.scenes.isEmpty {
                                    let available = max(0, proxy.size.width - (rowLabels ? 240 : 160))
                                    if CGFloat(identity.scenes.count) * 24 <= available {
                                        sceneMembershipButtons(layer)
                                    } else {
                                        ScrollView(.horizontal, showsIndicators: false) { sceneMembershipButtons(layer) }
                                            .frame(width: available, height: 24)
                                    }
                                }
                                iconButton(layer.isVisible ? "eye" : "eye.slash", layer.isVisible ? "Hide layer" : "Show layer") {
                                    editLayer(layer.id, named: "Change layer visibility") { $0.isVisible.toggle() }
                                }.inspectorLayoutProbe("layer.visible." + layer.id.uuidString)
                                muteButton(layer).inspectorLayoutProbe("layer.mute." + layer.id.uuidString)
                                .frame(width: rowLabels ? 32 : 20)
                                iconButton(layer.isLocked ? "lock.fill" : "lock.open", layer.isLocked ? "Unlock layer" : "Lock layer") {
                                    editLayer(layer.id, named: "Change layer lock") { $0.isLocked.toggle() }
                                }.inspectorLayoutProbe("layer.lock." + layer.id.uuidString)
                                if state.workspace.layers.count >= 2 {
                                    HelmutChannelButton(
                                        "S", isOn: layer.isSoloed, activeColor: .yellow,
                                        help: "Solo this layer without changing its level"
                                    ) {
                                        editLayer(layer.id, named: "Change layer solo") { $0.isSoloed.toggle() }
                                    }
                                    .frame(width: rowLabels ? 32 : 20).inspectorLayoutProbe("layer.solo." + layer.id.uuidString)
                                }
                            }.fixedSize().environment(\.fieldToolbarLabels, rowLabels)
                        }
                        .padding(5)
                        .environment(\.fieldToolbarLabels, rowLabels)
                        .contentShape(Rectangle())
                        .contextMenu { layerContextMenu(layer) }
                        }
                    }.equatable()
            .onDrag { NSItemProvider(object: layer.id.uuidString as NSString) }
    }

    private func sceneMembershipButtons(_ layer: SpatialInstrumentLayer) -> some View {
        HStack(spacing: 4) {
            ForEach(state.workspace.scenes) { scene in
                let _ = ViewEvaluationProbe.current?.record("inspector.sceneMembership")
                Button {
                    edit(named: "Change scene membership") { SceneAuthoringAction.membership(scene: scene.id, layer: layer.id).apply(to: &$0) }
                } label: {
                    Circle().fill(scene.activeLayerIDs.contains(layer.id) ? StageTheme.amber : Color.white.opacity(0.15))
                        .frame(width: 6, height: 6).frame(width: 20, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain)
                .help("\(scene.name): \(scene.activeLayerIDs.contains(layer.id) ? "plays (M off)" : "muted"). Click to change membership.")
                .disabled(state.workspace.controlLayerIDs.contains(layer.id))
            }
        }
    }

    private var instrumentPreferenceKey: String { spatialInstrument.document.revision.session.uuidString }
    private func groupHeader(_ group: SpatialLayerGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Button {
                    var collapsed = collapsedGroups
                    if !collapsed.insert(group.id).inserted { collapsed.remove(group.id) }
                    collapsedGroupsByInstrument[instrumentPreferenceKey] = collapsed
                    var preferences = WorkspacePreferenceStore.load(from: workspaceDefaults)
                    preferences.collapsedLayerGroups[instrumentPreferenceKey] = collapsed
                    WorkspacePreferenceStore.save(preferences, to: workspaceDefaults)
                } label: { Image(systemName: collapsedGroups.contains(group.id) ? "chevron.right" : "chevron.down").frame(width: 20,height: 20).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("Collapse group").accessibilityLabel("Collapse group " + group.name)
                Circle().fill(color(group.color)).frame(width: 7, height: 7)
                Button { _ = editor.selectLayers(group.layerIDs, active: group.layers.last?.id) } label: {
                    Text("\(group.name) · \(group.layers.count)").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity,minHeight: 20, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Select group " + group.name)
                Button {
                    edit(named: "Add layer to group") { workspace in
                        let id = workspace.addLayer()
                        workspace.updateLayer(id) { group.retarget(&$0) }
                    }
                } label: { Image(systemName: "plus").frame(width: 20,height: 20).contentShape(Rectangle()) }.buttonStyle(.plain).help("Add layer to group")
                    .disabled(state.isPerformanceLocked)
            }
            HStack(spacing: 7) {
                groupFlag(group, "M", \.isActive, inverted: true)
                groupFlag(group, "S", \.isSoloed)
                groupFlag(group, "Active", \.isActive)
                groupFlag(group, "Visible", \.isVisible)
                groupFlag(group, "Lock", \.isLocked)
                Spacer(minLength: 0)
            }.font(.system(size: 10)).disabled(state.isPerformanceLocked)
            if group.layers.contains(where: { noteTransition($0) == .holdUntilNext || noteTransition($0) == .toggle }) {
                Text("Hold: at most one held chord per group · any new note in this group ends it")
                    .font(.system(size: 9)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6).background(Color.white.opacity(0.07)).cornerRadius(4)
        .onDrop(of: [UTType.text], isTargeted: nil) { providers in
            guard !state.isPerformanceLocked, let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let text = value as? String, let id = UUID(uuidString: text) else { return }
                DispatchQueue.main.async {
                    guard !group.layerIDs.contains(id) else { return }
                    editor.applyToLayers([id], named: "Move layer to group") { group.retarget(&$0) }
                }
            }
            return true
        }
    }
    private func groupFlag(_ group: SpatialLayerGroup, _ title: String,
                           _ key: WritableKeyPath<SpatialInstrumentLayer, Bool>, inverted: Bool = false) -> some View {
        let values = Set(group.layers.map { $0[keyPath: key] })
        let all = values == [true]
        let mixed = values.count > 1
        let on = inverted ? !all && !mixed : all
        let ink: Color = on || mixed ? .black : .white
        let surface = on || mixed ? StageTheme.amber : HelmutChrome.controlRaised
        return Button {
            let next = inverted ? on : !all
            if key == \.isLocked { editor.setLayerLocks(group.layerIDs, locked: next) }
            else { editor.applyToLayers(group.layerIDs, named: "Change group \(title)") { $0[keyPath: key] = next } }
        } label: {
            Text(title + (mixed ? " −" : on ? " ✓" : ""))
                .font(.system(size: 10)).foregroundColor(ink).padding(.horizontal,3)
                .frame(minWidth: 20,minHeight: 20).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title + (mixed ? " · Mixed" : ""))
            .auditedButtonSurface(group.name + " " + title,font: 10,foreground: ink,background: surface)
    }

    private var layerListFooter: some View {
        HStack {
            HStack(spacing: 2) {
                iconButton("chevron.up", "Move layer up") { edit(named: "Change layer order") { $0.moveSelectedLayer(by: -1) } }.frame(width: buttonLabels ? 40 : 24, height: buttonLabels ? 38 : 24).inspectorLayoutProbe("order.up")
                iconButton("chevron.down", "Move layer down") { edit(named: "Change layer order") { $0.moveSelectedLayer(by: 1) } }.frame(width: buttonLabels ? 40 : 24, height: buttonLabels ? 38 : 24).inspectorLayoutProbe("order.down")
            }.fixedSize().inspectorLayoutProbe("audit.group.layer.order")
            Spacer()
            Text("\(state.workspace.selectedLayer.polarCells.count) \(state.workspace.selectedLayer.polarCells.count == 1 ? "cell" : "cells")")
                .font(.system(size: 9).monospacedDigit()).foregroundColor(secondary)
        }
    }

    func muteButton(_ layer: SpatialInstrumentLayer) -> HelmutChannelButton {
        HelmutChannelButton("M", isOn: !layer.isActive, activeColor: .orange,
            help: layer.isActive ? "Mute layer" : "Activate layer") {
            editLayer(layer.id, named: "Change layer activity") { $0.isActive.toggle() }
        }
    }
    @ViewBuilder func layerContextMenu(_ layer: SpatialInstrumentLayer) -> some View {
        if !state.isPerformanceLocked {
        Button(LayerContextMenuAction.duplicate.title) { spatialInstrument.duplicateLayer(layer.id) }
        Button(LayerContextMenuAction.copy.title) { copyLayers([layer.id]) }
        Button(LayerContextMenuAction.paste.title) { pasteLayers() }
            .disabled(!LayerContextMenuAction.paste.isEnabled(canPaste: LayerClipboard.pastedLayers() != nil))
        Divider()
        Button("Rename…") {
            beginLayerRename(layer.id)
        }
            .disabled(layer.isLocked)
        Menu("Color") {
            ForEach(SpatialLayerColor.palette.indices, id: \.self) { index in
                layerColorButton(LayerColorPalette.name(index), SpatialLayerColor.palette[index], layer: layer)
            }
            Button("Custom color…") {
                guard spatialInstrument.authorize(.edit), state.workspace.layers.contains(where: { $0.id == layer.id }) else { return }
                colorPaletteLayerID = layer.id
            }
        }
        .disabled(layer.isLocked)
        Menu("Output") {
            SelectionMenuItem("No output", selected: layer.routings.isEmpty) { selectLayerAndApply(layer.id) { $0.clearSelectedLayerTarget() } }
            SelectionMenuItem("AU instrument", selected: layer.routings.first?.target.destination == .audioUnit) { retargetLayerOutput(layer, to: .audioUnit) }
                .disabled(spatialInstrument.document.channels.isEmpty || layer.isLocked)
            SelectionMenuItem("MIDI", selected: layer.routings.first?.target.destination == .midi) { retargetLayerOutput(layer, to: .midi) }
                .disabled(layer.isLocked)
        }
        .disabled(layer.isLocked)
        if let target = layer.routings.first?.target {
            Menu("Controls") {
                steeringMenuContent(target: target) { replacement in
                    selectLayerAndApply(layer.id) { state in
                        let current = state.workspace.selectedLayer.routings.first
                        let next = preservingCommittedController(replacement, previous: target, current: current?.target)
                        if let channel = next.midiChannel { state.setSelectedLayerMIDIChannel(channel) }
                        state.setSelectedLayerTarget(next, program: steeringProgram(for: next, currentProgram: current?.program))
                    }
                }
            }
            .disabled(layer.isLocked)
        }
        }
    }

    private func layerColorButton(_ title: String, _ value: SpatialLayerColor, layer: SpatialInstrumentLayer) -> some View {
        SelectionMenuItem(title, selected: layer.color == value) {
            selectLayerAndApply(layer.id) { $0.setSelectedLayerColor(value) }
            colorPaletteLayerID = nil
        }
    }

    func selectLayerAndApply(_ id: UUID, _ action: (inout MetricCanvasInteractionState) -> Void) {
        // The native color panel may outlive the row that opened it.
        guard state.workspace.layers.contains(where: { $0.id == id }) else { return }
        editor.commitNumberEdits()
        guard spatialInstrument.authorize(.edit) else { return }
        if state.workspace.selectedLayerID != id { editor.updateWorkspace { $0.selectLayer(id) } }
        editor.perform(action)
    }

    private var midiEffectChannels: [InstrumentChannel] {
        spatialInstrument.document.channels.filter { $0.midiEffects.contains { $0.kind == .arpeggiator } }
    }

    /// Owner 02.10.2026: Eine Ebene, ein Ziel — gewählt per Dropdown.
    private var destinationMenu: some View {
        let fxChannels = midiEffectChannels
        return Menu {
            SelectionMenuItem(SpatialScenePresentation.outputTitles[0], selected: state.workspace.selectedLayer.routings.isEmpty) {
                if let routing = state.workspace.selectedLayer.routings.first {
                    removeRouting(routing.id)
                }
            }
            SelectionMenuItem(SpatialScenePresentation.outputTitles[1], selected: state.workspace.selectedLayer.routings.first.map { $0.target.destination == .audioUnit && selectedSteering($0.target) != "allNotesOff" } ?? false) {
                if state.workspace.selectedLayer.routings.first?.target.destination != .audioUnit {
                    retargetOutput(.audioUnit)
                }
            }
            .disabled(spatialInstrument.document.channels.isEmpty)
            SelectionMenuItem(SpatialScenePresentation.outputTitles[2], selected: state.workspace.selectedLayer.routings.first.map { $0.target.destination == .midi && selectedSteering($0.target) != "allNotesOff" } ?? false) {
                if state.workspace.selectedLayer.routings.first?.target.destination != .midi {
                    retargetOutput(.midi)
                }
            }
            SelectionMenuItem(SpatialScenePresentation.outputTitles[3], selected: destinationLabel == "Switch") {
                addRouting(.sceneSwitch(action: .next, dwellSeconds: 0), program: .constant(1))
            }
            SelectionMenuItem(SpatialScenePresentation.outputTitles[4], selected: destinationLabel == "Release layer") {
                let id = state.workspace.layers.first { !state.workspace.controlLayerIDs.contains($0.id) && $0.id != state.workspace.selectedLayerID }?.id ?? state.workspace.selectedLayerID
                addRouting(.releaseLayer(layerID: id), program: .constant(1))
            }
            if !fxChannels.isEmpty {
                Menu("MIDI FX") {
                    MIDIEffectTargetChoices(channels: fxChannels) { target in
                        let draft = visibleAssignmentDraft
                        let minimum: Double, maximum: Double
                        if case .midiEffectParameter = draft.target {
                            minimum = draft.minimumValue; maximum = draft.maximumValue
                        } else {
                            // Fresh Rate surfaces speed up toward the near edge.
                            if case .midiEffectParameter(_, _, .rate) = target { minimum = 1; maximum = 0 }
                            else { minimum = 0; maximum = 1 }
                        }
                        addRouting(target, program: .continuous(minimum: minimum, maximum: maximum,
                            directionDegrees: draft.directionDegrees, curve: draft.curve))
                    }
                }.help("Control an Arpeggiator parameter with this surface")
            }
            SelectionMenuItem("Silence (All notes off)", selected: state.workspace.selectedLayer.routings.first.map { selectedSteering($0.target) == "allNotesOff" } ?? false) {
                let target = state.workspace.selectedLayer.routings.first?.target
                let channel = target?.midiChannel ?? selectedMIDIChannel
                let silence: SpatialRoutingTarget = target?.destination == .audioUnit
                    ? .audioUnitAllNotesOff(channel: channel, stripID: target?.stripID ?? SpatialRoutingTarget.missingStripID)
                    : .midiAllNotesOff(channel: channel)
                addRouting(silence, program: steeringProgram(for: silence))
            }.help("Release all held and toggled notes on this output channel on fresh measured entry.")
        } label: {
            // Ein einziger Text: `.borderlessButton` zeigt in der
            // Menübeschriftung nur den ersten Text (Owner-Bild 03.10.).
            Text(destinationLabel)
                .fontWeight(.semibold)
                .lineLimit(1)
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 25)
            .background(row)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderedButton)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("inspector.layer.target")
        .tint(.white)
        .help("Select the output that receives this layer.")
    }

    @ViewBuilder
    private func whatMenu(target: SpatialRoutingTarget) -> some View {
        Menu {
            steeringMenuContent(target: target) { replacement in
                editor.commitNumberEdits()
                let next = preservingCommittedController(replacement, previous: target,
                    current: state.workspace.selectedLayer.routings.first?.target)
                addRouting(next, program: steeringProgram(for: next))
            }
        } label: {
            Text(selectedLayersDiffer { $0.routings.first?.target } ? "Mixed" : targetMenuLabel(target))
                .fontWeight(.semibold)
                .lineLimit(1)
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 25)
            .background(row)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderedButton)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("inspector.layer.what")
        .tint(.white)
        .help("Select the signal controlled at this output.")
    }

    @ViewBuilder
    private func steeringMenuContent(
        target: SpatialRoutingTarget,
        apply: @escaping (SpatialRoutingTarget) -> Void
    ) -> some View {
        if case .midiEffectParameter = target {
            MIDIEffectTargetChoices(channels: midiEffectChannels, apply: apply)
        }
        if case .sceneSwitch = target {
            ForEach(SpatialScenePresentation.choices(in: state, layerOnly: true)) { choice in
                SelectionMenuItem(choice.title, selected: choice.isSelected) { _ = editor.setSceneAction(choice.action, layerOnly: true) }
            }
        }
        if case .releaseLayer = target {
            ForEach(state.workspace.layers.filter { !state.workspace.controlLayerIDs.contains($0.id) }) { layer in
                SelectionMenuItem(layer.name, selected: target == .releaseLayer(layerID: layer.id)) { _ = editor.setReleaseLayerTarget(layer.id, layerOnly: true) }
            }
        }
        ForEach(SpatialSteeringOption.options(for: target.destination), id: \.self) { option in
            switch option {
            case .notes:
                SelectionMenuItem("Notes", selected: selectedSteering(target) == "notes") { apply(target.destination == .midi ? .midiNote(channel: target.midiChannel ?? selectedMIDIChannel) : .audioUnitNote(channel: target.midiChannel ?? selectedMIDIChannel, stripID: target.stripID ?? SpatialRoutingTarget.missingStripID)) }
            case .auParameter:
                Menu("AU-Parameter") {
                    let parameters = audioUnits.parameters(for: target.stripID ?? SpatialRoutingTarget.missingStripID)
                    if parameters.isEmpty {
            Text("No writable parameter available")
                    } else {
                        ForEach(parameters, id: \.self) { parameter in
                            SelectionMenuItem(parameter.displayName, selected: target == auTarget(parameter, stripID: target.stripID ?? SpatialRoutingTarget.missingStripID)) { apply(auTarget(parameter, stripID: target.stripID ?? SpatialRoutingTarget.missingStripID)) }
                        }
                    }
                }
            case .allNotesOff:
                SelectionMenuItem("All Notes Off", selected: selectedSteering(target) == "allNotesOff") { apply(target.destination == .midi ? .midiAllNotesOff(channel: target.midiChannel ?? selectedMIDIChannel) : .audioUnitAllNotesOff(channel: target.midiChannel ?? selectedMIDIChannel, stripID: target.stripID ?? SpatialRoutingTarget.missingStripID)) }
            case .cc:
                SelectionMenuItem("CC \(visibleAssignmentDraft.ccNumber)", selected: selectedSteering(target) == "cc") { apply(SpatialRoutingTarget.midiCC(channel: target.midiChannel ?? selectedMIDIChannel, controller: visibleAssignmentDraft.ccNumber).retargeted(to: target.destination, stripID: target.stripID ?? SpatialRoutingTarget.missingStripID)) }
            case .programChange:
                SelectionMenuItem("Program Change", selected: selectedSteering(target) == "programChange") { apply(SpatialRoutingTarget.midiProgramChange(channel: target.midiChannel ?? selectedMIDIChannel).retargeted(to: target.destination, stripID: target.stripID ?? SpatialRoutingTarget.missingStripID)) }
            case .pitchBend:
                SelectionMenuItem("Pitch Bend", selected: selectedSteering(target) == "pitchBend") { apply(SpatialRoutingTarget.midiPitchBend(channel: target.midiChannel ?? selectedMIDIChannel).retargeted(to: target.destination, stripID: target.stripID ?? SpatialRoutingTarget.missingStripID)) }
            case .pressure:
                SelectionMenuItem("Pressure", selected: selectedSteering(target) == "pressure") { apply(SpatialRoutingTarget.midiChannelPressure(channel: target.midiChannel ?? selectedMIDIChannel).retargeted(to: target.destination, stripID: target.stripID ?? SpatialRoutingTarget.missingStripID)) }
            case .channel:
                if target.midiChannel != nil {
                Menu("MIDI channel") {
                    ForEach(1...16, id: \.self) { channel in
                        SelectionMenuItem("Channel \(channel)", selected: target.midiChannel == UInt8(channel - 1)) {
                            apply(target.withMIDIChannel(UInt8(channel - 1)))
                        }
                    }
                }
                }
            }
        }
    }

    private func selectedSteering(_ target: SpatialRoutingTarget) -> String {
        switch target {
        case .midiNote, .audioUnitNote: return "notes"
        case .midiAllNotesOff, .audioUnitAllNotesOff: return "allNotesOff"
        case .midiCC, .audioUnitCC: return "cc"
        case .midiProgramChange, .audioUnitProgramChange: return "programChange"
        case .midiPitchBend, .audioUnitPitchBend: return "pitchBend"
        case .midiChannelPressure, .audioUnitChannelPressure: return "pressure"
        case .midiEffectParameter: return "midiEffectParameter"
        case .audioUnitParameter: return "auParameter"
        case .sceneSwitch: return "scene"
        case .releaseLayer: return "release"
        case .boolean: return "boolean"
        }
    }

    private func preservingCommittedController(_ replacement: SpatialRoutingTarget,
                                               previous: SpatialRoutingTarget,
                                               current: SpatialRoutingTarget?) -> SpatialRoutingTarget {
        guard let number = current?.controllerNumber,
              replacement.controllerNumber == previous.controllerNumber else { return replacement }
        return replacement.withControllerNumber(number)
    }

    private func steeringProgram(for target: SpatialRoutingTarget, currentProgram: SpatialValueProgram? = nil) -> SpatialValueProgram {
        let current = currentProgram ?? state.workspace.selectedLayer.routings.first?.program
        switch target {
        case .midiProgramChange, .audioUnitProgramChange:
            if let current, case .programChange = current { return current }
            return .programChange(.init(countsFromOne: target.destination == .midi ? editor.programCountingPreference?(state.workspace.selectedLayerID) ?? true : true))
        case .audioUnitNote, .midiNote:
            if let current {
                switch current {
                case .scale, .randomScale, .chord, .singleNote: return current
                case .constant, .continuous, .programChange: break
                }
            }
            return scaleProgram
        case .midiEffectParameter, .audioUnitParameter, .midiCC, .audioUnitCC, .midiPitchBend, .audioUnitPitchBend,
             .midiChannelPressure, .audioUnitChannelPressure:
            if let current {
                switch current {
                case .constant, .continuous: return current
                case .scale, .randomScale, .chord, .singleNote, .programChange: break
                }
            }
            return continuousProgram
        case .audioUnitAllNotesOff, .midiAllNotesOff, .sceneSwitch, .releaseLayer, .boolean:
            return continuousProgram
        }
    }

    private func selectedLayersDiffer<Value: Equatable>(_ value: (SpatialInstrumentLayer) -> Value) -> Bool {
        let layers = state.workspace.layers.filter { effectiveSelectedLayerIDs.contains($0.id) }
        guard let first = layers.first else { return false }
        return layers.dropFirst().contains { value($0) != value(first) }
    }
    private var canEditSelectedLayers: Bool {
        state.workspace.layers.contains { effectiveSelectedLayerIDs.contains($0.id) && !$0.isLocked }
    }
    private var destinationLabel: String {
        if selectedLayersDiffer({ $0.routings.first?.target.destination }) { return "Mixed" }
        switch state.workspace.selectedLayer.routings.first?.target.destination {
        case nil: return "No output"
        case .audioUnit: return "AU instrument"
        case .midi: return "MIDI"
        case .other:
            if selectedLayersDiffer({ $0.routings.first?.target }) { return "Mixed" }
            if case .midiEffectParameter = state.workspace.selectedLayer.routings.first?.target { return "MIDI FX" }
            if case .releaseLayer = state.workspace.selectedLayer.routings.first?.target { return "Release layer" }
            return "Switch"
        }
    }

    private func chooseImportPreset() {
        guard spatialInstrument.authorize(.edit) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), let reading = try? PresetDocumentReader.read(data).get(),
              let source = try? reading.replacing(spatialInstrument.document) else { return }
        importSource = source; showingImport = true
    }

    private func sharedBoolLabel(_ name: String, _ key: KeyPath<SpatialInstrumentLayer, Bool>) -> String {
        let values = state.workspace.layers.filter { effectiveSelectedLayerIDs.contains($0.id) }.map { $0[keyPath: key] }
        return "\(name): " + (Set(values).count > 1 ? "Mixed" : values.first == true ? "On" : "Off")
    }
    private var multiLayerProperties: some View {
        Menu("Layer properties") {
            Button(sharedBoolLabel("Active", \.isActive)) { setSharedBool(\.isActive) }
            Button(sharedBoolLabel("Solo", \.isSoloed)) { setSharedBool(\.isSoloed) }
            Button(sharedBoolLabel("Visible", \.isVisible)) { setSharedBool(\.isVisible) }
            Button(sharedBoolLabel("Locked", \.isLocked)) { setSharedBool(\.isLocked) }
            Menu(selectedLayersDiffer { $0.color } ? "Color: Mixed" : "Color") {
                Button("Orange") { setSharedColor(.orange) }; Button("Blue") { setSharedColor(.blue) }
                Button("Green") { setSharedColor(.green) }; Button("Purple") { setSharedColor(.purple) }
            }
        }.disabled(state.isPerformanceLocked)
    }
    private func setSharedBool(_ key: WritableKeyPath<SpatialInstrumentLayer, Bool>) {
        let layers = state.workspace.layers.filter { effectiveSelectedLayerIDs.contains($0.id) }
        let next = !layers.allSatisfy { $0[keyPath: key] }
        if key == \SpatialInstrumentLayer.isLocked { editor.setLayerLocks(effectiveSelectedLayerIDs, locked: next) }
        else { editor.applyToLayers(effectiveSelectedLayerIDs, named: "Change layer property") { $0[keyPath: key] = next } }
    }
    private func setSharedColor(_ value: SpatialLayerColor) {
        editor.applyToLayers(effectiveSelectedLayerIDs, named: "Change layer color") { $0.color = value }
    }

    private var mixedLayerSummary: String {
        let layers = state.workspace.layers.filter { effectiveSelectedLayerIDs.contains($0.id) }
        guard let first = layers.first else { return "" }
        let mixed = layers.dropFirst().contains {
            $0.routings.map(\.target) != first.routings.map(\.target) || $0.midiTarget != first.midiTarget ||
            $0.color != first.color || $0.isVisible != first.isVisible || $0.isActive != first.isActive || $0.isLocked != first.isLocked
        }
        return mixed ? "Mixed" : "Common values"
    }

    private var boundedTranspose: Int {
        guard let value = Double(transposeAmount), value.isFinite else { return 0 }
        return Int(min(48, max(-48, value)).rounded(.towardZero))
    }
    private func applyTranspose() {
        let amount = boundedTranspose
        transposeAmount = String(amount)
        guard amount != 0, !state.isPerformanceLocked else { return }
        _ = spatialInstrument.applyPitchOperation(.transpose(amount))
    }
    private var pitchTools: some View {
        HStack(spacing: 6) {
            Text("Semitones").font(.system(size: 10))
            TextField("Semitones", text: $transposeAmount)
                .textFieldStyle(.plain).font(.system(size: 12).monospacedDigit()).multilineTextAlignment(.trailing)
                .padding(4).background(Color.black.opacity(0.3)).cornerRadius(3)
                .frame(width: 48).onSubmit { applyTranspose() }
                .onChange(of: transposeAmount) { value in
                    if !value.isEmpty && value != "-" && value != "+" {
                        let normalized = String(boundedTranspose)
                        if value != normalized { transposeAmount = normalized }
                    }
                }
                .accessibilityIdentifier("inspector.transpose.amount")
            IconActionButton("Apply", symbol: "checkmark.circle") { applyTranspose() }
                .help("Apply transpose").disabled(boundedTranspose == 0)
                .accessibilityIdentifier("inspector.transpose.apply")
        }.disabled(state.isPerformanceLocked)
    }

    @ViewBuilder private var assignmentEditor: some View {
        let workspace = state.workspace
        let target = workspace.selectedLayer.routings.first?.target
        let fxChannels = midiEffectChannels
        let _ = controlPreparation.update(workspace)
        let _ = seedProgramMemory()
        section("OUTPUT") {
            VStack(spacing: 0) {
                InspectorStableMenu(identity: InspectorDestinationMenuIdentity(title: destinationLabel,
                    channelsAvailable: !spatialInstrument.document.channels.isEmpty, target: target, channels: fxChannels), name: "destination") {
                    HStack { Text("Output").font(.system(size: 10)); Spacer(minLength: 4); destinationMenu }.inspectorLayoutProbe("output")
                }
                    .equatable().disabled(state.isPerformanceLocked)
                if target?.destination == .midi, selectedLayersDiffer({ $0.midiTarget }) {
                    Text("MIDI destination: Mixed").font(.system(size: 10)).foregroundColor(.orange)
                }
                if controlPreparation.midiAvailable || target?.destination == .midi {
                    InspectorStableMenu(identity: InspectorMIDIMenuIdentity(target: workspace.selectedLayer.midiTarget,
                        enabled: !state.isPerformanceLocked && canEditSelectedLayers), name: "midiPresentation") {
                        LayerMIDIDestinationMenu(target: state.workspace.selectedLayer.midiTarget, midi: midiOutput) { target in
                            if let target { setLayerMIDITarget(target) }
                            else { editor.applyToLayers(effectiveSelectedLayerIDs, named: "Change layer MIDI target") { $0.midiTarget = nil } }
                        }
                        .help("Layer MIDI destination, shared by Notes and Controls; independent of clock targets. Unavailable selections remain saved.")
                        .disabled(state.isPerformanceLocked || !canEditSelectedLayers)
                    }.equatable().fixedSize(horizontal: false, vertical: true)
                        .opacity(target?.destination == .midi ? 1 : 0)
                        .frame(width: target?.destination == .midi ? nil : 0, height: target?.destination == .midi ? nil : 0)
                        .allowsHitTesting(target?.destination == .midi)
                        .accessibilityHidden(target?.destination != .midi)
                        .padding(.top, target?.destination == .midi ? 5 : 0)
                }
                if target?.destination == .audioUnit {
                    let mixedChannel = selectedLayersDiffer { $0.routings.first?.target.stripID }
                    if mixedChannel { Text("Channel: Mixed").font(.system(size: 10)).foregroundColor(.orange) }
                    ChannelOutputChoices(channels: spatialInstrument.document.channels, selectedID: mixedChannel ? nil : target?.stripID) { id in
                        guard let target else { return }
                        addRouting(target.withStripID(id), program: state.workspace.selectedLayer.routings.first?.program ?? scaleProgram)
                    }.inspectorLayoutProbe("strip").padding(.top, 5)
                }
                if let target {
                    if case .midiEffectParameter = target,
                       !target.isAvailable(in: spatialInstrument.document.channels) {
                        Text("Target unavailable · choose an active channel and Arpeggiator")
                            .font(.caption).foregroundColor(.orange)
                    }
                    InspectorStableMenu(identity: InspectorSteeringMenuIdentity(target: target, layers: workspace.layers,
                        scenes: workspace.scenes,
                        parameters: target.destination == .audioUnit ? audioUnits.parameters(for: target.stripID ?? SpatialRoutingTarget.missingStripID) : [],
                        controller: visibleAssignmentDraft.ccNumber, channels: fxChannels), name: "steering") {
                        HStack { Text("Controls").font(.system(size: 10)); Spacer(minLength: 4); whatMenu(target: target) }.inspectorLayoutProbe("steering")
                    }
                        .equatable().disabled(state.isPerformanceLocked).padding(.top, 5)
                } else {
                    Menu {
                        Text("Select an output first")
                    } label: {
                        Text("Controls")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .foregroundColor(secondary)
                            .padding(.horizontal, 7)
                            .frame(maxWidth: .infinity, minHeight: 25)
                            .background(row)
                            .cornerRadius(4)
                    }
                    .menuStyle(.borderedButton)
                    .environment(\.colorScheme, .dark)
                    .disabled(true)
                    .help("Choose where this layer sends its output.")
                    .padding(.top, 5)
                }
            }
            .help("Choose where this layer sends its output and which signal it controls.")
        }
        if target != nil {
            let draft = visibleAssignmentDraft
            VStack(alignment: .leading, spacing: 0) {
                InspectorRetainedMusicSurface(visible: isMusicalTarget) { musicalSection }
                    .frame(height: isMusicalTarget ? nil : 0)
                if programMemory.value != nil || layerProgramSelection != nil {
                    InspectorRetainedControlSurface(inspector: inspector, visible: { layerProgramSelection != nil }, name: "layerProgram", prepare: programMemory.value != nil) {
                        section("ASSIGNMENT") { retainedProgramEditor }
                    }.equatable().frame(height: layerProgramSelection != nil ? nil : 0)
                }
                if controlPreparation.control != nil || (!isMusicalTarget && layerProgramSelection == nil) {
                    InspectorRetainedControlSurface(inspector: inspector, visible: { state.workspace.selectedLayer.routings.first != nil && !isMusicalTarget && layerProgramSelection == nil }, name: "layerControl", prepare: controlPreparation.control != nil, tracksFields: controlPreparation.controlHasNumbers) {
                        let routing = !isMusicalTarget && layerProgramSelection == nil ? state.workspace.selectedLayer.routings.first : controlPreparation.control
                        if let routing {
                            section("ASSIGNMENT") {
                                nonMusicalAssignment(target: routing.target, draft: !isMusicalTarget ? draft : .from(program: routing.program, target: routing.target))
                            }
                        }
                    }.equatable().frame(height: !isMusicalTarget && layerProgramSelection == nil ? nil : 0)
                }
            }
            .disabled(state.workspace.selectedLayer.isLocked || state.isPerformanceLocked)
        } else {
            section("ASSIGNMENT") {
                Text("Select an output first")
                    .font(.system(size: 9))
                    .foregroundColor(secondary)
            }
            .disabled(state.workspace.selectedLayer.isLocked)
        }
    }

    @ViewBuilder private func nonMusicalAssignment(target: SpatialRoutingTarget, draft: SpatialAssignmentDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch target {
            case .midiProgramChange, .audioUnitProgramChange: EmptyView()
            case .midiNote, .audioUnitNote:
                EmptyView()
            case .midiCC, .audioUnitCC:
                CommittedProgramNumberField(title: "Controller", value: ccNumberBinding, range: 0...127,
                    identifier: "controller", context: state.workspace.selectedLayerID.uuidString, step: { ccNumberBinding.wrappedValue = $0 })
                    .environment(\.inspectorNumberSession, editor)
                HStack {
                    Text("CC name").font(.system(size: 10))
                    Spacer(minLength: 4)
                    Menu("\(draft.ccNumber) · \(MIDIControllerNames.name(draft.ccNumber))") {
                        if !MIDIControllerNames.common.contains(where: { $0.number == draft.ccNumber }) {
                            SelectionMenuItem("\(draft.ccNumber) · \(MIDIControllerNames.name(draft.ccNumber))", selected: true) {}
                            Divider()
                        }
                        ForEach(MIDIControllerNames.common, id: \.number) { entry in
                            SelectionMenuItem("\(entry.number) · \(entry.name)", selected: draft.ccNumber == entry.number) { ccNumberBinding.wrappedValue = Int(entry.number) }
                        }
                    }
                }.inspectorLayoutProbe("controllerName")
                continuousEditor
                assignmentButtons
            case .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure, .audioUnitParameter, .midiEffectParameter:
                continuousEditor
                assignmentButtons
            case .midiAllNotesOff, .audioUnitAllNotesOff:
                Text("Every colored cell releases all held notes for this output.")
                    .font(.system(size: 9)).foregroundColor(secondary)
            case let .sceneSwitch(action, _):
                Menu(SpatialScenePresentation.name(action, scenes: state.workspace.scenes)) {
                    ForEach(SpatialScenePresentation.choices(in: state, layerOnly: true)) { choice in
                        SelectionMenuItem(choice.title, selected: choice.isSelected) { _ = editor.setSceneAction(choice.action, layerOnly: true) }
                    }
                }
                .help("Choose the layer's default scene action. Cell-specific actions are edited in Cell.")
            case .boolean:
                Text("Colored cells switch this output on.")
                    .font(.system(size: 9)).foregroundColor(secondary)
            case .releaseLayer(let id):
                Menu(SpatialReleaseLayerPresentation.name(id, workspace: state.workspace)) {
                    ForEach(state.workspace.layers.filter { !state.workspace.controlLayerIDs.contains($0.id) }) { layer in
                        SelectionMenuItem(layer.name, selected: id == layer.id) { _ = editor.setReleaseLayerTarget(layer.id, layerOnly: true) }
                    }
                }.help("Choose the default layer to release. Each cell can choose its own target in Cell.")
                Text("Fresh entry releases only this layer's held and toggled notes.")
                    .font(.system(size: 9)).foregroundColor(secondary)
            }
        }
    }

    private var layerProgramSelection: SpatialProgramChange? {
        guard state.workspace.selectedLayer.routings.first?.target.isProgramChange == true,
              case .programChange(let value) = state.workspace.selectedLayer.routings.first?.program else { return nil }
        return value
    }
    private func seedProgramMemory() {
        if programMemory.value == nil { programMemory.value = controlPreparation.program }
    }
    @ViewBuilder private var retainedProgramEditor: some View {
        let layerID = state.workspace.selectedLayerID
        let current = layerProgramSelection
        if current != nil || programMemory.value != nil {
            InspectorProgramEditor(value: current ?? programMemory.value ?? .init(), selection: Binding(get: { layerProgramSelection ?? programMemory.value ?? .init() },
                set: { setLayerProgramChange($0, layerID: layerID) }), stepSelection: { value, component in
                    setLayerProgramChange(value, layerID: layerID, component: component)
                }, context: layerID.uuidString, rememberCounting: { if state.workspace.selectedLayer.routings.first?.target.destination == .midi { editor.rememberProgramCounting?(layerID, $0) } }).equatable()
            .environment(\.inspectorNumberSession, editor)
            .onAppear { if let current { programMemory.value = current } }
            .onChange(of: current) { if let value = $0 { programMemory.value = value } }
        }
    }

    private var isMusicalTarget: Bool {
        switch state.workspace.selectedLayer.routings.first?.target {
        case .midiNote?, .audioUnitNote?: return true
        default: return false
        }
    }
    private var visibleMusicalDraft: SpatialAssignmentDraft {
        isMusicalTarget ? visibleAssignmentDraft : musicalMemory.value
    }
    private var musicalSection: some View {
        let _ = ViewEvaluationProbe.current?.record("inspector.musicPresentation")
        let draft = visibleMusicalDraft
        return section("ASSIGNMENT") {
            compactPicker("Type", selection: musicalAssignmentBinding) {
                ForEach(MusicalAssignment.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    InspectorChordPicker(value: draft.chordPreset, selection: assignmentChordPresetBinding).equatable()
                    iconButton("arrow.uturn.down", "Invert chord down") { _ = spatialInstrument.applyPitchOperation(.invertDown) }
                        .frame(width: 24, height: 27)
                    iconButton("arrow.uturn.up", "Invert chord up") { _ = spatialInstrument.applyPitchOperation(.invertUp) }
                        .frame(width: 24, height: 27)
                }.environment(\.fieldToolbarLabels, false)
                    .modifier(InspectorContentVisibility(visible: draft.kind == .chord))
                    .padding(.bottom, draft.kind == .chord ? 6 : 0)
                if isMusicalTarget && draft.kind != .singleNote && draft.kind != .chord {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            pitchClassPicker("Root", selection: assignmentRootBinding)
                            scalePicker
                        }
                        HStack(spacing: 6) {
                            notePicker("From", selection: assignmentBinding(\.lowestMIDINote))
                            notePicker("To", selection: assignmentBinding(\.highestMIDINote))
                        }
                        if draft.kind == .scale { directionEditor }
                    }
                }
                assignmentKeyboard.inspectorLayoutProbe("keyboard")
                    .modifier(InspectorContentVisibility(visible: draft.kind == .singleNote || draft.kind == .chord))
            }
            transitionPicker
            commonNotesPicker
            toggleGuardEditor
            assignmentButtons
        }
        .onAppear {
            if isMusicalTarget {
                musicalMemory.value = visibleAssignmentDraft
                musicalTransitionMemory.value = (transitionBinding.wrappedValue, canChooseToggle)
            }
        }
        .onChange(of: musicalTransitionBinding.wrappedValue) { value in
            if isMusicalTarget { musicalTransitionMemory.value.tag = value }
        }
        .onChange(of: presentedCanChooseToggle) { value in
            if isMusicalTarget { musicalTransitionMemory.value.canToggle = value }
        }
        .onChange(of: visibleMusicalDraft) { value in
            if isMusicalTarget { musicalMemory.value = value }
        }
    }

    private func setLayerMIDITarget(_ target: InstrumentMIDITarget) {
        editor.applyToLayers(effectiveSelectedLayerIDs, named: "Change layer MIDI target") { $0.midiTarget = target }
    }
    private func setLayerProgramChange(_ value: SpatialProgramChange, layerID: UUID, component: String? = nil) {
        guard editor.workspace.selectedLayerID == layerID, !editor.workspace.selectedLayer.isLocked,
              editor.workspace.selectedLayer.routings.first?.target.isProgramChange == true else { return }
        edit(named: "Change program selection", coalescingKey: component.map { "layer:\(layerID):programChange:\($0)" }) {
            $0.updateSelectedLayer { $0.routings[0].program = .programChange(value) }
        }
        pending = nil
    }
    @ViewBuilder private var assignmentButtons: some View {
        let decision = state.assignmentApplyDecision(for: visibleAssignmentDraft)
        HStack(spacing: 4) {
            assignmentIconButton("checkmark", "Apply assignment", color: .green) {
                applyAssignment()
            }
            .disabled(state.workspace.selectedLayer.isLocked || decision != .allowed)
            if pending != nil {
                assignmentIconButton("xmark", "Discard", color: .red) { pending = nil }
                    .disabled(state.workspace.selectedLayer.isLocked || decision == .unchanged)
            }
            if visibleAssignmentDraft.kind == .randomScale {
                assignmentIconButton("die.face.5", "Reroll", color: .white) {
                    if editor.rerollAssignmentSeed() { pending = nil }
                }
                .disabled(state.workspace.selectedLayer.isLocked)
            }
        }
    }

    private func assignmentIconButton(
        _ symbol: String,
        _ label: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        AssignmentActionButton(title: label, symbol: symbol, tint: color, action: action)
    }

    private func iconOutputButton(
        _ symbol: String,
        _ label: String,
        isEnabled: Bool = true,
        fill: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            FieldToolbarIconLabel(title: label, symbol: symbol)
                .frame(maxWidth: .infinity, minHeight: 25)
                .background(isEnabled ? (fill ?? Color.accentColor.opacity(0.68)) : row)
                .cornerRadius(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(isEnabled ? .white : secondary)
        .help(label)
        .iconAccessibility(label)
        .disabled(!isEnabled)
    }

    private var scalePicker: some View {
        compactPicker("Scale", selection: assignmentBinding(\.scale)) {
            Text("Chromatic").tag(SpatialScale.chromatic)
            Text("Major").tag(SpatialScale.major)
            Text("Natural minor").tag(SpatialScale.naturalMinor)
            Text("Major pentatonic").tag(SpatialScale.majorPentatonic)
            Text("Minor pentatonic").tag(SpatialScale.minorPentatonic)
        }
    }

    private var directionEditor: some View {
        HStack {
            Text("Direction").font(.system(size: 10))
            Spacer()
                darkNumberField("Degrees", value: assignmentBinding(\.directionDegrees)).frame(width: 64)
            Text("°").foregroundColor(secondary)
        }.inspectorLayoutProbe("direction")
    }

    private var musicalTransitionBinding: Binding<Int> {
        Binding(get: { isMusicalTarget ? transitionBinding.wrappedValue : musicalTransitionMemory.value.tag }, set: { value in
            guard isMusicalTarget else { return }
            transitionBinding.wrappedValue = value
        })
    }
    private var presentedCanChooseToggle: Bool {
        isMusicalTarget ? canChooseToggle : musicalTransitionMemory.value.canToggle
    }
    private var transitionPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
        compactPicker("Transition", selection: musicalTransitionBinding) {
            if musicalTransitionBinding.wrappedValue == -1 {
                Text("Mixed").tag(-1)
            }
            Text("Retrigger").tag(0)
            Text("Legato").tag(1)
            Text("Overlap 35 ms").tag(2)
            Text("Hold till next trigger").tag(3)
            if presentedCanChooseToggle {
                Text("Toggle: on / next entry off").tag(4)
            }
        }
        .help(HoldTransitionHelp.text)
        if [3, 4].contains(musicalTransitionBinding.wrappedValue) {
            Text(HoldTransitionHelp.text).font(.system(size: 9)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
        }
        }
    }

    var commonNotesHelp: String {
        "Common notes: Keep sustains shared pitches (default). Retrigger sends Note-Off then Note-On for shared pitches when a new sound starts. Toggle-off still respects other owners. Applies to the whole layer."
    }

    func setCommonNotes(_ value: SpatialCommonNotes) {
        guard !state.isPerformanceLocked,
              !state.workspace.layers.contains(where: { effectiveSelectedLayerIDs.contains($0.id) && $0.isLocked }) else { return }
        edit(named: "Change common notes") { workspace in
            for id in effectiveSelectedLayerIDs { workspace.updateLayer(id) { $0.commonNotes = value } }
        }
    }

    private var commonNotesPicker: some View {
        HStack(spacing: 6) {
            Text("Common notes").font(.system(size: 10))
            Spacer(minLength: 0)
            ForEach(SpatialCommonNotes.allCases, id: \.self) { value in
                let selected = state.workspace.layers.filter { effectiveSelectedLayerIDs.contains($0.id) }
                    .allSatisfy { $0.commonNotes == value }
                Button { setCommonNotes(value) } label: {
                    FieldToolbarIconLabel(title: value == .keep ? "Keep" : "Retrigger", symbol: value == .keep ? "link" : "arrow.clockwise")
                        .frame(minWidth: 27, minHeight: 23)
                        .background(selected ? Color.accentColor : row).cornerRadius(4)
                }
                .buttonStyle(.plain)
                .iconAccessibility(value == .keep ? "Common notes: Keep" : "Common notes: Retrigger", caption: value == .keep ? "Keep" : "Retrigger")
                .help((value == .keep ? "Keep. " : "Retrigger. ") + commonNotesHelp)
            }
        }
        .disabled(state.isPerformanceLocked || state.workspace.layers.contains { effectiveSelectedLayerIDs.contains($0.id) && $0.isLocked })
    }

    private var continuousEditor: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Minimum").font(.system(size: 10))
                Spacer(minLength: 4)
                darkNumberField("Minimum", value: assignmentBinding(\.minimumValue)).frame(width: 86)
            }.inspectorLayoutProbe("range.minimum")
            HStack {
                Text("Maximum").font(.system(size: 10))
                Spacer(minLength: 4)
                darkNumberField("Maximum", value: assignmentBinding(\.maximumValue)).frame(width: 86)
            }.inspectorLayoutProbe("range.maximum")
            directionEditor
        }
    }

    var toggleGuardEnabled: Bool {
        transitionBinding.wrappedValue == 4 && !state.isPerformanceLocked &&
            !state.workspace.layers.contains { $0.isLocked && effectiveSelectedLayerIDs.contains($0.id) }
    }

    var toggleGuardHelp: String {
        let explanation = "Guards against accidental switching: after each Toggle switch, early entries are discarded. 0 s disables the guard."
        if state.isPerformanceLocked { return explanation + " · " + InstrumentAction.performanceLockReason }
        if state.workspace.layers.contains(where: { $0.isLocked && effectiveSelectedLayerIDs.contains($0.id) }) {
            return explanation + " · Unlock the selected layers to edit."
        }
        if transitionBinding.wrappedValue != 4 { return explanation + " · Select Toggle to enable this setting." }
        return explanation
    }

    private var toggleGuardEditor: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
            Text("Toggle guard").font(.system(size: 10))
            Spacer(minLength: 0)
            Stepper("\(String(format: "%.2f", toggleGuardBinding.wrappedValue)) s",
                    value: toggleGuardBinding, in: 0...2, step: 0.05)
                .font(.system(size: 10)).fixedSize()
        }
        .foregroundColor(toggleGuardEnabled ? .white.opacity(0.9) : secondary)
        .disabled(!toggleGuardEnabled)
        .help(toggleGuardHelp)
        .accessibilityIdentifier("layer.toggleGuard")
    }

    var toggleGuardBinding: Binding<Double> {
        Binding(get: { state.workspace.selectedLayer.toggleGuardSeconds }, set: { value in
            guard toggleGuardEnabled else { return }
            edit(named: "Change Toggle guard") { workspace in
                for id in effectiveSelectedLayerIDs {
                    workspace.updateLayer(id) { $0.toggleGuardSeconds = value }
                }
            }
        })
    }

    private var scaleProgram: SpatialValueProgram {
        .scale(rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84,
               scale: .major, directionDegrees: 90, ascending: true, transition: .legato)
    }

    private var continuousProgram: SpatialValueProgram {
        let draft = visibleAssignmentDraft
        return .continuous(minimum: min(draft.minimumValue, draft.maximumValue),
                           maximum: max(draft.minimumValue, draft.maximumValue),
                           directionDegrees: draft.directionDegrees, curve: draft.curve)
    }

    private var selectedMIDIChannel: UInt8 { UInt8(midiChannel - 1) }

    private var visibleAssignmentDraft: SpatialAssignmentDraft {
        SpatialPendingAssignment.visibleDraft(pending: pending, in: state)
    }

    private func assignmentBinding<Value>(_ keyPath: WritableKeyPath<SpatialAssignmentDraft, Value>) -> Binding<Value> {
        let layerID = state.workspace.selectedLayerID
        let target = state.workspace.selectedLayer.routings.first?.target
        // Only retained control formatters need a frozen hidden value. Keep
        // musical getters on their existing live presentation path.
        let lastVisibleValue: Value? = isMusicalTarget ? nil : .some(visibleAssignmentDraft[keyPath: keyPath])
        return Binding(
            get: {
                if let lastVisibleValue {
                    guard editor.workspace.selectedLayerID == layerID,
                          editor.workspace.selectedLayer.routings.first?.target == target else { return lastVisibleValue }
                }
                return visibleAssignmentDraft[keyPath: keyPath]
            },
            set: { value in
                // A retained formatter may finish after its selection was lost.
                guard editor.workspace.selectedLayerID == layerID,
                      editor.workspace.selectedLayer.routings.first?.target == target,
                      !editor.isPerformanceLocked, !editor.workspace.selectedLayer.isLocked else { return }
                var draft = visibleAssignmentDraft
                draft[keyPath: keyPath] = value
                let baseline = SpatialAssignmentDraft.current(in: state)
                let next = SpatialPendingAssignment(draft: draft, baseline: baseline)
                guard pending != next else { return }
                pending = next
            }
        )
    }

    private var musicalAssignmentBinding: Binding<MusicalAssignment> {
        Binding(
            get: {
                switch visibleMusicalDraft.kind {
                case .singleNote: return .singleNote
                case .scale: return .scale
                case .randomScale: return .random
                case .chord: return .chord
                case .constant, .continuous, .programChange: return .scale
                }
            },
            set: { value in
                guard isMusicalTarget else { return }
                var draft = visibleAssignmentDraft
                switch value {
                case .singleNote: draft.kind = .singleNote
                case .scale: draft.kind = .scale
                case .random: draft.kind = .randomScale
                case .chord:
                    if draft.chordPreset == nil { draft.setChordPreset(.major) }
                    else { draft.kind = .chord }
                }
                if (draft.kind == .scale || draft.kind == .randomScale), draft.transition == .toggle {
                    draft.transition = .retrigger
                }
                let baseline = SpatialAssignmentDraft.current(in: state)
                pending = SpatialPendingAssignment(draft: draft, baseline: baseline)
            }
        )
    }

    private var assignmentRootBinding: Binding<Int> {
        Binding(
            get: { visibleAssignmentDraft.rootMIDINote },
            set: { value in
                var draft = visibleAssignmentDraft
                draft.setRootMIDINote(value)
                let baseline = SpatialAssignmentDraft.current(in: state)
                pending = SpatialPendingAssignment(draft: draft, baseline: baseline)
            }
        )
    }

    var assignmentKeyboard: PianoKeyboardView {
        PianoKeyboardView(model: assignmentKeyboardBinding, velocity: assignmentVelocityBinding,
                          transition: assignmentKeyboardTransitionBinding, supportsNoteTransition: false)
    }
    private var assignmentKeyboardBinding: Binding<PianoKeyboardModel> {
        Binding(
            get: {
                let notes = visibleMusicalDraft.kind == .singleNote
                    ? [visibleMusicalDraft.rootMIDINote] : visibleMusicalDraft.chordNotes
                let lowest = notes.min() ?? visibleMusicalDraft.rootMIDINote
                return PianoKeyboardModel(
                    octave: assignmentKeyboardOctave ?? min(max(lowest / 12 - 1, 0), 9),
                    selectedNotes: Set(notes)
                )
            },
            set: { model in
                guard isMusicalTarget, !model.selectedNotes.isEmpty else { return }
                assignmentKeyboardOctave = model.octave
                var draft = visibleAssignmentDraft
                if draft.kind == .singleNote {
                    let added = model.selectedNotes.subtracting([draft.rootMIDINote])
                    draft.setRootMIDINote(added.sorted().first ?? model.selectedNotes.sorted().first!)
                } else {
                    guard draft.setChordNotes(model.selectedNotes) else { return }
                }
                let baseline = SpatialAssignmentDraft.current(in: state)
                pending = SpatialPendingAssignment(draft: draft, baseline: baseline)
            }
        )
    }

    private var assignmentVelocityBinding: Binding<Double> {
        Binding(
            get: { Double(visibleMusicalDraft.velocity) },
            set: { value in
                guard isMusicalTarget else { return }
                assignmentBinding(\.velocity).wrappedValue = UInt8(clamping: Int(value.rounded()))
            }
        )
    }

    private var assignmentKeyboardTransitionBinding: Binding<SpatialNoteTransition> {
        .constant(.retrigger)
    }

    private var assignmentChordPresetBinding: Binding<SpatialChordPreset?> {
        Binding(
            get: { visibleMusicalDraft.chordPreset },
            set: { value in
                guard isMusicalTarget, let value else { return }
                var draft = visibleAssignmentDraft
                draft.setChordPreset(value)
                let baseline = SpatialAssignmentDraft.current(in: state)
                pending = SpatialPendingAssignment(draft: draft, baseline: baseline)
            }
        )
    }

    var transitionBinding: Binding<Int> {
        Binding(
            get: {
                if let pending, pending.baseline == SpatialAssignmentDraft.current(in: state) {
                    return transitionPickerTag(for: pending.draft.transition)
                }
                let transitions = effectiveSelectedLayerIDs.compactMap { id in
                    state.workspace.layers.first(where: { $0.id == id }).flatMap(noteTransition)
                }
                guard let first = transitions.first,
                      transitions.allSatisfy({ $0 == first }) else { return -1 }
                return transitionPickerTag(for: first)
            },
            set: { value in
                guard value >= 0 else { return }
                let transition: SpatialNoteTransition = switch value {
                case 0: .retrigger
                case 1: .legato
                case 2: .overlap(milliseconds: 35)
                case 3: .holdUntilNext
                case 4: .toggle
                default: .retrigger
                }
                guard transition != .toggle || canChooseToggle else { return }
                if let pending, pending.baseline == SpatialAssignmentDraft.current(in: state) {
                    var draft = pending.draft
                    draft.transition = transition
                    self.pending = SpatialPendingAssignment(draft: draft, baseline: pending.baseline)
                    return
                }
                edit(named: "Change transition") {
                    $0.setNoteTransition(transition, for: effectiveSelectedLayerIDs)
                }
                if let pending {
                    var draft = pending.draft
                    draft.transition = transition
                    self.pending = SpatialPendingAssignment(
                        draft: draft,
                        baseline: SpatialAssignmentDraft.current(in: state)
                    )
                }
            }
        )
    }

    var effectiveSelectedLayerIDs: Set<UUID> {
        let state = self.state
        return layerSelectionCache.read(selection: state.selection, activeLayerID: state.workspace.selectedLayerID)
    }

    var canChooseToggle: Bool {
        if let pending, pending.baseline == SpatialAssignmentDraft.current(in: state) {
            return SpatialAssignmentDraft.program(from: pending.draft).supportsToggle
        }
        let ids = effectiveSelectedLayerIDs
        return state.workspace.layers.filter { ids.contains($0.id) }
            .allSatisfy { layer in layer.routings.allSatisfy { $0.program.supportsToggle } }
    }

    func selectLayerForInspection(_ id: UUID) {
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var selection = effectiveSelectedLayerIDs
        if modifiers.contains(.shift), let anchor = layerSelectionAnchor.id,
           let first = state.workspace.layers.firstIndex(where: { $0.id == anchor }),
           let last = state.workspace.layers.firstIndex(where: { $0.id == id }) {
            selection = Set(state.workspace.layers[min(first, last)...max(first, last)].map(\.id))
        } else if modifiers.contains(.command) {
            if !selection.insert(id).inserted { selection.remove(id) }
            layerSelectionAnchor.id = id
        } else {
            selection = [id]
            layerSelectionAnchor.id = id
        }
        _ = editor.selectLayers(selection, active: id)
    }
    func beginLayerRename(_ id: UUID) {
        guard spatialInstrument.authorize(.edit) else { return }
        selectLayerForInspection(id); renamingLayerID = id
    }
    var duplicateLayerCommand: DuplicateLayerAction { .init(owner: spatialInstrument) }

    private func noteTransition(_ layer: SpatialInstrumentLayer) -> SpatialNoteTransition? {
        for routing in layer.routings {
            switch routing.program {
            case let .scale(_, _, _, _, _, _, transition),
                 let .randomScale(_, _, _, _, _, transition),
                 let .chord(_, _, transition),
                 let .singleNote(_, _, transition):
                return transition
            case .constant, .continuous, .programChange:
                continue
            }
        }
        return nil
    }

    private func transitionPickerTag(for transition: SpatialNoteTransition) -> Int {
        switch transition {
        case .retrigger: return 0
        case .legato: return 1
        case .overlap: return 2
        case .holdUntilNext: return 3
        case .toggle: return 4
        }
    }

    private var ccNumberBinding: Binding<Int> {
        Binding(
            get: { Int(visibleAssignmentDraft.ccNumber) },
            set: { value in
                if editor.setAssignmentCCNumber(UInt8(clamping: value)) { pending = nil }
            }
        )
    }

    private func applyAssignment() {
        guard let pending, editor.applyAssignment(pending.draft) else { return }
        self.pending = nil
    }

    private func selectedName(for id: UUID) -> Binding<String> {
        Binding(
            get: { state.workspace.layers.first(where: { $0.id == id })?.name ?? "" },
            set: { value in
                guard spatialInstrument.authorize(.edit),
                      let layer = state.workspace.layers.first(where: { $0.id == id }), !layer.isLocked else { return }
                edit(named: "Rename layer") { $0.updateLayer(id) { $0.name = value } }
            }
        )
    }

    private var selectedColor: Binding<Color> {
        Binding(get: { color(state.workspace.selectedLayer.color) }, set: { value in
            let converted = NSColor(value).usingColorSpace(.deviceRGB) ?? .systemBlue
            edit(named: "Change color", coalescingKey: "layer:\(state.workspace.selectedLayerID):color") { $0.updateSelectedLayer {
                $0.color = SpatialLayerColor(
                    red: Double(converted.redComponent), green: Double(converted.greenComponent),
                    blue: Double(converted.blueComponent), alpha: Double(converted.alphaComponent)
                )
            } }
        })
    }

    private func selectedBool(_ keyPath: WritableKeyPath<SpatialInstrumentLayer, Bool>) -> Binding<Bool> {
        Binding(get: { state.workspace.selectedLayer[keyPath: keyPath] }, set: { value in
            edit(named: "Change layer property") { $0.updateSelectedLayer { $0[keyPath: keyPath] = value } }
        })
    }

    private func retargetLayerOutput(_ layer: SpatialInstrumentLayer, to destination: SpatialRoutingDestination) {
        selectLayerAndApply(layer.id) { state in
            let current = state.workspace.selectedLayer.routings.first
            let target = (current?.target ?? .midiNote(channel: selectedMIDIChannel)).retargeted(to: destination,
                stripID: layer.routings.first?.target.stripID ?? spatialInstrument.document.channels.first?.id ?? SpatialRoutingTarget.missingStripID)
            _ = state.setSelectedLayerTarget(target, program: current?.target.midiChannel != nil ? (current?.program ?? scaleProgram) : scaleProgram)
        }
    }

    private func retargetOutput(_ destination: SpatialRoutingDestination) {
        editor.commitNumberEdits()
        let stripID = spatialInstrument.document.channels.first?.id ?? SpatialRoutingTarget.missingStripID
        let fallback = scaleProgram
        editor.applyToLayers(effectiveSelectedLayerIDs, named: "Change output") { layer in
            let target = (layer.routings.first?.target ?? .midiNote(channel: 0)).retargeted(to: destination, stripID: stripID)
            SpatialCellBulkEdit.retarget(&layer, to: target, fallbackProgram: fallback)
        }
    }

    private func addRouting(_ target: SpatialRoutingTarget, program: SpatialValueProgram) {
        editor.applyToLayers(effectiveSelectedLayerIDs, named: "Change output") { layer in
            SpatialCellBulkEdit.retarget(&layer, to: target, fallbackProgram: program)
        }
    }

    private func removeRouting(_ id: UUID) {
        editor.applyToLayers(effectiveSelectedLayerIDs, named: "Remove output") { $0.routings.removeAll() }
    }

    private func editLayer(_ id: UUID, named name: String, _ change: (inout SpatialInstrumentLayer) -> Void) {
        edit(named: name) { workspace in
            guard let index = workspace.layers.firstIndex(where: { $0.id == id }) else { return }
            workspace.selectLayer(id)
            workspace.updateSelectedLayer(change)
            if workspace.selectedLayerID != id { workspace.selectLayer(id) }
            _ = index
        }
    }

    private func edit(
        named name: String = "Edit document",
        coalescingKey: String? = nil,
        _ change: (inout SpatialInstrumentWorkspace) -> Void
    ) {
        editor.commitNumberEdits()
        editor.updateWorkspace(named: name, coalescingKey: coalescingKey, change)
    }

    private func copyLayers(_ ids: Set<UUID>? = nil) {
        guard spatialInstrument.authorize(.edit) else { return }
        let selected = ids ?? effectiveSelectedLayerIDs
        LayerClipboard.copy(state.workspace.layers.filter { selected.contains($0.id) })
    }

    private func pasteLayers() {
        guard let layers = LayerClipboard.pastedLayers() else { return }
        edit(named: "Paste layers") { _ = $0.insertCopiedLayers(layers) }
    }

    private func layerProviders() -> [NSItemProvider] {
        let layers = state.workspace.layers.filter { effectiveSelectedLayerIDs.contains($0.id) }
        guard let data = try? JSONEncoder().encode(layers) else { return [] }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: LayerClipboard.type.rawValue, visibility: .all) { completion in
            completion(data, nil); return nil
        }
        return [provider]
    }

    private func pasteLayers(from providers: [NSItemProvider]) {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(LayerClipboard.type.rawValue) }) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: LayerClipboard.type.rawValue) { data, _ in
            guard let data, let layers = try? JSONDecoder().decode([SpatialInstrumentLayer].self, from: data), !layers.isEmpty else { return }
            DispatchQueue.main.async { edit(named: "Paste layers") { _ = $0.insertCopiedLayers(layers) } }
        }
    }

    private func color(_ value: SpatialLayerColor) -> Color {
        Color(red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
    }

    private func targetName(_ target: SpatialRoutingTarget) -> String {
        switch target {
        case .midiEffectParameter(_, _, let parameter): return "Arpeggiator · \(parameter.title)"
        case .audioUnitParameter(let parameter): return "AU · \(parameter.displayName)"
        case .audioUnitNote(let channel, _): return "AU instrument · Notes · Channel \(channel + 1)"
        case .audioUnitAllNotesOff(let channel, _): return "AU instrument · All Notes Off · Channel \(channel + 1)"
        case .midiNote(let channel): return "Notes · Channel \(channel + 1)"
        case .midiCC(let channel, let controller), .audioUnitCC(let channel, let controller, _): return "CC \(controller) · Channel \(channel + 1)"
        case .midiProgramChange(let channel), .audioUnitProgramChange(let channel, _): return "Program Change · Ch \(channel + 1)"
        case .midiPitchBend(let channel), .audioUnitPitchBend(let channel, _): return "Pitch Bend · Channel \(channel + 1)"
        case .midiChannelPressure(let channel), .audioUnitChannelPressure(let channel, _): return "Channel Pressure · Channel \(channel + 1)"
        case .midiAllNotesOff(let channel): return "All Notes Off · Channel \(channel + 1)"
        case let .sceneSwitch(action, _): return "Scene switch · \(sceneActionName(action))"
        case .releaseLayer(let id): return "Release " + SpatialReleaseLayerPresentation.name(id, workspace: state.workspace)
        case .boolean(let name): return name
        }
    }

    /// Menübeschriftung ohne „AU-Instrument · “: der Ausgang darüber nennt es schon.
    private func targetMenuLabel(_ target: SpatialRoutingTarget) -> String {
        switch target {
        case .audioUnitNote(let channel, _): return "Notes · Channel \(channel + 1)"
        case .audioUnitAllNotesOff(let channel, _): return "All Notes Off · Channel \(channel + 1)"
        case .midiEffectParameter, .audioUnitParameter, .midiNote, .midiCC, .audioUnitCC, .midiProgramChange, .audioUnitProgramChange, .midiPitchBend, .audioUnitPitchBend,
             .midiChannelPressure, .audioUnitChannelPressure, .midiAllNotesOff, .sceneSwitch, .releaseLayer, .boolean:
            return targetName(target)
        }
    }

    private func sceneActionName(_ action: SpatialSceneSwitchAction) -> String {
        switch action {
        case .next: return "Next scene"
        case .previous: return "Previous scene"
        case .scene(let id): return state.workspace.scenes.first(where: { $0.id == id })?.name ?? "missing scene"
        }
    }

    private func auTarget(_ descriptor: AudioUnitParameterDescriptor, stripID: UUID) -> SpatialRoutingTarget {
        .audioUnitParameter(.init(
            component: .init(
                componentType: descriptor.componentType,
                componentSubType: descriptor.componentSubType,
                componentManufacturer: descriptor.componentManufacturer
            ),
            address: descriptor.address,
            identifier: descriptor.identifier,
            displayName: descriptor.displayName,
            stripID: stripID
        ))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(secondary).inspectorLayoutProbe("section." + title)
            content()
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.1)) }
    }

    private func notePicker(_ title: String, selection: Binding<Int>) -> some View {
        compactPicker(title, selection: selection) {
            ForEach(0..<128, id: \.self) { note in
                let _ = ViewEvaluationProbe.current?.record("inspector.noteRow")
                Text(MIDINoteName.displayName(for: note)).tag(note)
            }
        }
    }

    private func pitchClassPicker(_ title: String, selection: Binding<Int>) -> some View {
        compactPicker(title, selection: selection) {
            ForEach(0..<128, id: \.self) { note in
                let _ = ViewEvaluationProbe.current?.record("inspector.noteRow")
                Text(MIDINoteName.pitchClassName(for: note)).tag(note)
            }
        }
    }

    private func compactPicker<Selection: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Picker(title, selection: selection, content: content)
        .pickerStyle(.menu)
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
        .padding(.horizontal, 6)
        .background(row).cornerRadius(4)
        .contentShape(Rectangle())
        .help(helpText(for: title)).inspectorLayoutProbe("picker." + title)
    }

    private func helpText(for title: String) -> String {
        switch title {
        case "Type": return "Choose whether this layer plays a scale, random scale, or chord."
        case "Chord": return "Choose the chord preset or edit its notes on the keyboard."
        case "Root": return "Choose the root note for this layer."
        case "Scale": return "Choose the scale used by this layer."
        case "From": return "Set the lowest MIDI note used by this layer."
        case "To": return "Set the highest MIDI note used by this layer."
        case "Transition": return "Choose how notes change. Toggle starts each cell on first measured entry and stops it on the next entry after leaving. Held and toggled notes survive unexpected input loss; Panic releases everything."
        default: return "Choose the displayed value for this layer."
        }
    }

    private func darkNumberField(_ title: String, value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number)
            .textFieldStyle(.plain)
            .foregroundColor(.white)
            .padding(.horizontal, 7).frame(height: 25)
            .background(row).cornerRadius(4)
            .modifier(InspectorFieldAvailability())
    }

    private func subtleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
    }

    private func iconSubtleButton(
        _ symbol: String, _ label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { FieldToolbarIconLabel(title: label, symbol: symbol).frame(maxWidth: .infinity, minHeight: 25) }
            .buttonStyle(.bordered)
            .help(label)
            .iconAccessibility(label)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FieldToolbarIconLabel(title: label, symbol: symbol)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
            .buttonStyle(.borderless).help(label).iconAccessibility(label)
    }
}

// Compatibility name for the existing hosting proof harnesses.
typealias SpatialLayerInspectorView = LayerInspectorView

/// Stable hosting boundary; reads narrow current presentation, sends intents.
struct StableSpatialLayerInspectorView: View, Equatable {
    let editor: CanvasSession
    let audioUnits: AudioCatalogModel
    let midiOutput: MIDIPortOwner
    let spatialInstrument: SpatialInstrumentRuntimeModel
    let evaluationCounter: InspectorEvaluationCounter?
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.editor === rhs.editor }
    var body: some View {
        InspectorHostingSurface(editor: editor, audioUnits: audioUnits, midiOutput: midiOutput,
            spatialInstrument: spatialInstrument, evaluationCounter: evaluationCounter)
    }
}
/// Immutable presentation key, with live owner bindings for actions. Visibility
/// invalidates the number leaves, not the unchanged counting/bank menu graph.
struct InspectorProgramEditor: View, Equatable {
    let value: SpatialProgramChange
    @Binding var selection: SpatialProgramChange
    let stepSelection: ((SpatialProgramChange, String) -> Void)?
    let context: String
    var rememberCounting: ((Bool) -> Void)? = nil
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value && lhs.context == rhs.context
    }
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("inspector.programPresentation")
        ProgramChangeEditor(selection: $selection, stepSelection: stepSelection, context: context, rememberCounting: rememberCounting)
    }
}

/// Shared controls for the layer default and a cell's own program selection.
struct ProgramChangeEditor: View {
    @Binding var selection: SpatialProgramChange
    var stepSelection: ((SpatialProgramChange, String) -> Void)? = nil
    var context = ""
    var rememberCounting: ((Bool) -> Void)? = nil
    @Environment(\.inspectorNumberSession) private var numberSession
    var body: some View {
        let countsFromOne = selection.countsFromOne
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text("Device display")
                Spacer(minLength: 4)
                Picker("Device display", selection: Binding(get: { selection.countsFromOne }, set: {
                    numberSession?.commitNumberEdits()
                    selection.countsFromOne = $0; rememberCounting?($0)
                })) {
                    Text("Device shows 1–128").tag(true)
                    Text("Device shows 0–127").tag(false)
                }.labelsHidden().fixedSize()
                    .help("Display origin only; MIDI always sends program 0–127.")
            }.inspectorLayoutProbe("counting")
            CommittedProgramNumberField(title: "Preset", value: Binding(get: { selection.displayedProgram }, set: {
                guard selection.countsFromOne == countsFromOne else { return }
                selection.program = UInt8(clamping: $0 - (countsFromOne ? 1 : 0))
            }), range: countsFromOne ? 1...128 : 0...127, identifier: "program", context: context, step: {
                guard selection.countsFromOne == countsFromOne else { return }
                var next = selection
                next.program = UInt8(clamping: $0 - (countsFromOne ? 1 : 0))
                setStep(next, component: "program")
            })
            Text("sends \(selection.program)").font(.system(size: 9)).foregroundColor(.secondary).inspectorLayoutProbe("wireProgram")
            bank("Bank MSB · CC0", keyPath: \.bankMSB)
            bank("Bank LSB · CC32", keyPath: \.bankLSB)
            Text("On entry · bank before program").font(.system(size: 9)).foregroundColor(.secondary).inspectorLayoutProbe("entry")
        }.font(.system(size: 11))
        .accessibilityIdentifier("inspector.programChange")
    }
    private func bank(_ title: String, keyPath: WritableKeyPath<SpatialProgramChange, UInt8?>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: Binding(get: { selection[keyPath: keyPath] != nil }, set: {
                selection[keyPath: keyPath] = $0 ? 0 : nil
            })).inspectorLayoutProbe("bank." + title)
            if let value = selection[keyPath: keyPath] {
                CommittedProgramNumberField(title: "Value", value: Binding(get: { Int(selection[keyPath: keyPath] ?? value) }, set: {
                    guard selection[keyPath: keyPath] != nil else { return }
                    selection[keyPath: keyPath] = UInt8(clamping: $0)
                }), range: 0...127, identifier: keyPath == \.bankMSB ? "bankMSB" : "bankLSB", context: context, step: {
                    guard selection[keyPath: keyPath] != nil else { return }
                    var next = selection
                    next[keyPath: keyPath] = UInt8(clamping: $0)
                    setStep(next, component: keyPath == \.bankMSB ? "bankMSB" : "bankLSB")
                })
            }
        }
    }
    private func setStep(_ next: SpatialProgramChange, component: String) {
        if let stepSelection { stepSelection(next, component) }
        else { selection = next }
    }
}

/// The native text responder owns typing and text Undo. Only a complete,
/// in-range integer crosses the binding on Return or when focus leaves.
struct CommittedProgramNumberField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let identifier: String
    var context = ""
    var placeholder: String? = nil
    let step: (Int) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.inspectorControlActive) private var isActive
    @Environment(\.inspectorNumberSession) private var session
    @State private var rejected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(title)
                Spacer(minLength: 4)
                InspectorNumberField(value: $value, range: range, context: context,
                    title: title, identifier: identifier, enabled: isEnabled && isActive, placeholder: placeholder,
                    session: session, rejected: $rejected)
                    .frame(width: 62, height: 22)
                Stepper(title, onIncrement: {
                    session?.commitNumberEdits()
                    if value < range.upperBound { step(value + 1) }
                }, onDecrement: {
                    session?.commitNumberEdits()
                    if value > range.lowerBound { step(value - 1) }
                })
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("\(title) fine adjustment")
                    .accessibilityIdentifier("inspector.programChange.\(identifier).stepper")
            }.inspectorLayoutProbe("number." + identifier)
            if rejected {
                Text("Enter \(range.lowerBound)–\(range.upperBound)")
                    .font(.system(size: 9)).foregroundColor(.red)
                    .accessibilityIdentifier("inspector.programChange.\(identifier).invalid")
            }
        }.font(.system(size: 11))
    }
}


struct InspectorHostedRoot: View {
    let inspector: LayerInspectorView
    let labels: Bool
    var body: some View { inspector.environment(\.fieldToolbarLabels, labels) }
}
private struct InspectorHostingSurface: NSViewRepresentable {
    let editor: CanvasSession
    let audioUnits: AudioCatalogModel
    let midiOutput: MIDIPortOwner
    let spatialInstrument: SpatialInstrumentRuntimeModel
    let evaluationCounter: InspectorEvaluationCounter?
    @Environment(\.fieldToolbarLabels) private var labels
    final class Coordinator { var labels: Bool? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    private func content() -> InspectorHostedRoot {
        InspectorHostedRoot(inspector: LayerInspectorView(editor: editor, audioUnits: audioUnits, midiOutput: midiOutput,
              spatialInstrument: spatialInstrument, evaluationCounter: evaluationCounter), labels: labels)
    }
    func makeNSView(context: Context) -> NSHostingView<InspectorHostedRoot> {
        context.coordinator.labels = labels
        return NSHostingView(rootView: content())
    }
    func updateNSView(_ view: NSHostingView<InspectorHostedRoot>, context: Context) {
        guard context.coordinator.labels != labels else { return }
        context.coordinator.labels = labels
        view.rootView = content()
    }
}

/// A collapsed editor keeps its prepared controls and layout identity. It is
/// absent from hit testing and accessibility while another assignment is shown.
struct InspectorContentVisibility: ViewModifier {
    let visible: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if InspectorLayoutProbe.enabled {
            content.frame(height: visible ? nil : 0, alignment: .top)
                .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                .environment(\.inspectorLayoutVisible, visible)
        } else {
            content.frame(height: visible ? nil : 0, alignment: .top)
                .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
        }
    }
}

private struct InspectorChordPicker: View, Equatable {
    let value: SpatialChordPreset?
    // The action reads the live inspector and draft storage, never a saved cell.
    @Binding var selection: SpatialChordPreset?
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
    var body: some View {
        Picker("Chord", selection: $selection) {
            Text("Custom").tag(Optional<SpatialChordPreset>.none)
            ForEach(SpatialChordPreset.allCases, id: \.self) {
                let _ = ViewEvaluationProbe.current?.record("inspector.chordRow")
                Text($0.displayName).tag(Optional($0))
            }
        }
        .pickerStyle(.menu)
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
        .padding(.horizontal, 6)
        .background(Color(red: 0.16, green: 0.165, blue: 0.18)).cornerRadius(4)
        .contentShape(Rectangle())
        .help("Choose the chord preset or edit its notes on the keyboard.")
    }
}

/// Remembers the last visible value without publishing a second selection.
/// The live inspector is still the only invalidation source; actions read it.
@MainActor final class InspectorRetainedValue<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// MIDI destination refreshes invalidate only the menu that presents them.
/// Selection must not re-evaluate the layer list when this menu reappears.
private struct LayerMIDIDestinationMenu: View {
    let target: InstrumentMIDITarget?
    @ObservedObject var midi: MIDIPortOwner
    let select: (InstrumentMIDITarget?) -> Void
    private func targetName(_ target: InstrumentMIDITarget?) -> String {
        guard let target, target.uniqueID != 0 else { return "Planarium virtual source" }
        return midi.destinations.first { $0.id == target.uniqueID }?.name ?? "Unavailable MIDI \(target.uniqueID)"
    }
    private var title: String {
        target == nil ? "Sum · " + targetName(midi.target) : targetName(target)
    }
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("inspector.midiDestination")
        HStack(spacing: 6) {
            Text("Device").font(.system(size: 10))
            Menu {
                SelectionMenuItem("Sum MIDI output · " + targetName(midi.target), selected: target == nil) { select(nil) }
                SelectionMenuItem("Planarium virtual source", selected: target?.uniqueID == 0) { select(.init(uniqueID: 0)) }
                if let id = target?.uniqueID, id != 0, !midi.destinations.contains(where: { $0.id == id }) {
                    SelectionMenuItem("Unavailable MIDI \(id)", selected: true) {}.disabled(true)
                }
                ForEach(midi.destinations) { destination in
                    SelectionMenuItem(destination.name, selected: target?.uniqueID == destination.id) { select(.init(uniqueID: destination.id)) }
                }
            } label: {
                Text(title).lineLimit(2).frame(maxWidth: .infinity, alignment: .trailing)
            }
            IconActionButton("Refresh MIDI devices", symbol: "arrow.clockwise") { midi.refresh() }
                .buttonStyle(.plain).help("Refresh MIDI devices")
                .iconAccessibility("Refresh MIDI devices")
        }.inspectorLayoutProbe("device")
        .onAppear { midi.refresh() }
    }
}

/// A native visibility boundary keeps the prepared music graph without changing
/// hit-testing or enabled inputs throughout that graph when another editor wins.
private struct InspectorRetainedMusicSurface<Content: View>: NSViewRepresentable {
    let visible: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.fieldToolbarLabels) private var labels
    @ViewBuilder let content: () -> Content
    private func root() -> some View {
        content().foregroundColor(.white.opacity(0.9)).environment(\.colorScheme, .dark).environment(\.fieldToolbarLabels, labels).disabled(!enabled)
    }
    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: AnyView(root()))
        view.identifier = NSUserInterfaceItemIdentifier("inspector.retainedMusic")
        view.isHidden = !visible
        return view
    }
    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        if visible {
            ViewEvaluationProbe.current?.record("inspector.musicRootUpdate")
            view.rootView = AnyView(root())
        }
        view.isHidden = !visible
    }
}

/// Only editable number leaves observe visibility. Hiding a complete SwiftUI
/// root through `disabled` invalidates every native menu and intermediate layout.
/// The native host handles hit testing/accessibility for all other controls.
@MainActor private final class InspectorControlAvailability: ObservableObject {
    @Published private(set) var active: Bool
    var willDeactivate: (() -> Void)?
    private var subscription: AnyCancellable?
    init(inspector: CanvasInspectorModel, visible: @escaping () -> Bool) {
        active = visible()
        // CanvasInspectorModel installs its current interaction before publishing
        // presentation. React at that owner boundary, never in updateNSView.
        // The initial value above precedes any field observer; dropFirst avoids
        // publishing during native host construction. No asynchronous UI hop.
        subscription = inspector.$presentation.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            let next = visible()
            if active != next {
                if !next { willDeactivate?() }
                active = next
            }
        }
    }
}
private struct InspectorControlAvailabilityKey: EnvironmentKey {
    static let defaultValue: InspectorControlAvailability? = nil
}
private struct InspectorControlActiveKey: EnvironmentKey {
    static let defaultValue = true
}
private extension EnvironmentValues {
    var inspectorControlActive: Bool {
        get { self[InspectorControlActiveKey.self] }
        set { self[InspectorControlActiveKey.self] = newValue }
    }
    var inspectorControlAvailability: InspectorControlAvailability? {
        get { self[InspectorControlAvailabilityKey.self] }
        set { self[InspectorControlAvailabilityKey.self] = newValue }
    }
}
struct InspectorFieldAvailability: ViewModifier {
    @Environment(\.inspectorControlActive) private var active
    func body(content: Content) -> some View { content.disabled(!active) }
}
private struct InspectorControlHostedContent<Content: View>: View {
    @ObservedObject var availability: InspectorControlAvailability
    let enabled: Bool
    let content: Content
    var body: some View {
        content.foregroundColor(.white.opacity(0.9))
            .environment(\.colorScheme, .dark)
            .environment(\.inspectorControlAvailability, availability)
            .environment(\.inspectorControlActive, availability.active)
            .disabled(!enabled)
    }
}

/// One fixed native host per control section. Prepare only document-backed
/// control types; otherwise create the host lazily on first use.
/// A hidden host keeps its last root; only number leaves discard their drafts
/// and become disabled. Visible updates read the current selection and locks.
struct InspectorRetainedControlSurface<Content: View>: View, Equatable {
    let inspector: CanvasInspectorModel
    let visible: () -> Bool
    let showing: Bool
    let name: String
    let prepare: Bool
    let tracksFields: Bool
    let content: () -> Content
    @State private var mounted = InspectorRetainedValue(false)
    init(inspector: CanvasInspectorModel, visible: @escaping () -> Bool, name: String,
         prepare: Bool = false, tracksFields: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        ViewEvaluationProbe.current?.record("inspector.controlSurfaceInput")
        self.inspector = inspector; self.visible = visible; self.showing = visible()
        self.name = name; self.prepare = prepare; self.tracksFields = tracksFields; self.content = content
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // Compare captured flags, never the live predicates (both predicates
        // would read the new owner and could incorrectly skip a hide edge).
        !lhs.showing && !rhs.showing && lhs.inspector === rhs.inspector &&
            lhs.name == rhs.name && lhs.prepare == rhs.prepare && lhs.tracksFields == rhs.tracksFields
    }
    var body: some View {
        if showing || prepare || mounted.value {
            InspectorControlHostingSurface(inspector: inspector, visible: visible, name: name, tracksFields: tracksFields, content: content)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: showing ? nil : 0)
                .onAppear { mounted.value = true }
        }
    }
}

/// Keep the native child mounted so its number fields receive visibility and
/// draft changes. A dormant host has no intrinsic height and need not measure
/// its retained form. Uses the macOS-12 sizing contract from the preflight.
private final class InspectorControlHost: NSHostingView<AnyView> {
    override var intrinsicContentSize: NSSize {
        isHidden ? NSSize(width: NSView.noIntrinsicMetric, height: 0) : super.intrinsicContentSize
    }
    override var fittingSize: NSSize {
        isHidden ? NSSize(width: bounds.width, height: 0) : super.fittingSize
    }
}

private struct InspectorControlHostingSurface<Content: View>: NSViewRepresentable {
    let inspector: CanvasInspectorModel
    let visible: () -> Bool
    let name: String
    let tracksFields: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.fieldToolbarLabels) private var labels
    @ViewBuilder let content: () -> Content
    @MainActor final class Coordinator {
        fileprivate var availability: InspectorControlAvailability?
        var prepared = false
        init(inspector: CanvasInspectorModel, visible: @escaping () -> Bool, tracksFields: Bool) {
            availability = tracksFields ? InspectorControlAvailability(inspector: inspector, visible: visible) : nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(inspector: inspector, visible: visible, tracksFields: tracksFields) }
    func makeNSView(context: Context) -> InspectorControlHost {
        let view = InspectorControlHost(rootView: AnyView(EmptyView()))
        view.identifier = NSUserInterfaceItemIdentifier("inspector.retained." + name)
        view.isHidden = true
        return view
    }
    func updateNSView(_ view: InspectorControlHost, context: Context) {
        if tracksFields && context.coordinator.availability == nil {
            context.coordinator.availability = InspectorControlAvailability(inspector: inspector, visible: visible)
            context.coordinator.prepared = false
        }
        let availability = context.coordinator.availability
        availability?.willDeactivate = { [weak view] in
            // End editing at the owner boundary, before SwiftUI hides/resizes
            // this retained root and before disabling its number leaves.
            if let window = view?.window, window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
        }
        let showing = tracksFields ? (availability?.active ?? visible()) : visible()
        if showing || !context.coordinator.prepared {
            let value = VStack(alignment: .leading, spacing: 0) { content() }.environment(\.fieldToolbarLabels, labels)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let availability, tracksFields {
                view.rootView = AnyView(InspectorControlHostedContent(availability: availability,
                    enabled: showing ? enabled : true, content: value))
            } else {
                view.rootView = AnyView(value.foregroundColor(.white.opacity(0.9))
                    .environment(\.colorScheme, .dark).disabled(showing ? !enabled : false))
            }
            context.coordinator.prepared = true
        }
        // macOS 12 can cache the hidden host's zero ideal height. Changing the
        // root/isHidden alone does not invalidate the outer representable's
        // sizing proposal. The root invalidates content changes itself; the
        // explicit visibility edge also invalidates the cached zero height.
        let visibilityChanged = view.isHidden == showing
        view.isHidden = !showing
        if visibilityChanged { view.invalidateIntrinsicContentSize() }
    }
}

/// One document-derived preparation value, independent of the active selection.
/// It shares the last layer array and keeps at most one program/control seed;
/// no per-cell view cache and no second authoring/selection owner.
@MainActor final class InspectorControlPreparation {
    private var layers: [SpatialInstrumentLayer]?
    private var grid: MetricSquareGrid?
    private(set) var program: SpatialProgramChange?
    private(set) var programCell: (cell: PolarMetricGridCell, info: SpatialCellInfo)?
    private(set) var control: SpatialRouting?
    private(set) var controlCell: (cell: PolarMetricGridCell, info: SpatialCellInfo)?
    private(set) var midiAvailable = false
    private(set) var controlHasNumbers = false
    private(set) var retainsCellContent = false
    func update(_ workspace: SpatialInstrumentWorkspace) {
        guard layers != workspace.layers || grid != workspace.grid else { return }
        ViewEvaluationProbe.current?.record("inspector.controlPreparation")
        layers = workspace.layers; grid = workspace.grid
        program = nil; programCell = nil; control = nil; controlCell = nil; midiAvailable = false; controlHasNumbers = false
        var controlPriority = -1
        for layer in workspace.layers {
            guard let routing = layer.routings.first else { continue }
            if routing.target.destination == .midi { midiAvailable = true }
            switch routing.target {
            case .midiNote, .audioUnitNote: continue
            case .midiProgramChange, .audioUnitProgramChange:
                if case .programChange(let value) = routing.program {
                    if program == nil { program = value }
                    if programCell == nil, let cell = firstCell(layer) {
                        programCell = SpatialCellInfo.make(cell: cell, layerID: layer.id, workspace: workspace).map { (cell, $0) }
                        if programCell != nil { program = value }
                    }
                }
            case .midiCC, .audioUnitCC, .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure, .audioUnitParameter, .midiEffectParameter:
                prepareControl(routing, layer: layer, workspace: workspace, priority: 1, best: &controlPriority)
            case .midiAllNotesOff, .audioUnitAllNotesOff, .sceneSwitch, .boolean, .releaseLayer:
                prepareControl(routing, layer: layer, workspace: workspace, priority: 0, best: &controlPriority)
            }
        }
        retainsCellContent = retainsCellContent || programCell != nil || controlCell != nil
    }
    private func prepareControl(_ routing: SpatialRouting, layer: SpatialInstrumentLayer,
                                workspace: SpatialInstrumentWorkspace, priority: Int, best: inout Int) {
        if priority > best {
            best = priority; control = routing; controlCell = nil; controlHasNumbers = priority == 1
        }
        if priority == best && controlCell == nil, let cell = firstCell(layer) {
            controlCell = SpatialCellInfo.make(cell: cell, layerID: layer.id, workspace: workspace).map { (cell, $0) }
        }
    }
    private func firstCell(_ layer: SpatialInstrumentLayer) -> PolarMetricGridCell? {
        layer.polarCells.min { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }
    }
}

/// One current layer-ID set, shared by the inspector's native binding getters.
/// Inputs are explicit: changing note values does not change layer selection.
@MainActor final class InspectorLayerSelectionCache {
    private var selection: CanvasSelection?
    private var activeLayerID: UUID?
    private var ids = Set<UUID>()
    func read(selection: CanvasSelection, activeLayerID: UUID) -> Set<UUID> {
        guard self.selection != selection || self.activeLayerID != activeLayerID else { return ids }
        self.selection = selection; self.activeLayerID = activeLayerID
        ViewEvaluationProbe.current?.record("inspector.effectiveLayerSelection")
        ids = selection.effectiveLayerIDs(activeLayerID: activeLayerID)
        return ids
    }
}

/// Shared 3×8 palette; the native free color well stays available below it.
struct LayerColorPalette: View {
    let selected: SpatialLayerColor
    let select: (SpatialLayerColor) -> Void
    var close: () -> Void = {}
    static func name(_ index: Int) -> String {
        let hues = ["Orange", "Gold", "Green", "Cyan", "Blue", "Violet", "Magenta", "Red"]
        return (index < 8 ? "" : index < 16 ? "Soft " : "Muted ") + hues[index % 8]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 4), count: 8), spacing: 4) {
                ForEach(SpatialLayerColor.palette.indices, id: \.self) { index in
                    let value = SpatialLayerColor.palette[index]
                    Button { select(value); close() } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 3).fill(Color(red: value.red, green: value.green, blue: value.blue))
                            if selected == value { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(StageTheme.readableInk(on: Color(red: value.red,green: value.green,blue: value.blue))) }
                        }.frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(Self.name(index))
                        .auditedButtonSurface(Self.name(index),font: 12,foreground: StageTheme.readableInk(on: Color(red: value.red,green: value.green,blue: value.blue)),background: Color(red: value.red,green: value.green,blue: value.blue))
                        .accessibilityLabel("Layer color: " + Self.name(index))
                        .accessibilityValue(selected == value ? "selected" : "not selected")
                        .inspectorLayoutProbe("palette." + String(index))
                }
            }
            ColorPicker("Custom color", selection: Binding(get: {
                Color(red: selected.red, green: selected.green, blue: selected.blue)
            }, set: { value in
                guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                select(.init(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent)))
            }), supportsOpacity: false)
        }.padding(12).background(StageTheme.workspace)
            .environment(\.colorScheme, .dark).preferredColorScheme(.dark)
    }
}
