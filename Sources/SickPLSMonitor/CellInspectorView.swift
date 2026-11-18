import AppKit
import SwiftUI
import PlanariumAudio
import PlanariumApplication
import SickPLSControlCore
import SickPLSMonitorKit
import PlanariumPresets
import PlanariumMIDI
import PlanariumDomain

private struct PendingCellNoteEdit: Equatable {
    let cell: PolarMetricGridCell
    let baseline: SpatialCellNoteDraft
    var draft: SpatialCellNoteDraft
    var keyboard: PianoKeyboardModel
    var transition: SpatialNoteTransition = .retrigger

    init(cell: PolarMetricGridCell, document: SpatialCellNoteDraft) {
        self.cell = cell
        self.baseline = document
        self.draft = document
        let lowest = document.notes.min() ?? 60
        self.keyboard = PianoKeyboardModel(
            octave: min(max(lowest / 12 - 1, 0), 9),
            selectedNotes: document.notes
        )
    }
}

private struct PendingCellScalarEdit: Equatable {
    let cell: PolarMetricGridCell
    let baseline: Double
    var draft: Double
}

/// Transient inspector choices belong to one cell selection only.  A routing
/// UUID is valid inside its originating layer, but must never carry over to a
/// different kind of cell or layer.
struct CellInspectorDraft: Equatable {
    var selectedRoutingID: UUID?

    mutating func rebuildForNewSelection() {
        selectedRoutingID = nil
    }

    func routingID(availableRoutingIDs: [UUID]) -> UUID? {
        selectedRoutingID.flatMap { availableRoutingIDs.contains($0) ? $0 : nil }
            ?? availableRoutingIDs.first
    }
}

/// Only prepared control documents need an invisible fallback section. Pure
/// musical documents keep the ordinary cell section without collapse wrappers.
private struct InspectorCellContentVisibility: ViewModifier {
    let retaining: Bool
    let visible: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if retaining { content.modifier(InspectorContentVisibility(visible: visible)) }
        else { content }
    }
}

/// The former cell editor; its pending drafts belong to this inspector.
struct CellInspectorView: View {
    let editor: CanvasSession
    @ObservedObject private var inspector: CanvasInspectorModel
    private var state: MetricCanvasInteractionState { inspector.interaction }
    @State private var draft = CellInspectorDraft()
    @State private var pendingCellNoteEdit: PendingCellNoteEdit?
    @State private var programMemory = InspectorRetainedValue<SpatialProgramChange?>(nil)
    @State private var controlPreparation = InspectorControlPreparation()
    @State private var cellPresentationCache = InspectorCellPresentationCache()
    @State private var noteMemory = InspectorRetainedValue<SpatialCellNoteDraft?>(nil)
    @State private var pendingCellScalarEdit: PendingCellScalarEdit?
    @State private var cellValueText = ""
    @State private var cellValueRejected = false
    @FocusState private var cellValueFocused: Bool
    private let row = Color(red: 0.16, green: 0.165, blue: 0.18)
    private let secondary = Color.white.opacity(0.58)
    init(editor: CanvasSession) { self.editor = editor; inspector = editor.inspector }

    var body: some View { CanvasTimingProbe.measure("inspector.cellBody") { content } }
    @ViewBuilder private var content: some View {
        let _ = ViewEvaluationProbe.current?.record("cell")
        let _ = prepareControls()
        VStack(spacing: 0) {
            Text("CELL").font(.system(size: 12, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).padding(.horizontal, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if currentCellInfo == nil {
                        Text("Select cells in the field.").font(.caption).foregroundColor(secondary)
                    }
                    selectedCellInfo
                }.padding(8).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }.background(Color(red: 0.115, green: 0.118, blue: 0.130))
        .foregroundColor(.white.opacity(0.9)).clipped()
        .accessibilityIdentifier("workspace.cell")
        .environment(\.inspectorNumberSession, editor)
        .onAppear { resetDrafts() }
        .onChange(of: state.workspace.selectedLayerID) { _ in resetDrafts() }
        .onChange(of: currentCellAddress) { _ in resetDrafts() }
        .onChange(of: currentCellInfo?.target) { _ in resetDrafts() }
        .onChange(of: currentScalarValue) { _ in
            if let info = currentCellInfo, let cell = currentCellAddress {
                resetCellValueEditor(cell: cell, info: info)
            }
        }
    }
    private func resetDrafts() {
        // Every selected cell owns a fresh editor draft.  This also clears a
        // routing selection from a different layer/type before it can present
        // a stale switch value in a note or chord cell.
        draft.rebuildForNewSelection()
        cellValueFocused = false
        pendingCellNoteEdit = nil; pendingCellScalarEdit = nil; cellValueRejected = false
        if let info = currentCellInfo, let cell = currentCellAddress {
            resetCellValueEditor(cell: cell, info: info)
        }
    }
    @ViewBuilder private var selectedCellInfo: some View {
        if let presented = cellPresentation {
            let cell = presented.cell, info = presented.info
            section("CELL") {
                VStack(alignment: .leading, spacing: 0) {
                    inspectorTextLine("\(info.ringText) · \(info.angleText)")
                    if state.selectedCells.count > 1 {
                        inspectorRow("Selection", "\(state.selectedCells.count) cells").padding(.top, 6)
                    }
                    if programMemory.value != nil || isProgramValue(info) {
                        InspectorRetainedControlSurface(inspector: inspector, visible: { currentCellInfo.map(isProgramValue) ?? false }, name: "cellProgram", prepare: programMemory.value != nil) {
                            retainedProgramEditor(cell: cell, info: info)
                        }.equatable().frame(height: isProgramValue(info) ? nil : 0)
                            .padding(.top, isProgramValue(info) ? 6 : 0)
                    }
                    if controlPreparation.controlCell != nil || hasValueEditor(info) {
                        InspectorRetainedControlSurface(inspector: inspector, visible: { currentCellInfo.map(hasValueEditor) ?? false }, name: "cellValue", prepare: controlPreparation.controlCell != nil, tracksFields: controlPreparation.controlHasNumbers) {
                            // In the original parent, each ViewBuilder child had
                            // six points of top padding. Keep that spacing explicit
                            // inside the retained native root.
                            VStack(alignment: .leading, spacing: 6) {
                                if let value = currentCellInfo.map({ (cell, $0) }).flatMap({ hasValueEditor($0.1) ? $0 : nil }) ?? controlPreparation.controlCell {
                                    cellValueEditor(cell: value.0, info: value.1)
                                }
                            }
                        }.equatable().frame(height: hasValueEditor(info) ? nil : 0)
                            .padding(.top, hasValueEditor(info) ? 6 : 0)
                    }
                    if let origin = info.origin {
                        inspectorRow("Source", origin == .cellOverride ? "Cell override" : "Layer default")
                            .padding(.top, 6)
                    }
                    if let transition = info.transition {
                        inspectorRow("Transition", transitionName(transition)).padding(.top, 6).help(HoldTransitionHelp.text)
                        if transition == .holdUntilNext || transition == .toggle {
                            Text(HoldTransitionHelp.text).font(.system(size: 9)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if state.workspace.selectedLayer.polarCells.contains(cell) {
                        selectedCellControls(cell: cell)
                        IconActionButton("Reset to layer", symbol: "arrow.uturn.backward") { _ = editor.resetSelectedCellsToLayer() }
                            .help("Remove own values from every selected cell and use the layer default.")
                            .disabled(state.workspace.selectedLayer.isLocked)
                            .padding(.top, 6).inspectorLayoutProbe("cell.reset")
                    }
                }
            }
            .accessibilityIdentifier("inspector.cell.info")
            .modifier(InspectorCellContentVisibility(retaining: controlPreparation.retainsCellContent, visible: currentCellInfo != nil))
        }
    }

    private func prepareControls() {
        controlPreparation.update(state.workspace)
        if programMemory.value == nil { programMemory.value = controlPreparation.program }
    }
    private var cellPresentation: (cell: PolarMetricGridCell, info: SpatialCellInfo)? {
        if let info = currentCellInfo, let cell = currentCellAddress { return (cell, info) }
        return controlPreparation.programCell ?? controlPreparation.controlCell
    }
    private var currentCellInfo: SpatialCellInfo? {
        cellPresentationCache.update(workspace: editor.workspace, selection: editor.selection, locked: editor.isPerformanceLocked)
        return cellPresentationCache.info
    }
    private var currentCellAddress: PolarMetricGridCell? {
        let _ = currentCellInfo
        return cellPresentationCache.cell
    }
    private var currentScalarValue: Double? {
        if case .scalar(let value) = currentCellInfo?.value { return value }
        return nil
    }
    private func isProgramValue(_ info: SpatialCellInfo) -> Bool {
        if case .programChange = info.value { return true }
        return false
    }
    private func hasValueEditor(_ info: SpatialCellInfo) -> Bool {
        switch info.target {
        case .midiNote?, .audioUnitNote?, .midiProgramChange?, .audioUnitProgramChange?: return false
        default: return true
        }
    }
    private var hasCellControls: Bool {
        switch selectedCellTarget {
        case nil, .midiProgramChange?, .audioUnitProgramChange?, .midiNote?, .audioUnitNote?, .midiCC?, .audioUnitCC?: return false
        default: return true
        }
    }

    private var releaseSelectionID: UUID? {
        let layer = state.workspace.selectedLayer
        let ids = state.selectedPolarCells.compactMap { SpatialReleaseLayerPresentation.target(cell: $0, layer: layer) }
        if let first = ids.first { return ids.allSatisfy { $0 == first } ? first : nil }
        if case .releaseLayer(let id) = layer.routings.first?.target { return id }
        return nil
    }

    @ViewBuilder private func cellValueEditor(cell: PolarMetricGridCell, info: SpatialCellInfo) -> some View {
        if info.target == nil {
            Text("Select an output first")
                .font(.system(size: 9))
                .foregroundColor(secondary)
        } else {
            switch info.target {
            case .releaseLayer?:
                inspectorRow("Target", SpatialReleaseLayerPresentation.selectionTitle(in: state))
                Menu(SpatialReleaseLayerPresentation.selectionTitle(in: state)) {
                    ForEach(state.workspace.layers.filter { !state.workspace.controlLayerIDs.contains($0.id) }) { layer in
                        SelectionMenuItem(layer.name, selected: releaseSelectionID == layer.id) { _ = editor.setReleaseLayerTarget(layer.id) }
                    }
                }.help("Release held and toggled notes of the chosen layer on fresh measured entry.")
                    .disabled(state.workspace.selectedLayer.isLocked)
            case .sceneSwitch?:
                inspectorRow("Target", SpatialScenePresentation.selectionTitle(in: state))
                Menu(SpatialScenePresentation.selectionTitle(in: state)) {
                    ForEach(SpatialScenePresentation.choices(in: state)) { choice in
                        SelectionMenuItem(choice.title, selected: choice.isSelected) { _ = editor.setSceneAction(choice.action) }
                    }
                }.help("Choose the scene action for all selected cells.")
                    .disabled(state.workspace.selectedLayer.isLocked)
            case .midiNote?, .audioUnitNote?:
                EmptyView()
            case .midiProgramChange?, .audioUnitProgramChange?: EmptyView()
            case .midiCC?, .audioUnitCC?:
                committedCCValue(cell: cell, info: info)
            case .midiPitchBend?, .audioUnitPitchBend?, .midiChannelPressure?, .audioUnitChannelPressure?, .audioUnitParameter?, .midiEffectParameter?:
                editableCellValueField(cell: cell, placeholder: "Value 0…100 %")
            default:
                inspectorRow("Value", info.valueText ?? "—")
            }
        }
    }

    @ViewBuilder private func retainedProgramEditor(cell: PolarMetricGridCell, info: SpatialCellInfo) -> some View {
        let layerID = state.workspace.selectedLayerID
        let routingID = selectedCellRouting.wrappedValue
        let current: SpatialProgramChange? = {
            if let actual = currentCellInfo, case .programChange(var value) = actual.value {
                if actual.origin != .cellOverride && actual.target?.destination == .midi {
                    value.countsFromOne = editor.programCountingPreference?(layerID) ?? value.countsFromOne
                }
                return value
            }
            return nil
        }()
        if current != nil || programMemory.value != nil {
            InspectorProgramEditor(value: current ?? programMemory.value ?? .init(), selection: Binding(get: {
                guard let info = currentCellInfo, case .programChange(var value) = info.value else { return programMemory.value ?? .init() }
                if info.origin != .cellOverride && info.target?.destination == .midi {
                    value.countsFromOne = editor.programCountingPreference?(layerID) ?? value.countsFromOne
                }
                return value
            }, set: { setCellProgramChange($0, cell: cell, layerID: layerID, routingID: routingID) }), stepSelection: { value, component in
                setCellProgramChange(value, cell: cell, layerID: layerID, routingID: routingID, component: component)
            }, context: "\(layerID):\(cell):\(String(describing: routingID))", rememberCounting: { if currentCellInfo?.target?.destination == .midi { editor.rememberProgramCounting?(layerID, $0) } }).equatable()
            .environment(\.inspectorNumberSession, editor)
            .disabled(current != nil && (state.workspace.selectedLayer.isLocked || state.isPerformanceLocked))
            .onAppear { if let current { programMemory.value = current } }
            .onChange(of: current) { if let value = $0 { programMemory.value = value } }
        }
    }

    private func committedCCValue(cell: PolarMetricGridCell, info: SpatialCellInfo) -> some View {
        let layerID = info.layerID, target = info.target
        let binding = Binding<Int>(get: {
            guard case .scalar(let value) = currentCellInfo?.value else { return 0 }
            return Int((value * 127).rounded())
        }, set: { value in
            guard editor.workspace.selectedLayerID == layerID, editor.selectedPolarCell == cell,
                  selectedCellTarget == target else { return }
            setCellValue(.scalar(Double(value) / 127), cell: cell)
        })
        return CommittedProgramNumberField(title: "Value", value: binding, range: 0...127,
            identifier: "ccValue", context: "\(layerID):\(cell):\(String(describing: target))", placeholder: "Value 0…127",
            step: { binding.wrappedValue = $0 })
            .environment(\.inspectorNumberSession, editor)
    }

    private func editableCellValueField(cell: PolarMetricGridCell, placeholder: String) -> some View {
        let layerID = state.workspace.selectedLayerID
        let target = selectedCellTarget
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Value %").font(.system(size: 10))
                Spacer(minLength: 4)
                TextField(placeholder, text: $cellValueText)
                .textFieldStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 7).frame(height: 25)
                .background(row)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(cellValueRejected ? .red : .clear))
                .cornerRadius(4)
                .focused($cellValueFocused)
                .onSubmit { submitCellValue(cell: cell, layerID: layerID, target: target) }
                .onExitCommand { discardCellValue(cell: cell) }
                .modifier(InspectorFieldAvailability()).frame(width: 86)
            }
            if cellValueRejected {
                Text("Invalid value")
                    .font(.system(size: 9)).foregroundColor(.red)
            }
        }.inspectorLayoutProbe("cell.scalar")
    }

    private func resetCellValueEditor(cell: PolarMetricGridCell, info: SpatialCellInfo) {
        cellValueRejected = false
        switch info.target {
        case .midiCC, .audioUnitCC: break // The native number leaf owns its draft.
        case .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure, .audioUnitParameter, .midiEffectParameter:
            if case .scalar(let value) = info.value { cellValueText = String(Int((value * 100).rounded())) }
            else { cellValueText = "" }
        default:
            // No scalar text field is shown for notes, switches or programs.
            // Keeping this invisible draft avoids a second view invalidation
            // on every round trip; entering a scalar cell always reads it anew.
            break
        }
    }

    private func submitCellValue(cell: PolarMetricGridCell, layerID: UUID, target: SpatialRoutingTarget?) {
        guard editor.selectedPolarCell == cell, editor.workspace.selectedLayerID == layerID else { return }
        guard selectedCellTarget == target else { return }
        guard let target else { cellValueRejected = true; return }
        switch target {
        case .midiNote, .audioUnitNote:
            guard let note = MIDINoteInputParser.parse(cellValueText),
                  let document = SpatialCellNoteDraft.current(cell: cell, in: state) else {
                cellValueRejected = true
                return
            }
            var edit = currentCellNoteEdit(cell: cell, document: document)
            edit.keyboard.setSelectedNotes([note])
            edit.draft.notes = [note]
            pendingCellNoteEdit = edit
            applyCellNoteEdit(cell: cell, document: document)
        case .midiCC, .audioUnitCC:
            guard let value = Double(cellValueText), (0...127).contains(value) else {
                cellValueRejected = true
                return
            }
            setCellValue(.scalar(value / 127), cell: cell)
        case .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure, .audioUnitParameter, .midiEffectParameter:
            guard let value = Double(cellValueText), (0...100).contains(value) else {
                cellValueRejected = true
                return
            }
            setCellValue(.scalar(value / 100), cell: cell)
        default:
            cellValueRejected = true
            return
        }
        cellValueRejected = false
    }

    private func discardCellValue(cell: PolarMetricGridCell) {
        pendingCellNoteEdit = nil
        pendingCellScalarEdit = nil
        if let info = SpatialCellInfo.make(cell: cell, layerID: state.workspace.selectedLayerID, workspace: state.workspace) {
            resetCellValueEditor(cell: cell, info: info)
        }
    }

    private func inspectorRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10))
            Spacer(minLength: 4)
            Text(value).font(.system(size: 10, weight: .medium)).lineLimit(2)
        }
        .padding(.horizontal, 6).frame(minHeight: 23)
        .background(row).cornerRadius(4).inspectorLayoutProbe("cell.metadata")
    }

    private func inspectorTextLine(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 23, alignment: .leading)
            .background(row)
            .cornerRadius(4)
            .contentShape(Rectangle()).inspectorLayoutProbe("cell.address")
    }

    private func transitionName(_ transition: SpatialNoteTransition) -> String {
        switch transition {
        case .retrigger: return "Retrigger"
        case .legato: return "Legato"
        case .overlap(let milliseconds): return "Overlap \(Int(milliseconds.rounded())) ms"
        case .holdUntilNext: return "Hold till next trigger"
        case .toggle: return "Toggle: on / next entry off"
        }
    }

    @ViewBuilder private func selectedCellControls(cell: PolarMetricGridCell) -> some View {
        cellNoteControls(cell: cell)
        if controlPreparation.controlCell != nil || hasCellControls {
            InspectorRetainedControlSurface(inspector: inspector, visible: { currentCellInfo != nil && hasCellControls }, name: "cellControl", prepare: controlPreparation.controlCell != nil, tracksFields: controlPreparation.controlHasNumbers) {
                nonNoteControls(cell: cell)
            }.equatable().frame(height: hasCellControls ? nil : 0).padding(.top, hasCellControls ? 6 : 0)
        }
    }
    @ViewBuilder private func cellNoteControls(cell: PolarMetricGridCell) -> some View {
        let current = SpatialCellNoteDraft.current(cell: cell, in: state)
        if let document = current ?? noteMemory.value {
            VStack(alignment: .leading, spacing: 6) {
                Text(document.source == .cellOverride ? "Cell override" : "Layer value; no override")
                    .font(.system(size: 9)).foregroundColor(secondary)
                PianoKeyboardView(
                    model: cellKeyboardBinding(cell: cell, document: document),
                    velocity: cellVelocityBinding(cell: cell, document: document),
                    transition: cellTransitionBinding(cell: cell, document: document),
                    supportsNoteTransition: false).inspectorLayoutProbe("cell.keyboard")
                HStack(spacing: 4) {
                    assignmentIconButton("checkmark", "Apply assignment", color: .green) {
                        if let current { applyCellNoteEdit(cell: cell, document: current) }
                    }
                    .disabled(state.workspace.selectedLayer.isLocked || currentCellNoteEdit(cell: cell, document: document).keyboard.selectedNotes.isEmpty)
                    assignmentIconButton("xmark", "Discard", color: .red) { pendingCellNoteEdit = nil }
                        .disabled(state.workspace.selectedLayer.isLocked)
                }
                iconSubtleButton("trash", "Remove cell override") { removeCellValue(cell: cell) }
                    .disabled(state.workspace.selectedLayer.isLocked)
            }
            .onAppear { if let current { noteMemory.value = current } }
            .onChange(of: document) { noteMemory.value = $0 }
            .modifier(InspectorContentVisibility(visible: current != nil))
            .padding(.top, current != nil ? 6 : 0)
        }
    }

    @ViewBuilder private func nonNoteControls(cell: PolarMetricGridCell) -> some View {
        switch selectedCellTarget {
        case .midiProgramChange?, .audioUnitProgramChange?: EmptyView()
        case .releaseLayer?:
            Text("Leaving the cell re-arms it. Other layers keep playing.")
                .font(.system(size: 9)).foregroundColor(secondary)
        case .sceneSwitch?:
            Text("Switches immediately on entry. Leaving the cell re-arms it.")
                .font(.system(size: 9)).foregroundColor(secondary)
        case .midiNote(_)?, .audioUnitNote(_, _)?: EmptyView()
        case .boolean(_)?:
            HStack {
                subtleButton("Off") { setCellValue(.boolean(false), cell: cell) }
                subtleButton("On") { setCellValue(.boolean(true), cell: cell) }
            }
        case .midiAllNotesOff(_)?, .audioUnitAllNotesOff(_, _)?:
            Text("Entering this cell releases all held notes for this output.")
                .font(.system(size: 9)).foregroundColor(secondary)
        case .some:
            HStack {
                Text("Value 0–1").font(.system(size: 10))
                Spacer(minLength: 4)
                darkNumberField("Value 0…1", value: cellScalarBinding(cell: cell)).frame(width: 64)
                assignmentIconButton("checkmark", "Apply assignment", color: .green) {
                    setCellValue(.scalar(min(max(cellScalarValue(cell: cell), 0), 1)), cell: cell)
                }
                assignmentIconButton("xmark", "Discard", color: .red) {
                    pendingCellScalarEdit = nil
                }
            }
            .disabled(state.workspace.selectedLayer.isLocked)
        case nil:
            EmptyView()
        }
    }

    private var selectedCellRouting: Binding<UUID?> {
        Binding(
            get: {
                draft.routingID(availableRoutingIDs: state.workspace.selectedLayer.routings.map(\.id))
            },
            set: { draft.selectedRoutingID = $0 }
        )
    }

    private var selectedCellTarget: SpatialRoutingTarget? {
        guard let id = selectedCellRouting.wrappedValue else { return nil }
        return state.workspace.selectedLayer.routings.first { $0.id == id }?.target
    }

    private func currentCellNoteEdit(
        cell: PolarMetricGridCell,
        document: SpatialCellNoteDraft
    ) -> PendingCellNoteEdit {
        if let pendingCellNoteEdit,
           pendingCellNoteEdit.cell == cell,
           pendingCellNoteEdit.baseline == document {
            return pendingCellNoteEdit
        }
        return PendingCellNoteEdit(cell: cell, document: document)
    }

    func noteKeyboard(cell: PolarMetricGridCell, document: SpatialCellNoteDraft) -> PianoKeyboardView {
        PianoKeyboardView(model: cellKeyboardBinding(cell: cell, document: document),
            velocity: cellVelocityBinding(cell: cell, document: document),
            transition: cellTransitionBinding(cell: cell, document: document), supportsNoteTransition: false)
    }
    private func cellKeyboardBinding(
        cell: PolarMetricGridCell,
        document: SpatialCellNoteDraft
    ) -> Binding<PianoKeyboardModel> {
        Binding(
            get: {
                currentCellNoteEdit(cell: cell, document: document).keyboard
            },
            set: { model in
                guard !state.workspace.selectedLayer.isLocked else { return }
                var edit = currentCellNoteEdit(cell: cell, document: document)
                edit.keyboard = model
                edit.draft.notes = model.selectedNotes
                pendingCellNoteEdit = edit
            }
        )
    }

    private func cellVelocityBinding(
        cell: PolarMetricGridCell,
        document: SpatialCellNoteDraft
    ) -> Binding<Double> {
        Binding(
            get: { Double(currentCellNoteEdit(cell: cell, document: document).draft.velocity) },
            set: { value in
                guard !state.workspace.selectedLayer.isLocked else { return }
                var edit = currentCellNoteEdit(cell: cell, document: document)
                edit.draft.velocity = UInt8(clamping: Int(value.rounded()))
                pendingCellNoteEdit = edit
            }
        )
    }

    private func cellTransitionBinding(
        cell: PolarMetricGridCell,
        document: SpatialCellNoteDraft
    ) -> Binding<SpatialNoteTransition> {
        Binding(
            get: { currentCellNoteEdit(cell: cell, document: document).transition },
            set: { value in
                var edit = currentCellNoteEdit(cell: cell, document: document)
                edit.transition = value
                pendingCellNoteEdit = edit
            }
        )
    }

    private func applyCellNoteEdit(cell: PolarMetricGridCell, document: SpatialCellNoteDraft) {
        var edit = currentCellNoteEdit(cell: cell, document: document)
        edit.draft.notes = edit.keyboard.selectedNotes
        guard !edit.draft.notes.isEmpty else { return }
        let value: SpatialCellValue = .chord(notes: edit.draft.notes.sorted(), velocity: edit.draft.velocity)
        let applied: Bool
        if state.selectedCells.count > 1, let target = selectedCellTarget {
            if case .success(.applied) = editor.applyToSelection(.setAction(.init(target: target, value: value))) { applied = true }
            else { applied = false }
        } else { applied = editor.applyCellNotes(edit.draft, cell: cell) }
        if applied {
            pendingCellNoteEdit = nil
        }
    }

    private func cellScalarValue(cell: PolarMetricGridCell) -> Double {
        let document = currentCellScalarValue(cell: cell) ?? 0
        if let pendingCellScalarEdit,
           pendingCellScalarEdit.cell == cell,
           pendingCellScalarEdit.baseline == document {
            return pendingCellScalarEdit.draft
        }
        return document
    }

    private func currentCellScalarValue(cell: PolarMetricGridCell) -> Double? {
        cell == currentCellAddress ? currentScalarValue : nil
    }

    private func cellScalarBinding(cell: PolarMetricGridCell) -> Binding<Double> {
        let layerID = state.workspace.selectedLayerID
        let lastVisibleValue = cellScalarValue(cell: cell)
        return Binding(
            get: {
                guard editor.workspace.selectedLayerID == layerID, editor.selectedPolarCell == cell else { return lastVisibleValue }
                return cellScalarValue(cell: cell)
            },
            set: { value in
                guard editor.workspace.selectedLayerID == layerID, editor.selectedPolarCell == cell,
                      !editor.isPerformanceLocked, !state.workspace.selectedLayer.isLocked,
                      let baseline = currentCellScalarValue(cell: cell) else { return }
                if let existing = pendingCellScalarEdit,
                   existing.cell == cell,
                   existing.baseline == baseline {
                    pendingCellScalarEdit = PendingCellScalarEdit(
                        cell: cell, baseline: baseline, draft: value
                    )
                } else {
                    pendingCellScalarEdit = PendingCellScalarEdit(
                        cell: cell, baseline: baseline, draft: value
                    )
                }
            }
        )
    }

    private func setCellProgramChange(_ value: SpatialProgramChange, cell: PolarMetricGridCell,
                                      layerID: UUID, routingID: UUID?, component: String? = nil) {
        guard editor.workspace.selectedLayerID == layerID, editor.selectedPolarCell == cell,
              selectedCellRouting.wrappedValue == routingID, let routingID,
              let routing = editor.workspace.selectedLayer.routings.first(where: { $0.id == routingID }),
              routing.target.isProgramChange else { return }
        _ = editor.applyToSelection(.setAction(.init(target: routing.target, value: .programChange(value))),
            coalescingKey: component.map { "programChange:\(layerID):\(routingID):\(cell):\($0)" })
    }

    private func setCellValue(_ value: SpatialCellValue, cell: PolarMetricGridCell) {
        guard let routingID = selectedCellRouting.wrappedValue,
              let routing = state.workspace.selectedLayer.routings.first(where: { $0.id == routingID }) else { return }
        _ = editor.applyToSelection(.setAction(.init(target: routing.target, value: value)))
        pendingCellScalarEdit = nil
    }

    private func removeCellValue(cell: PolarMetricGridCell) {
        guard let routingID = selectedCellRouting.wrappedValue,
              let routing = state.workspace.selectedLayer.routings.first(where: { $0.id == routingID }) else { return }
        _ = editor.applyToSelection(.removeActions(target: routing.target))
        pendingCellNoteEdit = nil
    }

    private func assignmentIconButton(
        _ symbol: String,
        _ label: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        AssignmentActionButton(title: label, symbol: symbol, tint: color, action: action)
    }

    private func edit(
        named name: String = "Edit document",
        coalescingKey: String? = nil,
        _ change: (inout SpatialInstrumentWorkspace) -> Void
    ) {
        editor.updateWorkspace(named: name, coalescingKey: coalescingKey, change)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(secondary).inspectorLayoutProbe("section." + title)
            content()
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.1)) }
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
            .buttonStyle(CaptionActionStyle())
            .help(label)
            .iconAccessibility(label)
    }

}

/// Exactly one current cell projection. The owner has already prepared its
/// interaction before publishing selection; no view/layer history is retained.
@MainActor final class InspectorCellPresentationCache {
    private var key: CanvasInspectorPresentation?
    private(set) var cell: PolarMetricGridCell?
    private(set) var info: SpatialCellInfo?
    func update(_ state: MetricCanvasInteractionState) {
        update(workspace: state.workspace, selection: state.selection, locked: state.isPerformanceLocked)
    }
    func update(workspace: SpatialInstrumentWorkspace, selection: CanvasSelection, locked: Bool) {
        let next = CanvasInspectorPresentation(workspace: workspace, selection: selection, locked: locked)
        guard key != next else { return }
        key = next
        ViewEvaluationProbe.current?.record("inspector.cellInfo")
        cell = selection.cells.lazy.filter { $0.layerID == workspace.selectedLayerID }.map(\.cell)
            .min { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }
        info = cell.flatMap { SpatialCellInfo.make(cell: $0, layerID: workspace.selectedLayerID, workspace: workspace) }
        if info == nil { cell = nil }
    }
}
