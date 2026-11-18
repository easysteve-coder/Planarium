import SwiftUI
import AppKit
import PlanariumApplication
import PlanariumAudio
import PlanariumInput
import PlanariumMIDI
import PlanariumDomain
import PlanariumRuntime
import SickPLSMonitorKit
import PlanariumScannerUI
import SickPLSCommissioningControl
import SickPLSSimulationControl
import SickPLSSetupControl
import PlanariumPresets

struct ContentView: View {
    @State private var presentationVisible = true
    @State private var meterReader = ChannelMeterReader()
    /// Nur die Kanalzahl steuert die Mischpultbreite; das Fenster beobachtet
    /// deshalb nicht das ganze Laufzeitmodell, sondern nur deren Änderung.
    @State private var observedChannelCount: Int?
    @ObservedObject var workspace: WorkspaceControlModel
    let root: PlanariumComposition
    let connection: StandardConnectionControlModel
    let scannerSetup: SetupConsoleModel
    let presets: PresetControlModel
    let spatialInstrument: SpatialInstrumentRuntimeModel
    let audioUnits: AudioCatalogModel
    let audioDevices: AudioOutputDeviceControlModel
    let scannerWorkspace: ScannerWorkspaceModel
    let simulation: SimulationConnectionControlModel
    var providedMeterReader: ChannelMeterReader? = nil
    var canvasPasteboard: NSPasteboard = .general
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("root")
        VStack(spacing: 0) {
            WorkspaceStatusView(input: root.input, simulation: simulation, workspace: workspace,
                presets: presets, instrument: spatialInstrument)
            WorkspaceDocumentNotice(instrument: spatialInstrument)
            Divider()
            GeometryReader { geometry in
                let layout = WorkspaceLayout.forAvailableWidth(Double(geometry.size.width),
                    visibility: workspace.preferences.visibility, mode: workspace.mode,
                    selectedTab: workspace.preferences.inspectorTab, channelCount: observedChannelCount ?? spatialInstrument.document.channels.count)
                let fieldHeight = layout.arrangement == .stacked ? max(500, geometry.size.height * 0.65) : geometry.size.height
                // Stable area identities survive both row and visibility changes.
                // In particular, collapsing Setup never recreates MeasurementPane
                // or reorders its display start/stop hooks.
                ScrollView(.vertical, showsIndicators: layout.arrangement == .stacked) {
                    ZStack(alignment: .topLeading) {
                        ForEach(WorkspaceLayout.Area.allCases, id: \.self) { area in
                            if layout[area].visible {
                                let row = layout[area].row
                                region(area, layout: layout)
                                    .frame(width: CGFloat(layout[area].width), height: row == 0 ? fieldHeight : 800)
                                    .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1) }
                                    .offset(x: CGFloat(layout[area].x), y: row == 0 ? 0 : fieldHeight + CGFloat(row - 1) * 800)
                            }
                        }
                    }.frame(width: geometry.size.width, height: fieldHeight + CGFloat(layout.rows.count - 1) * 800, alignment: .topLeading)
                }
            }
        }
        .environment(\.presentationVisible, presentationVisible)
        .environment(\.fieldToolbarLabels, workspace.preferences.buttonLabels)
        .background(WindowPresentationVisibility { visible in
            root.display.setVisible(visible)
            if presentationVisible != visible { presentationVisible = visible }
        })
        .modifier(PresetViewportBridge(presets: presets, spatialInstrument: spatialInstrument))
        .onAppear {
            if !spatialInstrument.canvas.isPerformanceLocked {
                workspace.applyClockPreferences(to: spatialInstrument)
            }
        }
        .onChange(of: workspace.preferences.clockDirection) { _ in workspace.applyClockPreferences(to: spatialInstrument) }
        .onChange(of: workspace.preferences.clockTargetIDs) { _ in workspace.applyClockPreferences(to: spatialInstrument) }
        .onChange(of: workspace.preferences.clockSourceID) { _ in workspace.applyClockPreferences(to: spatialInstrument) }
        .onChange(of: workspace.preferences.clockSourceName) { _ in workspace.applyClockPreferences(to: spatialInstrument) }
        .onReceive(spatialInstrument.$document.map(\.channels.count).removeDuplicates().dropFirst()) {
            observedChannelCount = $0
        }
        .frame(minWidth: CGFloat(WorkspaceLayout.centerMinimumWidth + 160), minHeight: 480)
        .background(StageTheme.workspace.ignoresSafeArea()).preferredColorScheme(.dark).tint(StageTheme.amber)
        .overlay {
            if workspace.mode == .perform {
                Rectangle().stroke(StageTheme.amber, lineWidth: 3).padding(1.5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
    @ViewBuilder private func region(_ area: WorkspaceLayout.Area, layout: WorkspaceLayout) -> some View {
        switch area {
        case .setup: left
        case .field: field
        case .layers, .cell:
            VStack(spacing: 0) {
                if layout.usesInspectorTabs {
                    Picker("Inspector", selection: Binding(get: { workspace.preferences.inspectorTab }, set: { workspace.selectTab($0) })) {
                        FieldToolbarMenuLabel(title: "Layers", symbol: "square.stack.3d.up").help("Layers").accessibilityLabel("Layers").tag(WorkspaceLayout.InspectorTab.layers)
                        FieldToolbarMenuLabel(title: "Cell", symbol: "square.dashed").help("Cell").accessibilityLabel("Cell").tag(WorkspaceLayout.InspectorTab.cell)
                    }.pickerStyle(.segmented).labelsHidden().padding(8)
                }
                if area == .layers { layers } else { cell }
            }
        case .channelStrip:
            MixerView(instrument: spatialInstrument, audioUnits: audioUnits, host: root.audio,
                midi: root.midi, devices: audioDevices, compact: workspace.mode == .perform, display: root.display,
                meterReader: providedMeterReader ?? meterReader)
        }
    }
    private var left: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SimulationInputSwitchView(simulation: simulation, scannerBar: AnyView(ConnectionBarView(model: connection, scannerSetup: scannerSetup, rate: root.input.profileRateDisplay)), rate: root.input.profileRateDisplay)
                Divider()
                DiagnosticsView(input: root.input, runtime: root.runtime, host: root.audio, midi: root.midi)
                Divider()
                ReferenceMeasurementCardView(coordinator: scannerWorkspace)
                Divider()
                ConnectionEvidenceView(model: connection)
            }.padding()
        }
    }
    private var field: some View {
        VStack(spacing: 4) {
            if workspace.mode == .perform {
                HStack(alignment: .top, spacing: 12) {
                    PresetBarView(model: presets, performanceOnly: true).frame(maxWidth: 360)
                    RoomFitControls(instrument: spatialInstrument)
                }.font(.caption)
            }
            MeasurementPane(display: root.display, instrument: spatialInstrument, simulation: simulation, workspace: workspace,
                            cellPasteboard: canvasPasteboard)
        }.frame(minHeight: 360).padding(12)
    }
    private var layers: some View {
        WorkspaceLayerPane(instrument: spatialInstrument, presets: presets, audioUnits: audioUnits, midi: root.midi)
    }
    private var cell: some View {
        WorkspaceCellPane(instrument: spatialInstrument)
    }
}

private struct WorkspaceLayerPane: View {
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    let presets: PresetControlModel
    let audioUnits: AudioCatalogModel
    let midi: MIDIPortOwner
    var body: some View {
        VStack(spacing: 0) {
            PresetBarView(model: presets).padding(8)
            Divider()
            StableSpatialLayerInspectorView(editor: instrument.canvas,
                audioUnits: audioUnits, midiOutput: midi, spatialInstrument: instrument,
                evaluationCounter: nil).equatable()
        }
    }
}
private struct WorkspaceCellPane: View {
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    var body: some View {
        StableCellInspectorView(editor: instrument.canvas).equatable()
    }
}

/// This is the only view that observes the 25 Hz runtime mailbox.
struct MeasurementPane: View {
    let display: PerformanceDisplayModel
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    let simulation: SimulationConnectionControlModel
    @ObservedObject var workspace: WorkspaceControlModel
    var cellPasteboard: NSPasteboard = .general
    @State private var cells = SpatialActiveCellDisplayModel()
    @AppStorage("planarium.stageSource") private var stageSource = StageSourceChoice.scanner.rawValue
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("measurement")
        VStack(alignment: .leading, spacing: 8) {
            if workspace.editsDeviceFields && workspace.mode == .edit {
                HStack {
                    SceneBarView(instrument: instrument, compact: true)
                    DeviceFieldModeBar(workspace: workspace, fields: workspace.deviceFields)
                }.environment(\.fieldToolbarLabels, workspace.preferences.fieldToolbarLabels)
                    .controlSize(.small)
                    .contextMenu {
                        FieldToolbarLabelMenu(labels: Binding(get: { workspace.preferences.fieldToolbarLabels },
                            set: { workspace.setFieldToolbarLabels($0) }))
                    }
                    .accessibilityIdentifier("field.toolbar")
                DeviceFieldEditorView(model: workspace.deviceFields)
            } else {
                stage
            }
            RuntimeInputBacklogNotice(display: display)
        }
        .onReceive(display.$frame) { frame in
            guard let frame else { return }
            cells.update(frame, workspace: instrument.canvas.workspace)
            instrument.noteDisplay(frame)
        }
        .onAppear { ViewEvaluationProbe.current?.record("measurementAppear"); display.start() }
        .onDisappear { ViewEvaluationProbe.current?.record("measurementDisappear"); display.stop() }
    }
    private var source: StageSourceChoice { StageSourceChoice(rawValue: stageSource) ?? .scanner }
    /// Switched in the header (`StageSourcePicker`); it takes no field height.
    @ViewBuilder private var stage: some View {
        switch source {
        case .scanner: instrumentField
        case .controller: controllerStage
        case .both:
            HStack(spacing: 8) {
                instrumentField
                controllerStage.frame(minWidth: 280, idealWidth: 380, maxWidth: 520)
            }
        }
    }
    private var controllerStage: some View {
        ControllerStageView(display: display, instrument: instrument, stage: instrument.controllerStage, editable: workspace.mode == .edit)
    }
    private var instrumentField: some View {
        DeviceFieldInstrumentView(instrument: instrument, cells: cells, simulation: simulation,
            workspace: workspace, fields: workspace.deviceFields, cellPasteboard: cellPasteboard)
    }
}

private struct RuntimeInputBacklogNotice: View {
    let display: PerformanceDisplayModel
    @State private var status: InputBacklogStatus = .ready
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("input.backlog")
        InputBacklogNotice(status: status)
            .onReceive(display.$inputBacklogStatus.removeDuplicates()) { next in
                if status != next { status = next }
            }
    }
}

struct InputBacklogNotice: View {
    let status: InputBacklogStatus
    var body: some View {
        Text(status.message ?? " ").font(.caption).foregroundColor(.orange)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
            .help(status.message ?? "")
            .accessibilityIdentifier("input.backlog-status")
    }
}

private struct DeviceFieldInstrumentView: View {
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    // Profile ticks belong to the existing live canvas, not this composition.
    let cells: SpatialActiveCellDisplayModel
    let simulation: SimulationConnectionControlModel
    @ObservedObject var workspace: WorkspaceControlModel
    @ObservedObject var fields: DeviceFieldControlModel
    var cellPasteboard: NSPasteboard = .general
    var body: some View {
        CartesianScanFieldView(editor: instrument.canvas, profile: cells.latestProfile,
            activeCellDisplay: cells, spatialInstrument: instrument,
            simulationBadge: AnyView(SimulationInputBadgeView(model: simulation)),
            scannerFlagBits: Binding(get: { workspace.preferences.scannerFlagBits }, set: { workspace.setScannerFlagBits($0) }),
            toolbarLabels: Binding(get: { workspace.preferences.fieldToolbarLabels }, set: { workspace.setFieldToolbarLabels($0) }),
            toolbarScenes: AnyView(SceneBarView(instrument: instrument, compact: true)),
            toolbarDeviceFields: AnyView(DeviceFieldModeBar(workspace: workspace, fields: fields)),
            deviceFieldDrafts: (workspace.mode == .edit ? fields.drafts.showInEdit : fields.drafts.showInPerformance) ? fields.visibleDrafts : [],
            cellPasteboard: cellPasteboard)
    }
}

private struct DeviceFieldModeBar: View {
    @ObservedObject var workspace: WorkspaceControlModel
    @ObservedObject var fields: DeviceFieldControlModel
    var body: some View {
        HStack(spacing: 4) {
            if workspace.mode == .edit {
                IconToggle("Device fields", symbol: "pencil.and.outline", isOn: $workspace.editsDeviceFields)
                    .help("Edit scanner reference fields offline. These fields never play or enter presets.")
            }
            IconToggle("Show device fields", symbol: "eye", isOn: Binding(get: {
                workspace.mode == .edit ? fields.drafts.showInEdit : fields.drafts.showInPerformance
            }, set: { show in fields.update { if workspace.mode == .edit { $0.showInEdit = show } else { $0.showInPerformance = show } } }))
                .font(.caption)
        }
    }
}

/// Scanner, game controller or both in the stage centre. Lives in the header
/// next to the area switches, in their style; available in Perform too.
struct StageSourcePicker: View {
    @AppStorage("planarium.stageSource") private var stored = StageSourceChoice.scanner.rawValue
    var body: some View {
        let selection = StageSourceChoice(rawValue: stored) ?? .scanner
        HStack(spacing: 4) {
            ForEach(StageSourceChoice.allCases, id: \.self) { choice in
                Button { stored = choice.rawValue } label: {
                    FieldToolbarIconLabel(title: choice.caption, symbol: choice.symbol)
                        .frame(width: 36).frame(minHeight: 24)
                        .background(selection == choice ? StageTheme.amber.opacity(0.22) : .clear)
                        .cornerRadius(4)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(choice.title).iconAccessibility(choice.title, caption: choice.caption)
                .accessibilityIdentifier("stage.source.\(choice.rawValue)")
            }
        }
    }
}
