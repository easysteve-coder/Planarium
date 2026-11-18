import SwiftUI
import PlanariumDomain
import AppKit
import UniformTypeIdentifiers
import SickPLSMonitorKit
import PlanariumPresets
import PlanariumApplication

/// Die Brücke zwischen Ansichtsausschnitt und Presetmodell (SICK-037):
/// meldet jeden Ausschnitt, übernimmt einen geladenen genau einmal und
/// quittiert ihn. **Nur Ansichtszustand** -- Profile, Zonen und
/// Audiosteuerung laufen nicht hierüber.
struct PresetViewportBridge: ViewModifier {
    @ObservedObject var presets: PresetControlModel
    @ObservedObject var spatialInstrument: SpatialInstrumentRuntimeModel

    func body(content: Content) -> some View {
        content
            .onAppear { presets.noteViewport(spatialInstrument.legacyPresetViewport) }
            .onChange(of: spatialInstrument.canvas.viewport) { _ in presets.noteViewport(spatialInstrument.legacyPresetViewport) }
            .onChange(of: presets.viewportToApply) { pending in
                guard let pending else { return }
                spatialInstrument.applyLegacyPresetViewport(pending)
                presets.acknowledgeViewport()
            }
    }
}

/// Die Presetleiste (SICK-037): Liste, Laden, Speichern unter Namen,
/// Löschen. **Diese Ansicht verändert keinen Zustand selbst** -- jede
/// Handlung geht an ``PresetControlModel``, das erst löst, dann setzt
/// und nie startet.
struct PresetBarView: View {
    @ObservedObject var model: PresetControlModel
    var performanceOnly = false
    var aboutInitiallyExpanded = false
    var summaryEditorInitiallyExpanded = false
    @State private var aboutToggled = false
    @State private var submittedLoadConfirmationID: UUID?
    @State private var menuTarget: PresetMenuTarget?

    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("presetBar.body")
        let loadConfirmationID = model.pendingLoadID
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    let target = PresetMenuTarget { name in
                        guard name != model.lastLoadedName else { return }
                        _ = model.load(name)
                    }
                    menuTarget = target
                    PresetSelectionMenu.make(names: model.names, summaries: model.menuSummaries,
                        selected: model.lastLoadedName, target: target).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                } label: {
                    HStack(spacing: 4) {
                        Text(model.lastLoadedName ?? (model.isRecovered ? "Untitled" : "– select –"))
                            .lineLimit(1).truncationMode(.tail)
                        if model.isRecovered {
                            Text("(recovered)").font(.system(size: 11,weight: .semibold)).fixedSize().inspectorLayoutProbe("preset.recovered")
                            Image(systemName: "arrow.counterclockwise.circle").font(.system(size: 14)).accessibilityHidden(true)
                                .help(model.recoveryTooltip).inspectorLayoutProbe("preset.recoverySymbol")
                        } else if model.presentationIsDirty { Circle().fill(.orange).frame(width: 7, height: 7).accessibilityLabel("Unsaved changes") }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                    }.font(.system(size: 11)).padding(.horizontal,6).padding(.vertical,4)
                        .frame(maxWidth: .infinity,minHeight: 24, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                .auditedButtonSurface("Preset selector",font: 11,foreground: model.isRecovered ? StageTheme.amber : .white,background: HelmutChrome.control)
                .accessibilityLabel("Preset")
                .accessibilityValue((model.lastLoadedName ?? "Untitled") + (model.isRecovered ? " (recovered)" : ""))
                .accessibilityIdentifier("presets.picker")
                .help(model.isRecovered ? model.recoveryTooltip : model.lastLoadedName ?? "Select a preset")
                .frame(maxWidth: .infinity)
                if !performanceOnly {
                    IconActionButton("Refresh preset list", symbol: "arrow.clockwise") { model.refresh() }
                        .accessibilityIdentifier("presets.refresh")
                }
            }
            if !performanceOnly {
            HStack {
                IconActionButton("Save preset (⌘S)", symbol: "square.and.arrow.down") { model.requestSave() }
                    .accessibilityIdentifier("presets.save")
                IconActionButton("Save preset as (⌘⇧S)", symbol: "square.and.arrow.down.on.square") { model.beginSaveAs() }
                    .accessibilityIdentifier("presets.save-as")
                IconActionButton("Edit description", symbol: "pencil") { model.editDescription() }
                    .accessibilityIdentifier("presets.summary-editor")
                IconActionButton("Import presets (⌘⇧I)", symbol: "arrow.down.doc") { importPresets() }
                    .accessibilityIdentifier("presets.import")
                IconActionButton("Export preset (⌘⇧E)", symbol: "arrow.up.doc") { exportPreset() }
                    .accessibilityIdentifier("presets.export")
                IconActionButton("Delete preset", symbol: "trash") {
                    if let loaded = model.lastLoadedName {
                        model.requestDelete(loaded)
                    }
                }
                .disabled(model.lastLoadedName == nil || model.lastLoadedName.map(model.isFactoryPreset) == true)
                .accessibilityIdentifier("presets.delete")
                Spacer(minLength: 0)
            }
            if let loaded = model.lastLoadedName {
                Text("Last loaded: \(loaded)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("presets.notice")
            }
            let about = PresetSummaryPresentation(model.loadedSummary)
            if about.isVisible {
                FullRowDisclosure(expanded: Binding(
                    get: { aboutInitiallyExpanded != aboutToggled }, set: { aboutToggled = $0 != aboutInitiallyExpanded }
                ), label: {
                    FieldToolbarIconLabel(title: "About", symbol: "info.circle").help("About this preset").iconAccessibility("About this preset", caption: "About")
                }) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !about.body.isEmpty { Text(about.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                        if !about.source.isEmpty { Text(about.source).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                    }.font(.caption)
                }.accessibilityIdentifier("presets.about")
            }
            }
        }
        .alert(
            loadConfirmationTitle,
            isPresented: Binding(
                get: { model.pendingLoadName != nil },
                set: {
                    // A button already resolved this alert. Its automatic dismissal
                    // must not cancel a newer decision created by that click.
                    if !$0, submittedLoadConfirmationID != loadConfirmationID {
                        model.cancelPendingLoad(confirmationID: loadConfirmationID)
                    }
                }
            )
        ) {
            if !performanceOnly, let lastLoadedName = model.lastLoadedName, !model.isFactoryPreset(lastLoadedName) {
                Button("Save") { submittedLoadConfirmationID = loadConfirmationID; model.resolvePendingLoad(.save, confirmationID: loadConfirmationID) }
            }
            Button("Don't Save", role: .destructive) { submittedLoadConfirmationID = loadConfirmationID; model.resolvePendingLoad(.discard, confirmationID: loadConfirmationID) }
            Button("Cancel", role: .cancel) { submittedLoadConfirmationID = loadConfirmationID; model.resolvePendingLoad(.cancel, confirmationID: loadConfirmationID) }
        } message: {
            if let name = model.pendingLoadName {
                Text("\(model.unsavedChangesDescription). Unsaved musical changes will be replaced when loading \u{201C}\(name)\u{201D}.")
            }
        }
        .alert(
            "Replace preset?",
            isPresented: Binding(
                get: { model.pendingSaveName != nil },
                set: { if !$0 { model.resolvePendingSave(confirmed: false) } }
            )
        ) {
            Button("Replace", role: .destructive) { model.resolvePendingSave(confirmed: true) }
            Button("Cancel", role: .cancel) { model.resolvePendingSave(confirmed: false) }
        } message: {
            Text("The existing preset \u{201C}\(model.pendingSaveName ?? "")\u{201D} will be overwritten.")
        }
        .alert(
            "Delete preset?",
            isPresented: Binding(
                get: { model.pendingDeleteName != nil },
                set: { if !$0 { model.resolvePendingDelete(confirmed: false) } }
            )
        ) {
            Button("Delete", role: .destructive) {
                model.resolvePendingDelete(confirmed: true)
            }
            Button("Cancel", role: .cancel) { model.resolvePendingDelete(confirmed: false) }
        } message: {
            Text("The preset \u{201C}\(model.pendingDeleteName ?? "")\u{201D} will otherwise be kept.")
        }
        .sheet(isPresented: $model.isSaveAsPresented) {
            PresetSaveSheet(model: model)
        }
        .sheet(isPresented: $model.isDescriptionEditorPresented) {
            PresetDescriptionSheet(model: model)
        }
    }

    private var loadConfirmationTitle: String {
        if let lastLoadedName = model.lastLoadedName {
            return "Save changes to \u{201C}\(lastLoadedName)\u{201D}?"
        }
        return "Save unsaved changes?"
    }
    private func exportPreset() {
        guard model.authorizeMutation() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = model.exportFileName
        if panel.runModal() == .OK, let url = panel.url { model.export(to: url) }
    }
    private func importPresets() {
        guard model.authorizeMutation() else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK { model.importFiles(panel.urls) }
    }
}

struct PresetSaveSheet: View {
    @ObservedObject var model: PresetControlModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Preset As").font(.headline)
            TextField("Name", text: $model.draftName).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("presets.name")
            Text("Description").font(.subheadline)
            TextEditor(text: $model.draftSummary).frame(minHeight: 110)
                .accessibilityIdentifier("presets.summary-editor")
            Text("\(model.draftSummary.count)/1000 characters").font(.caption)
                .foregroundColor(model.draftSummary.count > 1000 ? .red : .secondary)
            HStack { Spacer()
                Button("Cancel") { model.isSaveAsPresented = false }
                Button("Save") { model.commitSaveAs() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(minWidth: 360)
    }
}

struct PresetDescriptionSheet: View {
    @ObservedObject var model: PresetControlModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preset Description").font(.headline)
            TextEditor(text: $model.draftSummary).frame(minHeight: 140)
                .accessibilityIdentifier("presets.summary-editor")
            Text("\(model.draftSummary.count)/1000 characters").font(.caption)
                .foregroundColor(model.draftSummary.count > 1000 ? .red : .secondary)
            HStack { Spacer(); Button("Done") { model.isDescriptionEditorPresented = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(minWidth: 360)
    }
}
