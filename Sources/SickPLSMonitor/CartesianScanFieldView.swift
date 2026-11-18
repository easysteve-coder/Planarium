import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import SickPLSCore
import SickPLSControlCore
import SickPLSMonitorKit
import PlanariumDomain
import PlanariumApplication

/// Deterministic label bounds shared by Canvas and placement tests. Keep the
/// complete text box inside the field, below the legend, and avoid collisions.
enum DetectionOverlayLabelLayout {
    struct Placement { let label: DetectionOverlayPresentation.Label; let rect: CGRect }
    static func probeBounds(_ geometry: MetricCanvasGeometry) -> DetectionProbePresentation.Bounds? {
        let size = geometry.canvasRect.size
        guard size.width > 36, size.height > 78,
              let a = geometry.metricPoint(forScreenPoint: .init(x: 8, y: 60)),
              let b = geometry.metricPoint(forScreenPoint: .init(x: size.width-8, y: size.height-2)) else { return nil }
        return .init(x: min(a.xMeters, b.xMeters)...max(a.xMeters, b.xMeters),
                     y: min(a.yMeters, b.yMeters)...max(a.yMeters, b.yMeters))
    }
    static func place(_ labels: [DetectionOverlayPresentation.Label], geometry: MetricCanvasGeometry) -> [Placement] {
        let area = geometry.canvasRect.insetBy(dx: 8, dy: 8)
        let top = area.minY + 48
        guard area.width > 20, area.maxY - top >= 18 else { return [] }
        var result: [Placement] = []
        for label in labels {
            let anchor = geometry.screenPoint(for: label.point)
            let width = min(area.width, CGFloat(label.text.count) * 7 + 8)
            let x = min(max(anchor.x + 8, area.minX), area.maxX - width)
            let y = min(max(anchor.y - 22, top), area.maxY - 18)
            let rows = (0..<Int((area.maxY - top) / 20)).map { top + CGFloat($0) * 20 }
            var candidates: [CGRect] = []
            for row in rows {
                for column in [x, area.minX, area.maxX-width] {
                    candidates.append(CGRect(x: column, y: row, width: width, height: 18))
                }
            }
            func distance(_ rect: CGRect) -> CGFloat { abs(rect.minX-x) + abs(rect.minY-y) }
            candidates.sort { distance($0) < distance($1) }
            let chosen = candidates.first { candidate in
                candidate.minY >= top && candidate.maxY <= area.maxY &&
                    !result.contains(where: { $0.rect.intersects(candidate) })
            }
            if let rect = chosen { result.append(.init(label: label, rect: rect)) }
        }
        return result
    }
}

struct RoomContourCaptureButton: View {
    @ObservedObject var capture: RoomContourCaptureState
    let instrument: SpatialInstrumentRuntimeModel
    func toggleCapture() {
        if capture.isCapturing { instrument.cancelRoomContourCapture() }
        else { instrument.beginRoomContourCapture() }
    }
    var body: some View {
        IconActionButton(capture.isCapturing ? "Cancel capture" : "Capture room",
                         symbol: capture.isCapturing ? "stop.circle" : "record.circle", action: toggleCapture)
            .fixedSize()
            .accessibilityIdentifier("detection.capture")
    }
}
struct RoomFitControls: View {
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    @ObservedObject private var fitState: RoomFitState
    var showsCapture = true
    init(instrument: SpatialInstrumentRuntimeModel, showsCapture: Bool = true) {
        self.instrument = instrument
        self.fitState = instrument.roomFit
        self.showsCapture = showsCapture
    }
    func fit() { instrument.fitToRoom() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if showsCapture {
                    RoomContourCaptureButton(capture: instrument.contourCapture, instrument: instrument)
                }
                IconActionButton("Fit to room", symbol: "arrow.down.right.and.arrow.up.left", action: fit)
                    .disabled(!fitState.hasContour || instrument.canvas.isDragging)
                    .help(!fitState.hasContour ? "Capture a room contour first."
                        : "Compress all layers towards the scanner to fit the room. One undo step; save the result under a new name.")
                    .accessibilityIdentifier("detection.fit")
            }
            Stepper(value: Binding(get: { fitState.marginCentimeters },
                                   set: { instrument.setRoomFitMargin(centimeters: $0) }), in: 0...50) {
                Text("Margin \(fitState.marginCentimeters) cm").monospacedDigit()
            }.fixedSize()
                .help("Distance from the measured wall. Only applies during this program run.")
                .accessibilityIdentifier("detection.margin")
        }
    }
}
struct RoomFitStatus: View {
    @ObservedObject var fitState: RoomFitState
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let notice = fitState.notice { Text(notice) }
            ForEach(Array(fitState.warnings.messages.enumerated()), id: \.offset) { entry in
                Text(entry.element).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
struct RoomContourCaptureStatus: View {
    @ObservedObject var capture: RoomContourCaptureState
    let contour: SpatialRoomContour?
    static func contourMessage(_ contour: SpatialRoomContour) -> String {
        let restless = contour.restlessBeamCount
        return restless == 0 ? "Contour steady" : "Contour steady · \(restless) restless beam\(restless == 1 ? "" : "s")"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if capture.isCapturing && capture.countdownSeconds == nil {
                ProgressView(value: capture.progress).frame(maxWidth: 180, alignment: .leading)
                Text("\(Int((capture.progress * 100).rounded()))%")
            }
            if let notice = capture.notice, !notice.hasPrefix("Room contour captured") { Text(notice) }
            else if let contour {
                Text(Self.contourMessage(contour))
            }
            else { Text("No room contour captured") }
        }.font(.caption).foregroundColor(.secondary)
    }
}

struct RoomCaptureCountdownOverlay: View {
    @ObservedObject var capture: RoomContourCaptureState
    var body: some View {
        if let seconds = capture.countdownSeconds {
            VStack(spacing: 8) {
                Text("Hands out").font(.title3)
                Text("\(seconds)").font(.system(size: 72, weight: .light, design: .rounded)).monospacedDigit()
            }
            .padding(24).background(StageTheme.canvas.opacity(0.94)).cornerRadius(16)
            .allowsHitTesting(false).accessibilityIdentifier("room.countdown")
        }
    }
}

private enum SpatialBulkPopover: String, Identifiable {
    case note, scalar
    var id: String { rawValue }
}

/// Profile ticks redraw measured geometry. Pickers and controls update only
/// for authoring, viewport or capture changes, keeping them out of the 25 Hz
/// AppKit/SwiftUI update path.
private struct MeasurementControlsIdentity: Equatable, Sendable {
    let grid: MetricSquareGrid
    let confirmationProfiles: Int
    let contourPenActive: Bool
    let tool: MetricCanvasTool
    let clickSelectsArea: Bool
    let hasSelection: Bool
    let mirrored: Bool
    let mergeZones: Bool
    let showRawScan: Bool
    let showsInactiveSceneLayers: Bool
    let scannerFlagBits: Bool
    let width: CGFloat
    let canFit: Bool
    let labels: Bool
    let locked: Bool
    let surfaceMode: Bool
}

/// Ordered, indivisible control groups wrap before exhausting the field width.
/// Fixed group budgets also keep profile ticks out of layout measurement.
enum FieldToolbarLayout {
    enum Group: Int, CaseIterable { case tools, size, viewport, display, scenes, deviceFields, summary }
    static func width(_ group: Group, labels: Bool, surfaces: Bool = false) -> CGFloat {
        switch group {
        case .tools: return labels ? 356 : 245
        case .size: return 140
        case .viewport: return labels ? 228 : 190
        // The mode switch is part of the group; the surface editor also keeps the contour pen here.
        case .display: return (labels ? 256 : 185) + (surfaces ? (labels ? 51 : 37) : 0)
        case .scenes: return labels ? 110 : 90
        case .deviceFields: return labels ? 110 : 90
        case .summary: return 130
        }
    }
    static func rows(width: CGFloat, labels: Bool, performing: Bool, scenes: Bool, deviceFields: Bool, surfaces: Bool = false) -> [[Group]] {
        let groups = Group.allCases.filter {
            if [.tools, .size, .viewport, .display].contains($0) { return !performing }
            if $0 == .scenes { return scenes }
            if $0 == .deviceFields { return deviceFields }
            return true
        }
        var result: [[Group]] = [], row: [Group] = [], used: CGFloat = 0
        for group in groups {
            let next = self.width(group, labels: labels, surfaces: surfaces)
            if !row.isEmpty && used + 8 + next > width {
                result.append(row); row = []; used = 0
            }
            used += (row.isEmpty ? 0 : 8) + next
            row.append(group)
        }
        if !row.isEmpty { result.append(row) }
        return result
    }
}

/// Selection changes refresh only this readout, not every authoring control.
private struct FieldToolbarSummary: View {
    @ObservedObject var editor: CanvasSession
    private var count: String {
        if !editor.selectedCells.isEmpty { return "\(editor.selectedCells.count) selected" }
        let count = editor.workspace.selectedLayer.polarCells.count
        return "\(count) \(count == 1 ? "cell" : "cells")"
    }
    var body: some View {
        Text("\(editor.workspace.selectedLayer.name) · \(count)")
            .font(.caption.monospacedDigit()).lineLimit(1).foregroundColor(.secondary)
            .help("Active layer: \(editor.workspace.selectedLayer.name) · \(editor.workspace.selectedLayer.polarCells.count) cells\(editor.selectedCells.isEmpty ? "" : " · \(editor.selectedCells.count) selected")")
    }
}
private struct DetectionControlsIdentity: Equatable, Sendable {
    let configuration: DetectionConfiguration
    let width: CGFloat
    let contour: SpatialRoomContour?
    let matches: Bool
    let expanded: Bool
    let dragging: Bool
}
private struct FieldFooterIdentity: Equatable, Sendable {
    let width: CGFloat
    let contourPenActive: Bool
    let tool: MetricCanvasTool
    let clickSelectsArea: Bool
    let scannerFlagBits: Bool
    let scatterNotice: String?
    let status: String?
    let boundary: Bool
    let surfaceHelp: String?
}
private struct StableMeasurementContent<Identity: Equatable & Sendable, Content: View>: View, Equatable {
    let identity: Identity
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
}

private final class SurfaceMenuTarget: NSObject {
    let actions: [() -> Void]
    init(actions: [() -> Void]) { self.actions = actions }
    @objc func choose(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

private final class SpatialBulkMenuTarget: NSObject {
    let action: (SpatialCellBulkMenuItem.Kind) -> Void
    let kinds: [SpatialCellBulkMenuItem.Kind]

    init(kinds: [SpatialCellBulkMenuItem.Kind], action: @escaping (SpatialCellBulkMenuItem.Kind) -> Void) {
        self.kinds = kinds
        self.action = action
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard kinds.indices.contains(sender.tag) else { return }
        action(kinds[sender.tag])
    }
}

/// Polare Instrumentfläche mit einer ebenengebundenen Zellauswahl. Gesten,
/// Tastatur und Kontextmenü benutzen denselben reinen Bedienzustand; der
/// Dokumentbesitzer veröffentlicht Änderungen an den bestehenden Laufzeitpfad.
struct CartesianScanFieldView: View {
    @ObservedObject var editor: CanvasSession
    @State var contourPenActive = false
    @State private var contourPenGeometry: MetricCanvasGeometry?
    private var state: MetricCanvasInteractionState { editor.presentation }
    let profile: B0ScanProfile?
    let activeCellDisplay: SpatialActiveCellDisplayModel
    @ObservedObject var spatialInstrument: SpatialInstrumentRuntimeModel
    let simulationBadge: AnyView
    var scannerFlagBits: Binding<Bool> = .constant(false)
    @AppStorage("clickSelectsArea") private var clickSelectsArea = false
    var toolbarLabels: Binding<Bool> = .constant(false)
    var toolbarScenes: AnyView? = nil
    var toolbarDeviceFields: AnyView? = nil
    var deviceFieldDrafts: [DeviceFieldDraft] = []
    var cellPasteboard: NSPasteboard = .general
    private var showsScannerFlags: Bool { scannerFlagBits.wrappedValue }
    private var surfaces: SurfaceEditorModel { spatialInstrument.surfaceEditor }
    private var surfaceMode: Bool { surfaces.mode == .surfaces }
    /// The pointer and the keys belong to the surface editor: its select/draw tools are active, not hand or audition.
    private var surfaceEditing: Bool { surfaceMode && state.effectiveTool == .select && !contourPenActive }
    private func surfaceModifiers(_ flags: NSEvent.ModifierFlags) -> SurfaceModifiers {
        var result: SurfaceModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    @State private var auditionGestureActive = false
    @State private var hasLiveMeasurement = false
    @State private var latestCanvasSize = CGSize.zero
    @State private var bulkPopover: SpatialBulkPopover?
    @State private var bulkError: String?
    @State private var pianoModel = PianoKeyboardModel(octave: 4, selectedNotes: [60])
    @State private var noteVelocity: Double = 100
    @State private var noteTransition: SpatialNoteTransition = .retrigger
    @State private var scalarValue: Double = 0.5
    @State private var menuTarget: SpatialBulkMenuTarget?
    @State private var surfaceMenuTarget: SurfaceMenuTarget?
    @State private var popoverAnchorPoint = CGPoint.zero
    @State private var selectionBeforePrimaryClick: Set<CanvasCellSelection>?
    /// Offline fixtures select their initial disclosure state through this
    /// stable input; user interaction is kept locally below.
    var detectionInitiallyExpanded = false
    var detectionStagePreview = false
    /// Offline rendering forces the same display-only probe used by a hovered
    /// regulator. It exists solely for deterministic visual evidence.
    var forceDetectionProbe = false
    var forceDetectionOverlay: DetectionOverlayControl? = nil
    @State private var detectionToggled = false
    @State private var overlayInteraction = DetectionOverlayInteraction()
    // Intentionally State: only LiveMeasurementCanvas observes draft publications.
    @State var detectionPreview = DetectionCanvasPreview()
    private var isDetectionExpanded: Bool { detectionInitiallyExpanded != detectionToggled }
    private var activeOverlay: DetectionOverlayControl? {
        guard let control = forceDetectionOverlay ?? overlayInteraction.active ?? (forceDetectionProbe ? .probe : nil),
              control.isAvailable(configuration: state.workspace.detectionConfiguration,
                  hasMatchingContour: spatialInstrument.roomContour != nil && spatialInstrument.roomContourMatches,
                  performing: state.isPerformanceLocked) else { return nil }
        return control
    }

    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("field")
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                StableMeasurementContent(identity: controlsIdentity(width: proxy.size.width)) {
                    toolbar(availableWidth: proxy.size.width)
                }.equatable()
                StableMeasurementContent(identity: DetectionControlsIdentity(
                    configuration: state.workspace.detectionConfiguration, width: proxy.size.width,
                    contour: spatialInstrument.roomContour, matches: spatialInstrument.roomContourMatches,
                    expanded: isDetectionExpanded, dragging: state.isDragging)) {
                    detectionControls(availableWidth: proxy.size.width)
                }.equatable()
                field
                    .overlay(alignment: .topLeading) {
                        if state.isPerformanceLocked, state.statusMessage == InstrumentAction.performanceLockReason {
                            Text(InstrumentAction.performanceLockReason).font(.caption).foregroundColor(.orange)
                                .padding(8).background(StageTheme.canvas.opacity(0.95)).padding(8)
                                .accessibilityIdentifier("field.perform-lock-notice")
                        }
                    }
                    .overlay { RoomCaptureCountdownOverlay(capture: spatialInstrument.contourCapture) }
                    .overlay(alignment: .topTrailing) { simulationBadge.padding(8) }
                if !state.isPerformanceLocked {
                StableMeasurementContent(identity: FieldFooterIdentity(width: proxy.size.width, contourPenActive: contourPenActive, tool: state.tool, clickSelectsArea: state.clickSelectsArea,
                    scannerFlagBits: showsScannerFlags, scatterNotice: scanPresentation.scatterNotice,
                    status: state.statusMessage ?? bulkError, boundary: state.moveHitBoundary,
                    surfaceHelp: surfaceEditing ? surfaces.tool.helpLine : nil)) {
                    ScrollView(.vertical, showsIndicators: true) {
                        footer.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: proxy.size.width, height: 130, alignment: .topLeading)
                }.equatable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: clickSelectsArea) { value in editor.perform { $0.clickSelectsArea = value } }

    }

    @ViewBuilder
    private func toolbar(availableWidth: CGFloat) -> some View {
            let _ = ViewEvaluationProbe.current?.record("field.toolbar")
            let labels = toolbarLabels.wrappedValue
            let rows = FieldToolbarLayout.rows(width: availableWidth, labels: labels,
                performing: state.isPerformanceLocked, scenes: toolbarScenes != nil, deviceFields: toolbarDeviceFields != nil, surfaces: surfaceMode)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        ForEach(rows[index], id: \.self) { group in
                            if group == .summary { Spacer(minLength: 0) }
                            toolbarGroup(group)
                                .frame(width: FieldToolbarLayout.width(group, labels: labels, surfaces: surfaceMode), alignment: group == .summary ? .trailing : .leading)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .environment(\.fieldToolbarLabels, labels)
            .controlSize(.small)
            .contextMenu {
                FieldToolbarLabelMenu(labels: toolbarLabels)
            }
            .accessibilityIdentifier("field.toolbar")
    }

    @ViewBuilder private func toolbarGroup(_ group: FieldToolbarLayout.Group) -> some View {
        switch group {
        case .tools: SurfaceToolsGroup(model: surfaces, editor: editor, cells: AnyView(toolSelector))
        case .size: SurfaceGridGroup(model: surfaces, cells: AnyView(sizeConfirmationGroup))
        case .viewport: viewportButtonGroup.buttonStyle(.plain)
        case .display: displayOptions
        case .scenes: toolbarScenes
        case .deviceFields: toolbarDeviceFields
        case .summary:
            if surfaceMode { SurfaceSummaryText(model: surfaces, editor: editor) } else { FieldToolbarSummary(editor: editor) }
        }
    }

    private var displayOptions: some View {
        HStack(spacing: 4) {
            IconToggle("Show inactive scene layers", symbol: "square.3.layers.3d", isOn: $spatialInstrument.showInactiveSceneLayers)
            IconToggle("Merge zones", symbol: "square.grid.2x2", isOn: Binding(get: { state.mergeZones }, set: { value in editor.perform { $0.mergeZones = value } }))
                .disabled(!state.selectedCells.isEmpty)
                .help("Combine touching active cell regions in the scan field display. Stored cells and musical output remain unchanged.")
                .help("Join adjacent cells with the same value. Editing and playing remain cell precise.")
            IconToggle("Show raw scan", symbol: "waveform", isOn: Binding(get: { state.showRawScan }, set: { value in editor.perform { $0.showRawScan = value } }))
                .help("Show the raw measurement for diagnosis, including wall returns.")
          IconToggle("Scanner flag bits", symbol: "flag", isOn: scannerFlagBits)
            .help("Color points in the unfiltered raw scan, including room boundaries, by their raw three-bit value. Flag meanings are unverified.")
            SurfaceModeButton(model: surfaces)
            if surfaceMode { contourPenButton }
        }.font(.caption)
    }

    private var contourPenButton: some View {
        Button { contourPenActive.toggle() } label: {
                FieldToolbarIconLabel(title: "Contour pen", symbol: "pencil.tip")
            }.buttonStyle(.plain).padding(6)
                .foregroundColor(contourPenActive ? .black : .white)
                .background(contourPenActive ? StageTheme.amber : HelmutChrome.control).cornerRadius(4)
                .accessibilityLabel("Contour pen").accessibilityValue(contourPenActive ? "selected" : "not selected")
                .accessibilityIdentifier("field.tool.contourPen")
                .help("Contour pen · drag draws · ⇧ straight line · ⌥ erase")
                .contextMenu { Button("Clear drawn contour") { spatialInstrument.clearDrawnContour() } }
    }

    private var toolSelector: some View {
        HStack(spacing: 4) {
            CanvasToolButtons(selection: toolBinding, selectionEnabled: !contourPenActive)
            if !surfaceMode { contourPenButton }
            if state.tool == .select && !contourPenActive {
                Button {
                    clickSelectsArea.toggle()
                    editor.perform { $0.clickSelectsArea = clickSelectsArea }
                } label: {
                    Image(systemName: clickSelectsArea ? "square.grid.3x3.fill" : "square")
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                        .background(Color.white.opacity(0.08)).cornerRadius(4)
                }.buttonStyle(.plain)
                .accessibilityLabel("Click selects: " + (clickSelectsArea ? "Area" : "Cell"))
                .help("Click selects: " + (clickSelectsArea ? "Area" : "Cell") + " · double-click selects " + (clickSelectsArea ? "Cell" : "Area"))
                .accessibilityIdentifier("field.clickSelectsArea")
            }
        }
    }

    private var sizeConfirmationGroup: some View {
        HStack(spacing: 8) {
            Picker("Cell size", selection: gridSizeBinding) {
                ForEach(MetricSquareGrid.CellSize.allCases, id: \.self) { size in
                    Text(size.displayName).tag(size)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Cell size")
            .fixedSize()
            .help("Sets the scan-field cell size. Fine cells and own values remain unchanged.")
        }
        .fixedSize().captionLayoutMarker(title: "Cell size", caption: "Cell size", labels: false)
    }

    private var viewportButtonGroup: some View {
        HStack(spacing: 4) {
            Button {
                if latestCanvasSize.width > 0, latestCanvasSize.height > 0 {
                    _ = editor.resetViewport(canvasSize: latestCanvasSize)
                } else {
                    editor.resetViewport()
                }
            } label: {
                FieldToolbarIconLabel(title: "Reset view", symbol: "scope")
            }
            .iconAccessibility("Reset view")
            .help("Reset the scan-field viewport.")

            Button {
                guard let profile = activeCellDisplay.latestProfile else { return }
                _ = editor.fitViewport(toMeasurementsOf: profile, canvasSize: latestCanvasSize)
            } label: {
                FieldToolbarIconLabel(title: "Zoom to measurement", symbol: "viewfinder")
            }
            .iconAccessibility("Zoom to measurement")
            .disabled(!canFitToMeasurement)
            .help(canFitToMeasurement ? "Zoom to the current measurement." : "No valid measurement to zoom to.")

            Button { zoomAtCenter(byFactor: 0.8) } label: {
                FieldToolbarIconLabel(title: "Zoom out", symbol: "minus.magnifyingglass")
            }
            .iconAccessibility("Zoom out")
            .help("Zoom out around the field center.")

            Button { zoomAtCenter(byFactor: 1.25) } label: {
                FieldToolbarIconLabel(title: "Zoom in", symbol: "plus.magnifyingglass")
            }
            .iconAccessibility("Zoom in")
            .help("Zoom in around the field center.")

            Button { editor.toggleHorizontalMirror() } label: {
                FieldToolbarIconLabel(title: state.isHorizontallyMirrored ? "Turn off horizontal mirror" : "Mirror horizontally",
                      symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .iconAccessibility(state.isHorizontallyMirrored ? "Turn off horizontal mirror" : "Mirror horizontally")
            .buttonStyle(CaptionActionStyle())
            .tint(state.isHorizontallyMirrored ? .accentColor : .secondary)
            .help("Mirror the scan field horizontally to match the scanner's stage position.")
        }
        .fixedSize()
    }

    private func controlsIdentity(width: CGFloat) -> MeasurementControlsIdentity {
        .init(grid: state.workspace.grid, confirmationProfiles: spatialInstrument.switchConfirmationProfiles, contourPenActive: contourPenActive,
              tool: state.tool, clickSelectsArea: clickSelectsArea, hasSelection: !state.selectedCells.isEmpty,
              mirrored: state.isHorizontallyMirrored, mergeZones: state.mergeZones, showRawScan: state.showRawScan, showsInactiveSceneLayers: spatialInstrument.showInactiveSceneLayers,
              scannerFlagBits: showsScannerFlags, width: width, canFit: canFitToMeasurement,
              labels: toolbarLabels.wrappedValue, locked: state.isPerformanceLocked, surfaceMode: surfaceMode)
    }

    private func detectionControls(availableWidth: CGFloat) -> some View {
        ViewEvaluationProbe.current?.record("field.detection")
        let configuration = state.workspace.detectionConfiguration
        let locked = state.isPerformanceLocked
        return VStack(alignment: .leading, spacing: 6) {
            Button { detectionToggled.toggle(); if !isDetectionExpanded { resetProbe() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: isDetectionExpanded ? "chevron.down" : "chevron.right")
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Detection")
                    Text(isDetectionExpanded ? "Room → Fit → Beams → Groups → Time → Cells" : detectionSummary(configuration))
                        .foregroundColor(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }.font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 24).contentShape(Rectangle())
                    .inspectorLayoutProbe("detection.disclosure")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detection.disclosure")
            .accessibilityLabel(isDetectionExpanded ? "Collapse detection" : "Expand detection")
            if isDetectionExpanded {
            if detectionStagePreview {
                DetectionStagePreview(instrument: spatialInstrument, availableWidth: availableWidth - 16,
                    onEditing: { control, editing in overlayEditing(control)(editing) },
                    onHover: { control, inside in overlayHover(control)(inside) }, preview: detectionPreview)
            } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: availableWidth < 500 ? 150 : 190), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 8) {
                detectionModule("Room", symbol: "house", help: "Capture the empty room contour. The capture is fixed at 5 seconds (125 scans at 25 Hz).") {
                    HStack(alignment: .top, spacing: 10) {
                        RoomContourCaptureButton(capture: spatialInstrument.contourCapture, instrument: spatialInstrument)
                        Text("5 s\n125 scans").font(.caption.monospacedDigit()).foregroundColor(.secondary).fixedSize()
                        DetectionKnob(title: DetectionControlDescriptor.descriptor(.contourTolerance).name,
                                      values: DetectionControlDescriptor.descriptor(.contourTolerance).values,
                                      value: Int(configuration.roomContour.toleranceCentimeters),
                                      defaultValue: DetectionControlDescriptor.descriptor(.contourTolerance).defaultValue,
                                      format: { "\($0) cm" }, help: locked ? InstrumentAction.performanceLockReason :
                                        spatialInstrument.roomContour == nil ? "Capture a room contour first." :
                                        !spatialInstrument.roomContourMatches ? "Capture the room again for the current scanner geometry." :
                                        !configuration.roomContour.isEnabled ? "Enable the room contour first." : "Permitted variation at the captured wall.",
                                      select: { value in updateDetection { $0.roomContour.toleranceCentimeters = UInt16(value) } },
                                      onEditing: overlayEditing(.contourTolerance), onHover: overlayHover(.contourTolerance),
                                      isEnabled: !locked && configuration.roomContour.isEnabled && spatialInstrument.roomContour != nil && spatialInstrument.roomContourMatches,
                                      accessibilityID: "detection.contourTolerance", onPreview: previewDetection(.contourTolerance))
                    }
                    RoomContourCaptureStatus(capture: spatialInstrument.contourCapture, contour: spatialInstrument.roomContour)
                    if !spatialInstrument.roomContourMatches && configuration.roomContour.isEnabled {
                        Text("Room contour does not match scanner settings. Capture it again.").font(.caption).foregroundColor(.red)
                    }
                }
                detectionModule("Fit", symbol: "arrow.down.right.and.arrow.up.left", help: "Fit the current cell layout inside the captured room.") {
                    RoomFitControls(instrument: spatialInstrument, showsCapture: false)
                }
                detectionModule("Beams", symbol: "dot.radiowaves.left.and.right", help: "Virtual MMK applies a spatial minimum to each scanner beam before grouping.") {
                    beamControls(configuration, enabled: !locked)
                }
                detectionModule("Groups", symbol: "circle.grid.3x3", help: "Turn neighbouring beam measurements into detected objects.") {
                    groupControls(configuration, enabled: !locked)
                }
                detectionModule("Time", symbol: "clock", help: "Smooth positions over recent scans and require confirmation before a cell changes.") {
                    timeControls(configuration, enabled: !locked)
                }
                detectionModule("Cells", symbol: "square.grid.2x2", help: "Keep a cell stable near its border and continuous values stable near their last position.") {
                    cellControls(configuration, enabled: !locked)
                }
            }
            }
            }
        }
        .padding(8)
        .background(StageTheme.workspace)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onDisappear(perform: resetProbe)
        .onChange(of: state.isPerformanceLocked) { if $0 { resetProbe() } }
    }

    private func detectionSummary(_ configuration: DetectionConfiguration) -> String {
        let room = spatialInstrument.roomContour.map(RoomContourCaptureStatus.contourMessage) ?? "No room contour"
        return "MMK \(configuration.virtualMMKMode.label) · \(room)"
    }

    @ViewBuilder
    private func detectionModule<Content: View>(_ title: String, symbol: String, help: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                .help(help).accessibilityIdentifier("detection.module.\(title.lowercased())")
                .inspectorLayoutProbe("detection.module." + title)
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(StageTheme.border, lineWidth: 1))
    }

    private func updateDetection(_ change: (inout DetectionConfiguration) -> Void) {
        guard spatialInstrument.authorize(.edit) else { return }
        var next = state.workspace.detectionConfiguration
        change(&next)
        spatialInstrument.updateDetectionConfiguration(next)
    }

    @ViewBuilder private func beamControls(_ configuration: DetectionConfiguration, enabled: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 4)], alignment: .leading, spacing: 5) {
            DetectionRotarySwitch(title: "Virtual MMK", accessibilityTitle: "Virtual MMK sampling", accessibilityID: "detection.mmk", labels: VirtualMMKMode.allCases.map(\.label), index: VirtualMMKMode.allCases.firstIndex(of: configuration.virtualMMKMode) ?? 0, help: "Spatial minimum before grouping.", select: { raw in guard enabled, VirtualMMKMode.allCases.indices.contains(raw) else { return }; updateDetection { $0.virtualMMKMode = VirtualMMKMode.allCases[raw] } }, onHover: detectionProbeHover)
            DetectionKnob(title: "Target width", values: Array(1...5), value: Int(configuration.virtualMMKTargetWidthCentimeters), defaultValue: 2, format: { "\($0) cm" }, help: "Adaptive beam window width; available only in Adaptive mode.", select: { value in updateDetection { $0.virtualMMKTargetWidthCentimeters = UInt8(value) } }, onEditing: overlayEditing(.targetWidth), onHover: overlayHover(.targetWidth), isEnabled: enabled && configuration.virtualMMKMode == .adaptive, accessibilityID: "detection.targetWidth", onPreview: previewDetection(.targetWidth))
            DetectionKnob(title: "Softness", values: Array(stride(from: 0, through: 100, by: 10)), value: Int(configuration.virtualMMKSoftness), defaultValue: 45, format: { $0 == 0 ? "Hard" : "\($0) %" }, help: "Softens the beam-window edge; unavailable at raw 0.5°.", select: { value in updateDetection { $0.virtualMMKSoftness = UInt8(value) } }, onEditing: overlayEditing(.softness), onHover: overlayHover(.softness), isEnabled: enabled && configuration.virtualMMKMode != .raw, accessibilityID: "detection.softness", onPreview: previewDetection(.softness))
        }.disabled(!enabled).help(enabled ? "" : InstrumentAction.performanceLockReason)
    }

    @ViewBuilder private func groupControls(_ configuration: DetectionConfiguration, enabled: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 4)], alignment: .leading, spacing: 5) {
            IconToggle("Grouping", symbol: "circle.grid.3x3", isOn: Binding(get: { configuration.groupingEnabled }, set: { value in updateDetection { $0.groupingEnabled = value } })).disabled(!enabled).help(enabled ? "Group neighbouring beams." : InstrumentAction.performanceLockReason).accessibilityIdentifier("detection.grouping").onHover(perform: detectionProbeHover)
            DetectionKnob(title: "Minimum gap", values: Array(1...30), value: Int(configuration.groupingJumpCentimeters), defaultValue: 10, format: { "\($0) cm" }, help: "Radial distance that separates objects.", select: { value in updateDetection { $0.groupingJumpCentimeters = UInt16(value) } }, onEditing: overlayEditing(.minimumGap), onHover: overlayHover(.minimumGap), isEnabled: enabled && configuration.groupingEnabled, accessibilityID: "detection.minimumGap", onPreview: previewDetection(.minimumGap))
            DetectionKnob(title: "Minimum points", values: Array(1...10), value: configuration.groupingMinimumPoints, defaultValue: 1, format: { "\($0)" }, help: "Few-point groups are discarded.", select: { value in updateDetection { $0.groupingMinimumPoints = value } }, onEditing: overlayEditing(.minimumPoints), onHover: overlayHover(.minimumPoints), isEnabled: enabled && configuration.groupingEnabled, accessibilityID: "detection.minimumPoints", onPreview: previewDetection(.minimumPoints))
            DetectionRotarySwitch(title: "Edge points", accessibilityID: "detection.edgePoints", labels: ["Off", "1", "2"], index: Int(configuration.edgePoints), help: "Removes up to one or two farther end rays per side when the inward radial step exceeds 3 cm. Keeps at least Minimum points; nearer finger rays remain.", select: { value in updateDetection { $0.edgePoints = UInt8(value) } }, onHover: detectionProbeHover, showsEdgePoints: true)
                .disabled(!enabled || !configuration.groupingEnabled)
            DetectionKnob(title: "Core width", values: Array(0...10), value: Int(configuration.coreWidthCentimeters), defaultValue: 3, format: { $0 == 0 ? "Off" : "\($0) cm" }, help: "Playing width around the middle measured beam after Edge points. Only this core feeds the representative, smoothing and cells; the disc keeps the whole object. Target width instead controls the spatial minimum window per beam.", select: { value in updateDetection { $0.coreWidthCentimeters = UInt8(value) } }, onEditing: overlayEditing(.probe), onHover: detectionProbeHover, isEnabled: enabled && configuration.groupingEnabled, accessibilityID: "detection.coreWidth", onPreview: previewDetection(.coreWidth))
            DetectionKnob(title: "Minimum angle", values: Array(stride(from: 0, through: 90, by: 5)), value: configuration.minimumAngleDegrees, defaultValue: 20, format: { $0 == 0 ? "Off" : "\($0)°" }, help: "Angular spacing required between objects.", select: { value in updateDetection { $0.minimumAngleDegrees = value } }, onEditing: overlayEditing(.minimumAngle), onHover: overlayHover(.minimumAngle), isEnabled: enabled, accessibilityID: "detection.minimumAngle", onPreview: previewDetection(.minimumAngle))
            DetectionKnob(title: "Representative", values: Array(0...3), value: [.mean, .nearestPoint, .median, .nearestPointWithOffset].firstIndex(of: configuration.representative) ?? 0, defaultValue: 0, format: { ["Mean", "Nearest", "Median", "Pt + offset"][$0] }, help: "Chooses the point representing each object.", select: { index in updateDetection { $0.representative = [.mean, .nearestPoint, .median, .nearestPointWithOffset][index] } }, onEditing: overlayEditing(DetectionControlDescriptor.descriptor(.representative).overlay), onHover: overlayHover(DetectionControlDescriptor.descriptor(.representative).overlay), isEnabled: enabled, accessibilityID: "detection.representative", onPreview: previewDetection(.representative))
            DetectionKnob(title: "Offset", values: Array(0...10), value: Int(configuration.representativeOffsetCentimeters), defaultValue: 0, format: { "\($0) cm" }, help: "Only applies to Point + offset.", select: { value in updateDetection { $0.representativeOffsetCentimeters = UInt16(value) } }, onEditing: overlayEditing(DetectionControlDescriptor.descriptor(.offset).overlay), onHover: overlayHover(DetectionControlDescriptor.descriptor(.offset).overlay), isEnabled: enabled && configuration.representative == .nearestPointWithOffset, accessibilityID: "detection.offset", onPreview: previewDetection(.offset))
        }
    }

    @ViewBuilder private func timeControls(_ configuration: DetectionConfiguration, enabled: Bool) -> some View {
        let smoothing = SmoothingSwitchPosition(configuration)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 4)], alignment: .leading, spacing: 5) {
            DetectionRotarySwitch(title: "Smoothing", accessibilityTitle: "Smoothing method", accessibilityID: "detection.smoothing", labels: SmoothingSwitchPosition.allCases.map(\.label), index: smoothing.rawValue, help: "Smooth each beam over time.", select: { raw in guard enabled, let position = SmoothingSwitchPosition(rawValue: raw) else { return }; spatialInstrument.updateDetectionConfiguration(position.applied(to: configuration)) }, onHover: overlayHover(.smoothing))
            if case .exponential(let alpha) = configuration.temporalSmoothing {
                DetectionKnob(title: "Weight α", values: Array(1...9), value: Int((alpha * 10).rounded()), defaultValue: 5, format: { String(format: "%.1f", Double($0) / 10) }, help: "Exponential weight of the newest measurement.", select: { tenth in updateDetection { $0.temporalSmoothing = .exponential(alpha: Double(tenth) / 10) } }, onEditing: overlayEditing(.smoothing), onHover: overlayHover(.smoothing), isEnabled: enabled, accessibilityID: "detection.weight", onPreview: previewDetection(.weight))
            } else {
                DetectionKnob(title: "Window", values: Array(2...8), value: smoothingWindow(configuration.temporalSmoothing), defaultValue: 4, format: { "\($0) scans" }, help: "Number of recent scans used by Mean and Median smoothing.", select: { n in updateDetection { if case .median = $0.temporalSmoothing { $0.temporalSmoothing = .median(window: n) } else { $0.temporalSmoothing = .mean(window: n) } } }, onEditing: overlayEditing(.smoothing), onHover: overlayHover(.smoothing), isEnabled: enabled && (smoothing == .mean || smoothing == .median), accessibilityID: "detection.window", onPreview: previewDetection(.window))
            }
            DetectionKnob(title: "Confirmation", values: Array(1...4), value: configuration.cellSelection.confirmationProfiles, defaultValue: 1, format: { "\($0) scan\($0 == 1 ? "" : "s")" }, help: DetectionLatency.confirmationTooltip(profiles: configuration.cellSelection.confirmationProfiles, profileRateHertz: 25), select: { value in updateDetection { $0.cellSelection = .init(boundaryMarginCentimeters: $0.cellSelection.boundaryMarginCentimeters, confirmationProfiles: value) } }, onEditing: overlayEditing(.confirmation), onHover: overlayHover(.confirmation), isEnabled: enabled, accessibilityID: "detection.confirmation", onPreview: previewDetection(.confirmation))
        }.disabled(!enabled).help(enabled ? "" : InstrumentAction.performanceLockReason)
    }

    @ViewBuilder private func cellControls(_ configuration: DetectionConfiguration, enabled: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 4)], alignment: .leading, spacing: 5) {
            DetectionKnob(title: "Snap", values: Array(0...10), value: Int(configuration.cellSelection.boundaryMarginCentimeters), defaultValue: 0, format: { "\($0) cm" }, help: "Resists crossing a cell border.", select: { value in updateDetection { $0.cellSelection = .init(boundaryMarginCentimeters: UInt16(value), confirmationProfiles: $0.cellSelection.confirmationProfiles) } }, onEditing: overlayEditing(.edgeMargin), onHover: overlayHover(.edgeMargin), isEnabled: enabled, showsMagnet: true, accessibilityID: "detection.snap", onPreview: previewDetection(.snap))
            DetectionKnob(title: "Hold margin", values: Array(0...5), value: Int(configuration.continuousBacklashCentimeters), defaultValue: 0, format: { "\($0) cm" }, help: "Keeps continuous values calm near their last position.", select: { value in updateDetection { $0.continuousBacklashCentimeters = UInt16(value) } }, onEditing: overlayEditing(.holdMargin), onHover: overlayHover(.holdMargin), isEnabled: enabled, accessibilityID: "detection.holdMargin", onPreview: previewDetection(.holdMargin))
        }.disabled(!enabled).help(enabled ? "" : InstrumentAction.performanceLockReason)
    }

    private func smoothingWindow(_ value: DetectionTemporalSmoothing) -> Int {
        switch value { case .mean(let n), .median(let n): return min(max(n, 2), 8); default: return 4 }
    }

    private func continuousEditing(_ editing: Bool) {
        if editing { spatialInstrument.beginContinuousEdit() } else { spatialInstrument.endContinuousEdit() }
    }
    private func detectionProbeHover(_ inside: Bool) {
        overlayInteraction.hover(.probe, inside: inside)
    }
    private func overlayHover(_ control: DetectionOverlayControl) -> (Bool) -> Void {
        { inside in overlayInteraction.hover(control, inside: inside) }
    }
    private func overlayEditing(_ control: DetectionOverlayControl) -> (Bool) -> Void {
        { editing in overlayInteraction.edit(control, editing: editing); continuousEditing(editing) }
    }
    private func previewDetection(_ id: DetectionControlDescriptor.ID) -> (Int?) -> Void {
        detectionPreview.action(id, base: state.workspace.detectionConfiguration,
            matchingContour: spatialInstrument.roomContour != nil && spatialInstrument.roomContourMatches,
            performing: state.isPerformanceLocked)
    }
    private func resetProbe() { overlayInteraction.reset(); detectionPreview.update(nil) }
    private var displayContour: SpatialRoomContour? {
        spatialInstrument.roomContourMatches ? spatialInstrument.roomContour : nil
    }
    private var displayProbeFrame: ProfileFrame? {
        activeCellDisplay.frame.sourceFrame
    }

    private func overlayPresentation(control: DetectionOverlayControl?, frame: ProfileFrame?,
                                     probe: DetectionProbePresentation?, bounds: DetectionProbePresentation.Bounds?,
                                     configuration: DetectionConfiguration) -> DetectionOverlayPresentation {
        guard let control else { return .empty }
        let instrument = spatialInstrument.compiledInstrument.previewingDetection(configuration)
        switch control {
        case .probe: return .empty
        case .contourTolerance:
            return .contourTolerance(contour: spatialInstrument.roomContour, matches: spatialInstrument.roomContourMatches,
                configuration: configuration.roomContour, measurements: activeCellDisplay.frame.projectedMeasurements,
                geometry: frame?.geometry)
        case .minimumGap, .minimumPoints, .minimumAngle, .confirmation, .targetWidth, .softness, .representative, .offset:
            return .measured(control: control, frame: frame, instrument: instrument, contour: displayContour,
                confirmation: activeCellDisplay.frame.confirmationProgress)
        case .edgeMargin:
            let layer = state.workspace.selectedLayer
            guard layer.isActive && layer.isVisible else { return .empty }
            return detectionPreview.snapMargins(document: spatialInstrument.document, layerID: layer.id,
                centimeters: configuration.cellSelection.boundaryMarginCentimeters)
        case .holdMargin:
            let layer = state.workspace.selectedLayer
            guard layer.isActive && layer.isVisible else { return .empty }
            return detectionPreview.holdMargins(layer: layer, grid: state.workspace.grid,
                centimeters: configuration.continuousBacklashCentimeters)
        case .smoothing:
            guard let frame else { return .empty }
            return .smoothing(frame: frame, instrument: instrument, contour: displayContour, bounds: bounds)

        }
    }

    private var field: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let geometry = editor.displayGeometry(canvasSize: size)

            ZStack {
                SpatialInstrumentStaticLayer(
                    plan: spatialInstrument.fieldPlan,
                    labels: spatialInstrument.fieldLabels,
                    selectedLayerID: state.workspace.selectedLayerID,
                    mergeZones: state.mergeZones && (state.selectedCells.isEmpty || !state.selection.layerIDs.isEmpty),
                    geometry: geometry, showsCellGrid: !surfaceMode
                )
                .equatable()
                if surfaceMode {
                    SurfaceFieldLayers(model: surfaces, document: spatialInstrument.document, selection: editor.selection.surfaceIDs, geometry: geometry,
                                       showsInactive: spatialInstrument.showInactiveSceneLayers, performing: state.isPerformanceLocked)
                }
                SpatialInstrumentActiveLayer(cells: activeCellDisplay, workspace: state.workspace, geometry: geometry, showsInactiveLayers: spatialInstrument.showInactiveSceneLayers).equatable()
                if let point = spatialInstrument.auditionPoint {
                    Image(systemName: "hand.point.up.left").font(.system(size: 26)).foregroundColor(.yellow)
                        .position(geometry.screenPoint(for: point)).allowsHitTesting(false)
                }
                SpatialInstrumentSelectionLayer(state: state, geometry: geometry, plan: spatialInstrument.fieldPlan).equatable()
                LiveMeasurementCanvas(cells: activeCellDisplay, fitState: spatialInstrument.roomFit, preview: detectionPreview) { (context: inout LiveCanvas, warnings, previewConfiguration) in
                    // The session caches this projection until an editor input changes.
                    let drawingState = state
                    let configuration = previewConfiguration ?? drawingState.workspace.detectionConfiguration
                    let instrument = previewConfiguration.map { spatialInstrument.compiledInstrument.previewingDetection($0) } ?? spatialInstrument.compiledInstrument
                    let presentation = scanPresentation(state: drawingState, configuration: configuration)
                    let control = activeOverlay
                    let frame = control != nil ? displayProbeFrame : nil
                    let bounds = control != nil ? DetectionOverlayLabelLayout.probeBounds(geometry) : nil
                    let probe = (control == .probe || control == .smoothing) ? frame.map {
                        DetectionProbePresentation.make(frame: $0, instrument: instrument, contour: displayContour, bounds: bounds)
                    } : nil
                    let overlay = CanvasTimingProbe.measure("field.overlay") {
                        overlayPresentation(control: control, frame: frame, probe: probe, bounds: bounds, configuration: configuration)
                    }
                    detectionPreview.didRender?(configuration, overlay)
                    drawRoomFitWarnings(warnings, in: &context, geometry: geometry, state: drawingState)
                    drawRoomContour(in: &context, geometry: geometry, presentation: presentation, state: drawingState)
                    CanvasTimingProbe.measure("field.scanDraw") { drawScan(in: &context, geometry: geometry, overlay: overlay, presentation: presentation) }
                    drawDetectionProbe(probe, in: &context, geometry: geometry)
                    drawDetectionOverlay(overlay, probe: probe, in: &context, geometry: geometry)
                    if control == .targetWidth || control == .softness {
                        drawBeamWeight(in: &context, geometry: geometry, configuration: configuration.beams)
                    }
                    drawRepresentative(in: &context, geometry: geometry, presentation: presentation)
                    drawSelectionRectangle(in: &context, state: drawingState)
                }
                if let control = activeOverlay {
                    Label(control.legend, systemImage: control == .contourTolerance ? "house" : "hand.draw")
                        .font(.caption.weight(.medium)).padding(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(.black.opacity(0.62)).clipShape(RoundedRectangle(cornerRadius: 5))
                        .help("Marks follow the current measurement. Probe examples never play notes.")
                        .accessibilityIdentifier("detection.probe.legend")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8).allowsHitTesting(false)
                }
                if state.isPerformanceLocked {
                    PerformanceCellNamesView(cells: activeCellDisplay, workspace: state.workspace)
                        .allowsHitTesting(false)
                }
                DeviceFieldOverlay(drafts: deviceFieldDrafts, viewport: state.viewport, mirrored: state.isHorizontallyMirrored).equatable()
                ScanFieldPointerEvents(
                    onScroll: { event, point in
                        guard !state.isDragging else { return }
                        guard let factor = ScanFieldZoomInput.zoomFactor(for: event) else { return }
                        _ = editor.zoom(byFactor: factor, atScreenPoint: point, canvasSize: size)
                    },
                    onPressedTwoFingerDrag: { translation in
                        _ = editor.panViewport(
                            byScreenX: translation.width,
                            screenY: translation.height
                        )
                    },
                    onSecondaryClick: { point in
                        if surfaceEditing { showSurfaceMenu(at: point, canvasSize: size); return }
                        guard editor.contextMenuSelection(at: point, canvasSize: size) else { return }
                        bulkError = nil
                        showBulkMenu(at: point)
                    },
                    onMagnify: { magnification, point in
                        guard !state.isDragging else { return }
                        guard let factor = ScanFieldZoomInput.zoomFactor(forMagnification: magnification) else { return }
                        _ = editor.zoom(byFactor: factor, atScreenPoint: point, canvasSize: size)
                    },
                    onKeyCommand: { handleCanvasKey($0, canvasSize: size) },
                    onKeyRelease: { if $0.keyCode == 49 { editor.holdHand(false) }; surfaces.keyReleased($0.keyCode) },
                    onPrimaryDoubleClick: { point, flags in
                        handlePrimaryDoubleClick(at: point, canvasSize: size, flags: flags)
                    },
                    onFocusLost: {
                        spatialInstrument.endContourStroke()
                        auditionGestureActive = false
                        spatialInstrument.audition(nil)
                        selectionBeforePrimaryClick = nil
                        surfaces.cancelEverything()
                        editor.holdHand(false)
                        if state.isDragging { _ = editor.handleKey(.escape) }
                    },
                    onPrimaryDrag: { phase, point, flags in
                        switch phase {
                        case .leftMouseDown: beginPrimaryDrag(at: point, canvasSize: size, flags: flags)
                        case .leftMouseDragged: updatePrimaryDrag(to: point, canvasSize: size, flags: flags)
                        case .leftMouseUp: endPrimaryDrag(at: point, canvasSize: size, flags: flags)
                        default: break
                        }
                    },
                    onSecondaryDrag: { phase, point in
                        switch phase {
                        case .rightMouseDown: editor.send(.armPan(point), canvasSize: size)
                        case .rightMouseDragged: editor.send(.drag(point), canvasSize: size)
                        case .rightMouseUp: editor.send(.release(point), canvasSize: size)
                        default: break
                        }
                    },
                    onDeleteCommand: {
                        if contourPenActive { return true }
                        if surfaceEditing { return surfaces.deleteSelection() }
                        return editor.perform(.delete, canvasSize: size)
                    },
                    onSelectAllCommand: {
                        if surfaceEditing { return surfaces.selectAll() }
                        return editor.perform(.selectAll)
                    },
                    isDeleteCommandEnabled: {
                        if surfaceEditing { return !surfaces.selectedSurfaceIDs.isEmpty }
                        return editor.isEnabled(.delete, canvasSize: size)
                    },
                    isSelectAllCommandEnabled: {
                        if surfaceEditing { return true }
                        return editor.isEnabled(.selectAll)
                    },
                    toolName: state.effectiveTool.rawValue,
                    cursor: cursor(for: state.effectiveTool),
                    cursorAtPoint: {
                        if surfaceEditing { surfaces.pointerMoved(to: $0, geometry: editor.displayGeometry(canvasSize: size)) }
                        return cursor(for: state.effectiveTool, at: $0, canvasSize: size)
                    }
                )
            }
            .background(StageTheme.canvas)
            .clipShape(Rectangle())
            .contentShape(Rectangle())
            .onDisappear { spatialInstrument.audition(nil) }
            .onAppear {
                editor.perform { $0.clickSelectsArea = clickSelectsArea }
                latestCanvasSize = size
                spatialInstrument.updateCanvasCommandContext(size: size, profile: profile)
                // Reappearing after a controls/layout rebuild must retain the
                // user's transformation. Only an anchored view follows size.
                _ = editor.followCanvasSize(size)
            }
            .onChange(of: size) {
                latestCanvasSize = $0
                spatialInstrument.updateCanvasCommandContext(size: $0, profile: profile)
                _ = editor.followCanvasSize($0)
            }
            .onChange(of: profile) {
                spatialInstrument.updateCanvasCommandContext(size: latestCanvasSize, profile: $0)
            }
            .onReceive(activeCellDisplay.$frame) { frame in
                spatialInstrument.updateCanvasCommandContext(size: latestCanvasSize, profileFrame: frame.sourceFrame)
                // Only an availability transition affects the controls.
                let available = frame.profile != nil
                if hasLiveMeasurement != available { hasLiveMeasurement = available }
            }
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .position(popoverAnchorPoint)
                    .popover(item: $bulkPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { popover in
                        bulkPopoverView(popover)
                            .padding(12)
                            .frame(width: 300)
                    }
            }
        }
        .frame(minHeight: 360)
        .overlay(Rectangle().stroke(StageTheme.border, lineWidth: 1))
    }

    private var footer: some View {
        let _ = ViewEvaluationProbe.current?.record("field.footer")
        return VStack(alignment: .leading, spacing: 3) {
            if showsScannerFlags { ScannerFlagLegendView(model: activeCellDisplay) }
            if let notice = scanPresentation.scatterNotice {
                Text(notice).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if state.moveHitBoundary {
                Text("Stopped at 2 m / ±90° field edge")
                    .foregroundColor(.orange)
                    .accessibilityIdentifier("field.move-boundary")
            }
            RoomFitStatus(fitState: spatialInstrument.roomFit)
            Text(state.statusMessage ?? bulkError ?? " ")
                    .foregroundColor(.orange).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
                    .help(state.statusMessage ?? bulkError ?? "")
                    .accessibilityIdentifier("field.edit-status")
            Text("Scanner: r = 0 m · ring sectors with radial occlusion · angle −90…+90°")
            Text(contourPenActive ? "Contour pen · drag draws · ⇧ straight line · ⌥ erase" : (surfaceMode && state.effectiveTool == .select ? surfaces.tool.helpLine : state.selectionHelpLine)).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    /// Both the native responder and offline UI tests execute this method.
    @discardableResult
    func handlePrimaryDoubleClick(at point: CGPoint, canvasSize: CGSize, flags: NSEvent.ModifierFlags) -> Bool {
        guard spatialInstrument.authorize(.edit) else { return true }
        guard !contourPenActive, state.effectiveTool == .select else { return false }
        if surfaceMode {
            // A double-click closes a polygon; on a surface it is just two clicks.
            guard surfaces.tool == .polygon else { return false }
            _ = surfaces.finishPolygon(); return true
        }
        // Frame handles keep the press: it starts the resize drag.
        if selectionModifiers(from: flags).isEmpty, editor.selectionHandle(at: point, canvasSize: canvasSize) != nil { return false }
        _ = editor.selectDoubleClick(at: point, canvasSize: canvasSize, modifiers: selectionModifiers(from: flags),
                              selectionBeforeClick: selectionBeforePrimaryClick)
        selectionBeforePrimaryClick = nil
        return true
    }
    @discardableResult
    func handleCanvasKey(_ event: NSEvent, canvasSize: CGSize) -> Bool {
        if event.modifierFlags.intersection([.option, .command, .control]) == .option,
           event.keyCode == 125 || event.keyCode == 126 {
            let amount = (event.modifierFlags.contains(.shift) ? 12 : 1) * (event.keyCode == 126 ? 1 : -1)
            _ = spatialInstrument.applyPitchOperation(.transpose(amount)); return true
        }

        if event.keyCode == 53 { auditionGestureActive = false; spatialInstrument.audition(nil) }
        if event.keyCode == 53, spatialInstrument.isCapturingRoomContour {
            spatialInstrument.cancelRoomContourCapture(); return true
        }
        bulkError = nil
        let modifiers = selectionModifiers(from: event.modifierFlags)
        // Paint and Erase paint cells; the surface editor has no such tool, so the keys must not switch them on unseen.
        if surfaceMode, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let letter = event.charactersIgnoringModifiers?.lowercased(), letter == "b" || letter == "e" {
            surfaces.refuse("Paint and Erase work on cells; use the cell editor (advanced), or draw a surface")
            return true
        }
        if surfaceEditing, handleSurfaceKey(event) { return true }
        if event.keyCode == 49 && !modifiers.contains(.command) {
            editor.holdHand(true); return true
        }
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": _ = editor.perform(.selectAll); return true
            case "z":
                let redo = modifiers.contains(.shift)
                let changed = redo ? spatialInstrument.redo() : spatialInstrument.undo()
                editor.noteHistoryCommand(changed, redo: redo)
                return true
            case "d": _ = editor.duplicateSelection(); return true
            case "c", "x":
                if editor.copySelection(), let data = try? JSONEncoder().encode(state.clipboard) {
                    cellPasteboard.clearContents()
                    cellPasteboard.setData(data, forType: .init("de.planarium.cells"))
                    if event.charactersIgnoringModifiers?.lowercased() == "x" { _ = editor.perform(.delete) }
                }
                return true
            case "v":
                editor.importClipboard([])
                if let data = cellPasteboard.data(forType: .init("de.planarium.cells")),
                   let entries = try? JSONDecoder().decode([CanvasCellCopy].self, from: data) {
                    editor.importClipboard(entries)
                }
                _ = editor.pasteSelection()
                return true
            default: return false
            }
        }
        let key: MetricCanvasKey
        switch event.keyCode {
        case 53: key = .escape
        case 51, 117: if !contourPenActive { _ = editor.perform(.delete, canvasSize: canvasSize) }; return true
        case 123: key = .left
        case 124: key = .right
        case 125: key = .down
        case 126: key = .up
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
        switch key {
        case .selectTool, .paintTool, .eraseTool, .handTool, .auditionTool, .escape:
            contourPenActive = false; spatialInstrument.endContourStroke()
        default: break
        }
        _ = editor.handleKey(key, modifiers: modifiers)
        return true
    }

    private var toolBinding: Binding<MetricCanvasTool> {
        Binding(get: { state.tool }, set: { contourPenActive = false; editor.select(tool: $0) })
    }

    private var gridSizeBinding: Binding<MetricSquareGrid.CellSize> {
        Binding(
            get: { state.workspace.grid.cellSizeOption ?? .fiveCentimeter },
            set: { size in
                _ = editor.requestGridChange(to: size)
            }
        )
    }

    func cursor(for tool: MetricCanvasTool, at point: CGPoint? = nil, canvasSize: CGSize = .zero) -> NSCursor {
        if contourPenActive && !state.isPerformanceLocked { return symbolCursor("pencil.tip", label: "Contour pen") }
        if state.gesture.phase == .panning { return .closedHand }
        if surfaceMode && tool == .select {
            return surfaceCursor(point.map { surfaces.cursor(at: $0, geometry: editor.displayGeometry(canvasSize: canvasSize)) } ??
                                 (surfaces.tool.drawsNewSurfaces ? .crosshair : .arrow))
        }
        if tool == .select {
            let handle = state.draggedSelectionHandle ?? point.flatMap { editor.selectionHandle(at: $0, canvasSize: canvasSize) }
            if let handle {
                switch handle {
                case .inner, .outer: return symbolCursor("arrow.up.and.down", label: "Resize radius")
                case .start, .end: return symbolCursor("arrow.left.and.right", label: "Resize angle")
                case .innerStart, .innerEnd, .outerStart, .outerEnd:
                    return symbolCursor("arrow.up.left.and.arrow.down.right", label: "Resize radius and angle")
                }
            }
            if state.isMovingSelection { return symbolCursor("arrow.up.and.down.and.arrow.left.and.right", label: "Move cells") }
            if let point, let bounds = state.selectionBounds,
               let polar = PolarProjection(geometry: editor.displayGeometry(canvasSize: canvasSize),
                    maximumRadius: editor.selectionMaximumRadiusMeters).point(at: point),
               (bounds.innerRadiusMeters...bounds.outerRadiusMeters).contains(polar.radius),
               (bounds.startBearingDegrees...bounds.endBearingDegrees).contains(polar.bearing) {
                return symbolCursor("arrow.up.and.down.and.arrow.left.and.right", label: "Move cells")
            }
            return .arrow
        }

        let symbol: String
        switch tool {
        case .audition: symbol = "hand.point.up.left"
        case .pan: symbol = state.isDragging ? "hand.raised.fill" : "hand.raised"
        case .select: symbol = "cursorarrow"
        case .paint: symbol = "pencil"
        case .erase: symbol = "delete.left"
        }
        return symbolCursor(symbol, label: tool.label)
    }

    private func symbolCursor(_ symbol: String, label: String) -> NSCursor {
        guard let source = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else {
            return .crosshair
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let image = source.withSymbolConfiguration(configuration) ?? source
        image.isTemplate = false
        image.size = NSSize(width: 22, height: 22)
        return NSCursor(image: image, hotSpot: NSPoint(x: 2, y: 20))
    }

    func beginPrimaryDrag(at point: CGPoint, canvasSize: CGSize, flags: NSEvent.ModifierFlags) {
        if contourPenActive && !state.isPerformanceLocked {
            contourPenGeometry = editor.displayGeometry(canvasSize: canvasSize)
            guard let metric = contourPenGeometry?.metricPoint(forScreenPoint: point) else { return }
            spatialInstrument.beginContourStroke(at: metric,
                straight: flags.contains(.shift), erasing: flags.contains(.option)); return
        }
        auditionGestureActive = state.effectiveTool == .audition && !state.isPerformanceLocked
        if state.effectiveTool == .audition && !state.isPerformanceLocked {
            spatialInstrument.audition(editor.displayGeometry(canvasSize: canvasSize).metricPoint(forScreenPoint: point)); return
        }
        if surfaceEditing {
            surfaces.pointerDown(at: point, geometry: editor.displayGeometry(canvasSize: canvasSize), modifiers: surfaceModifiers(flags)); return
        }
        bulkError = nil
        selectionBeforePrimaryClick = state.selectedCells
        editor.send(.arm(point, modifiers: selectionModifiers(from: flags), brush: false), canvasSize: canvasSize)
    }
    func updatePrimaryDrag(to point: CGPoint, canvasSize: CGSize, flags: NSEvent.ModifierFlags = []) {
        if contourPenActive && !state.isPerformanceLocked {
            if let metric = contourPenGeometry?.metricPoint(forScreenPoint: point) { spatialInstrument.updateContourStroke(to: metric) }; return
        }
        if state.effectiveTool == .audition && !state.isPerformanceLocked {
            guard auditionGestureActive, spatialInstrument.auditionPoint != nil else { return }
            spatialInstrument.audition(editor.displayGeometry(canvasSize: canvasSize).metricPoint(forScreenPoint: point)); return
        }
        if surfaceEditing { surfaces.pointerDragged(to: point, modifiers: surfaceModifiers(flags)); return }
        editor.send(.drag(point), canvasSize: canvasSize)
    }
    func endPrimaryDrag(at point: CGPoint, canvasSize: CGSize, flags: NSEvent.ModifierFlags = []) {
        if contourPenActive {
            if !state.isPerformanceLocked, let metric = contourPenGeometry?.metricPoint(forScreenPoint: point) { spatialInstrument.updateContourStroke(to: metric) }
            spatialInstrument.endContourStroke(); contourPenGeometry = nil; return
        }
        auditionGestureActive = false
        if state.effectiveTool == .audition { spatialInstrument.audition(nil); return }
        if surfaceMode && state.effectiveTool == .select { surfaces.pointerUp(at: point, modifiers: surfaceModifiers(flags)); return }
        editor.send(.release(point), canvasSize: canvasSize)
    }

    private var canFitToMeasurement: Bool {
        guard profile != nil || hasLiveMeasurement, latestCanvasSize.width > 0, latestCanvasSize.height > 0 else { return false }
        return !activeCellDisplay.frame.projectedMeasurements.isEmpty
    }

    private func zoomAtCenter(byFactor factor: Double) {
        guard latestCanvasSize.width > 0, latestCanvasSize.height > 0 else { return }
        _ = editor.zoom(
            byFactor: factor,
            atScreenPoint: CGPoint(x: latestCanvasSize.width / 2, y: latestCanvasSize.height / 2),
            canvasSize: latestCanvasSize
        )
    }

    func performContextAction(_ kind: SpatialCellBulkMenuItem.Kind) {
        guard spatialInstrument.authorize(.edit) else { return }
        bulkError = nil
        switch kind {
        case .selectLayer: _ = editor.selectLayers([state.workspace.selectedLayerID], active: state.workspace.selectedLayerID)
        case .activate: applyBulk(.paint)
        case .paintHere: _ = editor.paintContextCell()
        case .assignNote: openNotePopover()
        case .assignScalar: bulkPopover = .scalar
        case .removeActions: applyBulk(.removeOwnValues)
        case .deactivate: _ = editor.applyToSelection(.deactivate)
        case .erase: _ = editor.perform(.delete)
        case .duplicate: _ = editor.duplicateSelection()
        case .moveToLayer(let id): _ = editor.moveSelection(toLayer: id)
        }
    }

    // MARK: Surface editor input

    /// Keys of the surface editor. Returns whether the key was taken.
    private func handleSurfaceKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.command) {
            switch key {
            case "a": _ = surfaces.selectAll(); return true
            case "d": _ = surfaces.duplicateSelection(); return true
            case "c": _ = surfaces.copySelection(); return true
            case "x": _ = surfaces.cutSelection(); return true
            case "v": _ = surfaces.pasteSelection(); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 53: // Esc drops the sketch first, then the selection.
            if surfaces.cancelEverything() { return true }
            if !surfaces.selectedSurfaceIDs.isEmpty { surfaces.clearSelection(); return true }
            return false
        case 36, 76: return surfaces.polygon != nil ? surfaces.finishPolygon() || true : false
        case 51:
            if surfaces.polygon != nil { _ = surfaces.removeLastPolygonPoint(); return true }
            _ = surfaces.deleteSelection(); return true
        case 117: _ = surfaces.deleteSelection(); return true
        case 123, 124, 125, 126:
            guard !surfaces.selectedSurfaceIDs.isEmpty else { return false }
            let step = flags.contains(.shift) ? 10.0 : 1.0
            var dx = 0.0, dy = 0.0
            switch event.keyCode {
            case 123: dx = -step
            case 124: dx = step
            case 125: dy = -step
            default: dy = step
            }
            if state.isHorizontallyMirrored { dx = -dx }
            return surfaces.nudge(dxCm: dx, dyCm: dy, keyCode: event.keyCode)
        default: break
        }
        guard flags.intersection([.control, .option]).isEmpty, let key, key.count == 1 else { return false }
        if let tool = SurfaceTool.allCases.first(where: { String($0.key) == key }) { surfaces.select(tool: tool); return true }
        return false
    }

    private func surfaceCursor(_ kind: SurfaceCursorKind) -> NSCursor {
        switch kind {
        case .arrow: return .arrow
        case .crosshair: return .crosshair
        case .move: return symbolCursor("arrow.up.and.down.and.arrow.left.and.right", label: "Move surface")
        case .resizeHorizontal: return symbolCursor("arrow.left.and.right", label: "Resize")
        case .resizeVertical: return symbolCursor("arrow.up.and.down", label: "Resize")
        case .resizeDiagonal: return symbolCursor("arrow.up.left.and.arrow.down.right", label: "Resize")
        case .rotate: return symbolCursor("arrow.triangle.2.circlepath", label: "Rotate")
        case .forbidden: return symbolCursor("nosign", label: "Locked")
        }
    }

    /// The context menu of the surface editor: what a click on a surface can do without a handle.
    private func showSurfaceMenu(at point: CGPoint, canvasSize: CGSize) {
        let geometry = editor.displayGeometry(canvasSize: canvasSize)
        guard surfaces.prepareContextMenu(at: point, geometry: geometry) else { return }
        let actions: [(String, () -> Void)] = [
            ("Duplicate", { _ = surfaces.duplicateSelection() }),
            ("Mirror left/right", { _ = surfaces.mirrorSelection() }),
            ("Delete", { _ = surfaces.deleteSelection() })
        ]
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = SurfaceMenuTarget(actions: actions.map(\.1))
        surfaceMenuTarget = target
        for (index, entry) in actions.enumerated() {
            let item = NSMenuItem(title: entry.0, action: #selector(SurfaceMenuTarget.choose(_:)), keyEquivalent: "")
            item.target = target; item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        surfaceMenuTarget = nil
    }

    private func showBulkMenu(at point: CGPoint) {
        popoverAnchorPoint = point
        let items = SpatialCellBulkMenu.items(in: state)
        let menu = NSMenu(), destinations = NSMenu(title: "Move to layer")
        menu.autoenablesItems = false; destinations.autoenablesItems = false
        let target = SpatialBulkMenuTarget(kinds: items.map(\.kind)) { performContextAction($0) }
        menuTarget = target
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: SpatialCellBulkMenu.title(item.kind, in: state),
                action: #selector(SpatialBulkMenuTarget.choose(_:)), keyEquivalent: "")
            menuItem.target = target; menuItem.tag = index; menuItem.isEnabled = item.isEnabled
            if case .moveToLayer = item.kind { destinations.addItem(menuItem) }
            else { menu.addItem(menuItem) }
        }
        if !destinations.items.isEmpty {
            let parent = NSMenuItem(title: "Move to layer", action: nil, keyEquivalent: "")
            parent.submenu = destinations; menu.addItem(parent)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        menuTarget = nil
    }

    private func selectionModifiers(from flags: NSEvent.ModifierFlags) -> SelectionModifiers {
        var modifiers: SelectionModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }

    private func applyBulk(_ operation: SpatialCellBulkOperation) {
        switch editor.applyToSelection(operation) {
        case .success: bulkError = nil
        case .failure(let rejection): bulkError = bulkRejectionMessage(rejection)
        }
    }

    private func bulkPopoverView(_ popover: SpatialBulkPopover) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch popover {
            case .note:
                Text("Assign note/chord").font(.headline)
                PianoKeyboardView(
                    model: $pianoModel, velocity: $noteVelocity, transition: $noteTransition,
                    supportsNoteTransition: state.workspace.supportsNoteTransition,
                    supportsToggle: state.workspace.selectedLayer.routings.allSatisfy { $0.program.supportsToggle },
                    onTransitionChange: setLayerTransition
                )
                HStack(spacing: 4) {
                    popoverIconButton("checkmark", "Apply", color: .green) { applyNotePopover() }
                        .disabled(pianoModel.selectedNotes.isEmpty)
                    popoverIconButton("xmark", "Discard", color: .red) { bulkPopover = nil }
                }
            case .scalar:
                Text("Assign CC value").font(.headline)
                DeferredControlSlider(value: $scalarValue, range: 0...1, step: 0.01, defaultValue: 0)
                Text(String(format: "%.2f", scalarValue)).font(.caption.monospacedDigit())
                HStack(spacing: 4) {
                    popoverIconButton("checkmark", "Apply", color: .green) { applyScalarPopover() }
                    popoverIconButton("xmark", "Discard", color: .red) { bulkPopover = nil }
                }
            }
            if let bulkError { Text(bulkError).foregroundColor(.red).font(.caption) }
        }
    }

    private func popoverIconButton(
        _ symbol: String,
        _ label: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        AssignmentActionButton(title: label, symbol: symbol, tint: color, action: action)
    }

    private func applyNotePopover() {
        guard let target = editor.selectionTarget(notes: true) else {
            bulkError = "No output is assigned to the selected layer."; return
        }
        let notes = pianoModel.selectedNotes.sorted()
        let value: SpatialCellValue = notes.count == 1
            ? .note(number: notes[0], velocity: UInt8(clamping: Int(noteVelocity)))
            : .chord(notes: notes, velocity: UInt8(clamping: Int(noteVelocity)))
        var rejection: SpatialCellBulkRejection?
        let accepted = editor.performEdit(named: "Assign note") { canvas in
            canvas.updateWorkspace { $0.setNoteTransition(noteTransition) }
            switch canvas.applyToSelection(.assignAndActivate(.init(target: target, value: value))) {
            case .success: return true
            case .failure(let error):
                rejection = error
                return false
            }
        }
        bulkError = rejection.map(bulkRejectionMessage)
        if accepted { bulkPopover = nil }
    }

    private func setLayerTransition(_ transition: SpatialNoteTransition) {
        editor.updateWorkspace(named: "Change transition") {
            $0.setNoteTransition(transition)
        }
    }

    private func openNotePopover() {
        noteTransition = state.workspace.popoverNoteTransitionStartValue()
        bulkPopover = .note
    }

    private func applyScalarPopover() {
        guard let target = editor.selectionTarget(notes: false) else {
            bulkError = "No output is assigned to the selected layer."; return
        }
        applyBulk(.assignAndActivate(.init(target: target, value: .scalar(scalarValue))))
        if bulkError == nil { bulkPopover = nil }
    }

    private func bulkRejectionMessage(_ rejection: SpatialCellBulkRejection) -> String {
        switch rejection {
        case .emptySelection: return "No cells selected."
        case .layerLocked: return "The layer is locked."
        case .targetNotRouted: return "The output is not assigned."
        case .valueDoesNotFitTarget: return "The value does not fit the output."
        case .valueOutOfRange: return "The value is outside the allowed range."
        case .addressBudgetExceeded(let limit): return "Address budget exceeded (limit \(limit))."
        case .unsupportedCoordinateMode: return "This edit is only available in polar mode."
        case .noSelectedLayer: return "No layer selected."
        }
    }

    private func drawRoomFitWarnings(_ warnings: SpatialRoomFit.Warnings, in context: inout LiveCanvas, geometry: MetricCanvasGeometry, state: MetricCanvasInteractionState) {
        for cell in warnings.outsideCells {
            let segment = PolarMetricCellSegment(cell: cell, grid: state.workspace.grid)
            let path = polarSegmentPath(for: segment, geometry: geometry)
            guard path.boundingRect.intersects(geometry.canvasRect) else { continue }
            context.fill(path, with: .color(.red.opacity(0.22)))
            context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
        }
    }

    private func drawSelectionRectangle(in context: inout LiveCanvas, state: MetricCanvasInteractionState) {
        guard let selectionRectangle = state.selectionRectangle else { return }
        let path = Path(selectionRectangle)
        context.fill(path, with: .color(Color.accentColor.opacity(0.10)))
        context.stroke(path, with: .color(Color.accentColor), lineWidth: 1)
    }

    private func polarArcPath(
        radiusMeters: Double,
        startBearingDegrees: Double,
        endBearingDegrees: Double,
        geometry: MetricCanvasGeometry
    ) -> Path {
        let span = endBearingDegrees - startBearingDegrees
        let steps = max(12, Int(ceil(abs(span) / 3)))
        var path = Path()
        for step in 0...steps {
            let bearing = startBearingDegrees + span * Double(step) / Double(steps)
            let radians = bearing * .pi / 180
            let point = geometry.screenPoint(for: MetricScanPoint(
                xMeters: sin(radians) * radiusMeters,
                yMeters: cos(radians) * radiusMeters
            ))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private var scanPresentation: ScanFieldPresentation {
        scanPresentation(state: state)
    }

    private func scanPresentation(state: MetricCanvasInteractionState, configuration: DetectionConfiguration? = nil) -> ScanFieldPresentation {
        .init(contour: spatialInstrument.roomFit.fittingContour, matches: spatialInstrument.roomContourMatches,
            configuration: (configuration ?? state.workspace.detectionConfiguration).roomContour,
            showRawScan: state.showRawScan, objects: spatialInstrument.latestDetectionObjects)
    }

    private func drawDetectionProbe(_ probe: DetectionProbePresentation?, in context: inout LiveCanvas, geometry: MetricCanvasGeometry) {
        guard let probe else { return }
        let kept = Set(probe.objects.flatMap(\.measuredOrders))
        let ghostOrders = Set(probe.marks.flatMap { $0.measuredOrders })
        for measurement in probe.measuredPoints where ghostOrders.contains(measurement.order) {
            let point = geometry.screenPoint(for: measurement.point)
            context.fill(Path(ellipseIn: CGRect(x: point.x-1.5, y: point.y-1.5, width: 3, height: 3)),
                         with: .color(kept.contains(measurement.order) ? .cyan.opacity(0.8) : .gray.opacity(0.25)))
        }
        for mark in probe.marks {
            let point = geometry.screenPoint(for: mark.point)
            let size: CGFloat = mark.accepted ? 10 : 8
            let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            context.fill(Path(ellipseIn: rect), with: .color(mark.accepted ? .cyan.opacity(0.88) : .gray.opacity(0.28)))
            if mark.merged {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.purple.opacity(0.9)), lineWidth: 1.5)
            }
        }
        for object in probe.objects {
            drawCore(object, in: &context, geometry: geometry, color: .cyan)

        }
        for representative in probe.representatives {
            let point = geometry.screenPoint(for: representative)
            let radius: CGFloat = 2
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius*2, height: radius*2)), with: .color(.white))
        }
    }

    private func overlayColor(_ tone: DetectionOverlayPresentation.Tone) -> Color {
        switch tone { case .guide: return .mint; case .kept: return .cyan; case .rejected: return .gray.opacity(activeOverlay == .smoothing ? 0.8 : 0.3); case .merged: return .purple }
    }

    /// The metric window remains true to scale. This dimensionless inset makes
    /// even a sub-ray window's exact weight function readable at any zoom.
    private func drawBeamWeight(in context: inout LiveCanvas, geometry: MetricCanvasGeometry, configuration: DetectionBeamsConfiguration) {
        let rect = CGRect(x: max(12, geometry.canvasRect.maxX-178), y: 46, width: 166, height: 64)
        guard geometry.canvasRect.contains(rect) else { return }
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.black.opacity(0.8)))
        var path = Path()
        path.move(to: .init(x: rect.minX+10, y: rect.maxY-8))
        for index in 0...48 {
            let fraction = Double(index) / 24 - 1
            let weight = configuration.virtualMMKWeight(fractionOfHalfWidth: fraction)
            path.addLine(to: .init(x: rect.minX+10+CGFloat(index)*146/48, y: rect.maxY-8-CGFloat(weight)*30))
        }
        path.addLine(to: .init(x: rect.maxX-10, y: rect.maxY-8)); path.closeSubpath()
        context.fill(path, with: .color(.mint.opacity(0.65)))
        context.stroke(path, with: .color(.mint), lineWidth: 1)
        context.draw(text: "Window weight · \(configuration.virtualMMKSoftness)%", font: .system(size: 10, weight: .medium),
            color: .white, at: .init(x: rect.midX, y: rect.minY+10))
    }

    private func drawDetectionOverlay(_ overlay: DetectionOverlayPresentation, probe: DetectionProbePresentation?, in context: inout LiveCanvas, geometry: MetricCanvasGeometry) {
        for shape in overlay.shapes {
            var path = Path()
            for (index, point) in shape.points.enumerated() {
                let screen = geometry.screenPoint(for: point)
                if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
            }
            if shape.isClosed { path.closeSubpath() }
            if shape.fillOpacity > 0 { context.fill(path, with: .color(overlayColor(shape.tone).opacity(shape.fillOpacity))) }
            context.stroke(path, with: .color(overlayColor(shape.tone).opacity(shape.strokeOpacity)), lineWidth: shape.lineWidth)
            if activeOverlay == .smoothing {
                for value in shape.points.suffix(1) {
                    let point = geometry.screenPoint(for: value)
                    let radius = shape.lineWidth
                    context.fill(Path(ellipseIn: CGRect(x: point.x-radius, y: point.y-radius, width: radius*2, height: radius*2)),
                        with: .color(overlayColor(shape.tone).opacity(shape.strokeOpacity)))
                }
            }
        }
        var labels = overlay.labels
        if let probe, activeOverlay != .targetWidth && activeOverlay != .softness {
            for index in stride(from: 0, to: probe.marks.count, by: 4) {
                let point = probe.marks[index].point
                labels.append(.init(point: point, text: String(format: "%.2f m", hypot(point.xMeters, point.yMeters)), tone: .guide))
            }
        }
        for placement in DetectionOverlayLabelLayout.place(labels, geometry: geometry) {
            context.fill(Path(roundedRect: placement.rect, cornerRadius: 3), with: .color(.black.opacity(0.65)))
            context.draw(text: placement.label.text, font: .monospaced(size: 10, weight: .semibold),
                color: placement.label.tone == .rejected ? .orange : overlayColor(placement.label.tone),
                at: .init(x: placement.rect.minX+4, y: placement.rect.minY+2), anchor: .topLeading)
        }
    }

    private func drawCore(_ object: DetectionObject, in context: inout LiveCanvas, geometry: MetricCanvasGeometry, color: Color) {
        guard !object.coreStrip.isEmpty else { return }
        let center = geometry.screenPoint(for: object.center)
        let diameter = object.diameterMeters / geometry.viewport.metersPerPoint
        var strip = Path()
        for (index, point) in object.coreStrip.enumerated() {
            if index == 0 { strip.move(to: geometry.screenPoint(for: point)) }
            else { strip.addLine(to: geometry.screenPoint(for: point)) }
        }
        strip.closeSubpath()
        context.withClip(Path(ellipseIn: CGRect(x: center.x-diameter/2, y: center.y-diameter/2, width: diameter, height: diameter))) {
            $0.fill(strip, with: .color(color.opacity(0.35)))
        }
    }

    private func drawScan(in context: inout LiveCanvas, geometry: MetricCanvasGeometry, overlay: DetectionOverlayPresentation, presentation: ScanFieldPresentation) {
        for object in presentation.objects {
            let center = geometry.screenPoint(for: object.center)
            let diameter = object.diameterMeters / geometry.viewport.metersPerPoint
            context.fill(Path(ellipseIn: CGRect(x: center.x-diameter/2, y: center.y-diameter/2,
                width: diameter, height: diameter)), with: .color(StageTheme.amberBright.opacity(0.75)))
            drawCore(object, in: &context, geometry: geometry, color: .white)
            let point = geometry.screenPoint(for: object.representative.point)
            let markerSize = min(6, max(1, diameter * 0.25))
            context.fill(Path(ellipseIn: CGRect(x: point.x-markerSize/2, y: point.y-markerSize/2,
                width: markerSize, height: markerSize)), with: .color(.white))
        }
        guard presentation.showsRawScan || showsScannerFlags || !overlay.pointTones.isEmpty else { return }
        // Diagnostic raw mode deliberately includes wall points.
        let points = activeCellDisplay.frame.projectedMeasurements
        var previous: ProjectedScanMeasurement?
        var path = Path()
        var dots = Path()
        let uniformColor = !showsScannerFlags && overlay.pointTones.isEmpty
        for measurement in points {
            if activeOverlay != .contourTolerance, !overlay.pointTones.isEmpty, overlay.pointTones[measurement.order] == nil { continue }
            let point = geometry.screenPoint(for: measurement.point)
            if overlay.pointTones.isEmpty && previous?.order == measurement.order-1 { path.addLine(to: point) }
            else { path.move(to: point) }
            let dot = CGRect(x: point.x-3, y: point.y-3, width: 6, height: 6)
            if uniformColor {
                // A raw scan has one opaque color. Submit its discs together
                // as one fill instead of one per ray.
                dots.addEllipse(in: dot)
            } else {
                let color = overlay.pointTones[measurement.order].map(overlayColor) ??
                    (showsScannerFlags ? ScannerFlagPalette.colors[ScannerFlagPresentation.paletteIndex(measurement)] : StageTheme.amberBright)
                context.fill(Path(ellipseIn: dot), with: .color(color))
            }
            previous = measurement
        }
        if uniformColor { context.fill(dots, with: .color(StageTheme.amberBright)) }
        context.stroke(path, with: .color(showsScannerFlags ? Color.gray.opacity(0.45) : StageTheme.amberBright), lineWidth: 1.8)
    }

    private func drawRoomContour(in context: inout LiveCanvas, geometry: MetricCanvasGeometry, presentation: ScanFieldPresentation, state: MetricCanvasInteractionState) {
        var path = Path(), continuing = false
        for value in presentation.contour {
            guard let value else { continuing = false; continue }
            let point = geometry.screenPoint(for: value)
            if continuing { path.addLine(to: point) } else { path.move(to: point) }
            continuing = true
        }
        context.stroke(path, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        for index in restlessContourIndexes(state: state) {
            guard presentation.contour.indices.contains(index), let value = presentation.contour[index] else { continue }
            let point = geometry.screenPoint(for: value)
            context.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)),
                         with: .color(.orange.opacity(0.8)))
        }
    }

    private func restlessContourIndexes(state: MetricCanvasInteractionState) -> [Int] {
        guard state.workspace.detectionConfiguration.roomContour.isEnabled,
              spatialInstrument.roomContourMatches,
              let contour = spatialInstrument.roomContour else { return [] }
        return contour.restlessBeamIndexes
    }

    private func drawRepresentative(in context: inout LiveCanvas, geometry: MetricCanvasGeometry, presentation: ScanFieldPresentation) {
        guard presentation.objects.isEmpty else { return }
        guard let representative = spatialInstrument.latestDetectionRepresentative else { return }
        let point = geometry.screenPoint(for: representative.point)
        context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(.white))
    }

    private func drawAxes(
        in context: inout GraphicsContext,
        size: CGSize,
        geometry: MetricCanvasGeometry
    ) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: geometry.canvasBaselineY))
        baseline.addLine(to: CGPoint(x: size.width, y: geometry.canvasBaselineY))
        context.stroke(baseline, with: .color(Color.primary.opacity(0.45)), lineWidth: 1)

        let origin = geometry.screenPoint(for: MetricScanPoint(xMeters: 0, yMeters: 0))
        let marker = CGRect(x: origin.x - 4, y: origin.y - 4, width: 8, height: 8)
        if marker.intersects(geometry.canvasRect) {
            context.fill(Path(ellipseIn: marker), with: .color(StageTheme.amber))
        }
    }

}

/// The sole high-rate presentation in the field hierarchy, drawn natively.
/// Profiles and regulator drafts mark only this layer for display; SwiftUI
/// re-installs the painter when editor inputs change (one `canvasBody`).
private struct LiveMeasurementCanvas: NSViewRepresentable {
    let cells: SpatialActiveCellDisplayModel
    let fitState: RoomFitState
    let preview: DetectionCanvasPreview
    let draw: (inout LiveCanvas, SpatialRoomFit.Warnings, DetectionConfiguration?) -> Void
    func makeCoordinator() -> LiveLayerSubscriptions { LiveLayerSubscriptions() }
    func makeNSView(context: Context) -> LiveLayerView { LiveLayerView() }
    func updateNSView(_ view: LiveLayerView, context: Context) {
        ViewEvaluationProbe.current?.record("canvasBody")
        context.coordinator.redraw(view, on: [cells.objectWillChange.eraseToAnyPublisher(),
                                              fitState.objectWillChange.eraseToAnyPublisher(),
                                              preview.objectWillChange.eraseToAnyPublisher()],
                                   sources: [cells, fitState, preview])
        view.isPresenting = context.environment.presentationVisible
        let fitState = fitState, preview = preview, draw = draw
        view.paint = { canvas in
            ViewEvaluationProbe.current?.record("canvas")
            CanvasTimingProbe.measure("field.liveDraw") { draw(&canvas, fitState.warnings, preview.configuration) }
        }
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: LiveLayerView, coordinator: LiveLayerSubscriptions) { coordinator.cancel() }
}

/// Measured and held cells of one display frame, deduplicated as a pair so a
/// frame changing both causes one redraw.
struct ActiveCellPair: Equatable {
    var hands: [UUID: Set<PolarMetricGridCell>]
    var held: [UUID: Set<PolarMetricGridCell>]
    init(_ frame: SpatialDisplayFrame) { hands = frame.allHands; held = frame.heldCells }
}

/// Active fill changes with measured cell identity, not with profile sequence.
/// Drawn natively: a cell change marks only this layer for display.
struct SpatialInstrumentActiveLayer: NSViewRepresentable, Equatable {
    let cells: SpatialActiveCellDisplayModel
    let workspace: SpatialInstrumentWorkspace
    let geometry: MetricCanvasGeometry
    let showsInactiveLayers: Bool
    init(cells: SpatialActiveCellDisplayModel, workspace: SpatialInstrumentWorkspace, geometry: MetricCanvasGeometry, showsInactiveLayers: Bool = true) {
        self.showsInactiveLayers = showsInactiveLayers
        self.cells = cells; self.workspace = workspace; self.geometry = geometry
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.showsInactiveLayers == rhs.showsInactiveLayers && lhs.cells === rhs.cells && lhs.workspace.grid == rhs.workspace.grid &&
            lhs.workspace.layers == rhs.workspace.layers && lhs.geometry == rhs.geometry
    }
    @MainActor final class Coordinator {
        private(set) var pair = ActiveCellPair(SpatialDisplayFrame(profile: nil, activeCells: [:]))
        private var source: ObjectIdentifier?
        private var subscription: AnyCancellable?
        /// The delivered value is stored: `@Published` emits before it assigns.
        func observe(_ cells: SpatialActiveCellDisplayModel, view: LiveLayerView) {
            guard source != ObjectIdentifier(cells) else { return }
            source = ObjectIdentifier(cells)
            pair = ActiveCellPair(cells.frame)
            subscription = cells.$frame.map(ActiveCellPair.init).removeDuplicates().dropFirst().sink { [weak self, weak view] next in
                MainActor.assumeIsolated {
                    guard let self, self.pair != next else { return }
                    self.pair = next; view?.needsDisplay = true
                }
            }
        }
        func cancel() { subscription = nil; source = nil }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> LiveLayerView { LiveLayerView() }
    func updateNSView(_ view: LiveLayerView, context: Context) {
        ViewEvaluationProbe.current?.record("field.activeBody")
        let coordinator = context.coordinator
        coordinator.observe(cells, view: view)
        view.isPresenting = context.environment.presentationVisible
        let workspace = workspace, geometry = geometry, showsInactiveLayers = showsInactiveLayers
        view.paint = { [weak coordinator] canvas in
            guard let coordinator else { return }
            ViewEvaluationProbe.current?.record("field.activeDraw")
            Self.drawActiveCells(in: &canvas, cells: coordinator.pair, workspace: workspace, geometry: geometry,
                                 showsInactiveLayers: showsInactiveLayers)
        }
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: LiveLayerView, coordinator: Coordinator) { coordinator.cancel() }

    static func drawActiveCells(
        in context: inout LiveCanvas, cells: ActiveCellPair, workspace: SpatialInstrumentWorkspace,
        geometry: MetricCanvasGeometry, showsInactiveLayers: Bool
    ) {
        let activeCells = cells.hands, heldCells = cells.held
        let audible = SpatialLayerAudibility.audibleIDs(workspace.layers.map { ($0.id, $0.isActive, $0.isSoloed) })
        for layer in workspace.layers where showsInactiveLayers || (layer.isVisible && audible.contains(layer.id)) {
            let hands = activeCells[layer.id] ?? []
            for cell in (heldCells[layer.id] ?? []).union(hands) {
            let isHeld = !hands.contains(cell)
            // Perform suppresses hidden/inactive ink; Edit retains its existing
            // measured/held indicators. Musical release rules stay independent.
            let segment = PolarMetricCellSegment(cell: cell, grid: workspace.grid)
            let path = polarSegmentPath(for: segment, geometry: geometry)
            guard path.boundingRect.intersects(geometry.canvasRect) else { continue }
            let color = Color(
                red: layer.color.red, green: layer.color.green,
                blue: layer.color.blue, opacity: 1
            )
            context.fill(path, with: .color(color.opacity(isHeld ? 0.35 : 1)))
            context.stroke(path, with: .color(color), lineWidth: isHeld ? 2 : 4)
            if heldCells[layer.id]?.contains(cell) == true {
                let middle = geometry.screenPoint(for: segment.point(radiusMeters: segment.midpoint.radiusMeters, bearingDegrees: segment.midpoint.bearingDegrees))
                let name = layer.name.count > 22 ? String(layer.name.prefix(21)) + "…" : layer.name
                let width = min(180.0, Double(name.count) * 6 + 38)
                let x = min(max(8, middle.x + 8), max(8, geometry.canvasRect.maxX - width - 8))
                let y = min(max(12, middle.y - 16), geometry.canvasRect.maxY - 12)
                context.fill(Path(CGRect(x: x - 4, y: y - 9, width: width, height: 18)), with: .color(StageTheme.canvas.opacity(0.9)))
                context.draw(text: "\(name) · held", font: .system(size: 11, weight: .semibold), color: .white,
                    at: CGPoint(x: x, y: y), anchor: .leading)
            }
            }
        }
    }

}

/// Selection geometry belongs to editor changes, independently of live scans.
struct SpatialInstrumentSelectionLayer: View, Equatable {
    private enum SelectionInk { case cell, preview, frame, handle, culled }
    @Environment(\.presentationVisible) private var presentationVisible
    let state: MetricCanvasInteractionState
    let geometry: MetricCanvasGeometry
    let plan: SpatialFieldPlan?
    let planIdentity: UUID?
    let displayedLayerIDs: Set<UUID>?
    init(state: MetricCanvasInteractionState, geometry: MetricCanvasGeometry, plan: SpatialFieldPlan? = nil) {
        self.state = state; self.geometry = geometry; self.plan = plan; planIdentity = plan?.identity
        let audible = SpatialLayerAudibility.audibleIDs(state.workspace.layers.map { ($0.id, $0.isActive, $0.isSoloed) })
        displayedLayerIDs = (state.isPerformanceLocked || plan?.showsInactiveLayers == false)
            ? Set(state.workspace.layers.filter { $0.isVisible && audible.contains($0.id) }.map(\.id)) : nil
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.displayedLayerIDs == rhs.displayedLayerIDs && lhs.planIdentity == rhs.planIdentity && lhs.state.selection == rhs.state.selection && lhs.state.workspace.grid == rhs.state.workspace.grid &&
            lhs.state.isPerformanceLocked == rhs.state.isPerformanceLocked && lhs.geometry == rhs.geometry &&
            lhs.state.movePreviewCells == rhs.state.movePreviewCells
    }
    var body: some View {
        let prepared: (paths: [(Path, SelectionInk)], outline: Path, visibleCellCount: Int) = CanvasTimingProbe.measure("field.prepareSelection") {
            var result: [(Path, SelectionInk)] = []
            let cells = CGMutablePath(), outlines = CGMutablePath(), previews = CGMutablePath()
            let selected = displayedLayerIDs.map { ids in
                Set(state.selectedCells.filter { ids.contains($0.layerID) }.map(\.cell))
            } ?? state.selectedPolarCells
            var covered: Set<PolarMetricGridCell> = []
            if let plan, !state.selection.layerIDs.isEmpty {
                let ids = state.selection.layerIDs.intersection(plan.layers.filter { !$0.isLocked && (displayedLayerIDs?.contains($0.id) ?? true) }.map(\.id))
                let origin = geometry.screenPoint(for: .init(xMeters: 0, yMeters: 0))
                let scale = 1 / geometry.viewport.metersPerPoint
                var transform = CGAffineTransform(a: geometry.isHorizontallyMirrored ? -scale : scale, b: 0, c: 0, d: -scale, tx: origin.x, ty: origin.y)
                for region in plan.regions where ids.contains(region.layerID) && region.cells.allSatisfy(selected.contains) {
                    if let fill = region.fill.copy(using: &transform), let outline = region.outline.copy(using: &transform) {
                        cells.addPath(fill); outlines.addPath(outline); covered.formUnion(region.cells)
                    }
                }
            }
            var visible = covered.count
            for cell in selected.subtracting(covered) {
                let path = polarSegmentPath(for: .init(cell: cell, grid: state.workspace.grid), geometry: geometry)
                if path.boundingRect.intersects(geometry.canvasRect) { cells.addPath(path.cgPath); outlines.addPath(path.cgPath); visible += 1 }
            }
            if visible > 0 { result.append((Path(cells), .cell)) }
            for cell in state.movePreviewCells {
                previews.addPath(polarSegmentPath(for: .init(cell: cell, grid: state.workspace.grid), geometry: geometry).cgPath)
            }
            if !state.movePreviewCells.isEmpty { result.append((Path(previews), .preview)) }
            // Frame and handles share the same cached selection bounds.
            if !state.isPerformanceLocked, let bounds = state.selectionBounds {
                result.append((polarSegmentPath(for: bounds, geometry: geometry), .frame))
                if let layout = state.selectionHandleLayout(canvasSize: geometry.canvasRect.size) {
                    for entry in layout.centers {
                        result.append((Path(CGRect(x: entry.point.x - layout.size / 2,
                            y: entry.point.y - layout.size / 2,
                            width: layout.size, height: layout.size)), .handle))
                    }
                }
            }
            return (result, Path(outlines), visible)
        }
        Canvas { context, _ in
            guard presentationVisible else { return }
            for (path, kind) in prepared.paths {
                switch kind {
                case .cell:
                    if let probe = ViewEvaluationProbe.current {
                        for _ in 0..<prepared.visibleCellCount { probe.record("field.selectionCell") }
                    }
                    context.fill(path, with: .color(Color.accentColor.opacity(0.22)))
                    context.stroke(prepared.outline, with: .color(Color.accentColor), lineWidth: 2.5)
                case .preview:
                    context.stroke(path, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                case .frame:
                    context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                case .handle:
                    context.fill(path, with: .color(StageTheme.canvas))
                    context.stroke(path, with: .color(.white), lineWidth: 1.5)
                case .culled: break
                }
            }
        }.allowsHitTesting(false)
    }
}

/// Statische Messfeldgrafik. Sie hängt ausschließlich von Arbeitsbereich und
/// Geometrie ab und bleibt deshalb bei einer neuen Profilzustellung unverändert.
/// `equatable()` verhindert zusätzlich, dass SwiftUI den Canvas bei einer
/// reinen Profiländerung erneut rendert.
struct SpatialInstrumentStaticLayer: View, Equatable {
    @Environment(\.presentationVisible) private var presentationVisible
    let planIdentity: UUID
    let audibilityKey: [UUID: Double]
    let showsInactiveLayers: Bool
    let plan: SpatialFieldPlan
    let labels: [SpatialFieldPlan.Label]
    let selectedLayerID: UUID
    let mergeZones: Bool
    let geometry: MetricCanvasGeometry
    /// The surface editor shows the cell mesh only as an optional measuring aid.
    let showsCellGrid: Bool
    init(plan: SpatialFieldPlan, labels: [SpatialFieldPlan.Label], selectedLayerID: UUID,
         mergeZones: Bool, geometry: MetricCanvasGeometry, showsCellGrid: Bool = true) {
        self.showsCellGrid = showsCellGrid
        planIdentity = plan.identity; audibilityKey = plan.audibilityOpacity; showsInactiveLayers = plan.showsInactiveLayers
        self.plan = plan; self.labels = labels
        self.selectedLayerID = selectedLayerID; self.mergeZones = mergeZones; self.geometry = geometry
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.showsInactiveLayers == rhs.showsInactiveLayers && lhs.planIdentity == rhs.planIdentity && lhs.audibilityKey == rhs.audibilityKey &&
            lhs.selectedLayerID == rhs.selectedLayerID &&
            lhs.mergeZones == rhs.mergeZones && lhs.geometry == rhs.geometry && lhs.showsCellGrid == rhs.showsCellGrid
    }

    var body: some View {
        ZStack {
            if showsCellGrid { SpatialInstrumentBackgroundLayer(grid: plan.grid, geometry: geometry).equatable() }
            Canvas { context, size in
                guard presentationVisible else { return }
                CanvasTimingProbe.measure("field.staticDraw") {
                CanvasTimingProbe.measure("field.zoneDraw") { drawPolarPaintedArea(in: &context) }
                drawAxes(in: &context, size: size)
                }
            }
            // Text has a stable SwiftUI identity and a discrete font size;
            // panning changes only its position, avoiding Canvas text layout.
            // Occluding another region must not change this text's identity.
            ForEach(labels, id: \.regionIndex) { prepared in
                fieldLabel(prepared)
            }
        }.allowsHitTesting(false)
    }

    private var metricTransform: CGAffineTransform {
        let origin = geometry.screenPoint(for: MetricScanPoint(xMeters: 0, yMeters: 0))
        let scale = 1 / geometry.viewport.metersPerPoint
        return .init(a: geometry.isHorizontallyMirrored ? -scale : scale, b: 0, c: 0, d: -scale, tx: origin.x, ty: origin.y)
    }

    private func drawPolarPaintedArea(in context: inout GraphicsContext) {
        // Fill and label ownership share the same audible-first top surface.
        for layer in plan.paintOrder(selectedLayerID: selectedLayerID) {
            let selected = layer.id == selectedLayerID
            let audibility = plan.audibilityOpacity[layer.id, default: 1]
            let color = Color(red: layer.color.red, green: layer.color.green, blue: layer.color.blue)
            for region in plan.regions where region.layerID == layer.id {
                var transform = metricTransform
                guard let transformedFill = CanvasTimingProbe.measure("field.zonePathTransform", {
                    region.fill.copy(using: &transform)
                }) else { continue }
                let fill = Path(transformedFill)
                guard fill.boundingRect.intersects(geometry.canvasRect) else { continue }
                let mesh = mergeZones ? region.outline : region.cellMesh
                guard let transformedMesh = mesh.copy(using: &transform) else { continue }
                CanvasTimingProbe.measure("field.zonePaint") {
                    if mergeZones { context.fill(fill, with: .color(StageTheme.canvas)) }
                    context.fill(fill, with: .color(color.opacity((selected ? 0.5 : 0.25) * audibility)))
                    context.stroke(Path(transformedMesh), with: .color(color.opacity((selected ? 0.88 : 0.5) * audibility)), lineWidth: selected ? 1.5 : 1)
                }
            }
        }
    }

    static func labelFontSize(_ prepared: SpatialFieldPlan.Label, plan: SpatialFieldPlan,
                              geometry: MetricCanvasGeometry) -> CGFloat? {
        let region = plan.regions[prepared.regionIndex]
        let segment = PolarMetricCellSegment(cell: prepared.cell, grid: plan.grid)
        let scale = geometry.viewport.metersPerPoint
        let areaSize = min(region.bounds.width, region.bounds.height) / scale
        let point = geometry.screenPoint(for: .init(xMeters: prepared.center.x, yMeters: prepared.center.y))
        guard region.label != nil, geometry.canvasRect.contains(point),
              SpatialCellLabel.isVisible(segment: segment, metersPerPoint: scale) || (region.cells.count > 1 && areaSize >= 12)
        else { return nil }
        return areaSize >= 128 ? 16 : areaSize >= 96 ? 12 : 10
    }

    @ViewBuilder
    private func fieldLabel(_ prepared: SpatialFieldPlan.Label) -> some View {
        let _ = ViewEvaluationProbe.current?.record("field.labelInput")
        let region = plan.regions[prepared.regionIndex]
        let point = geometry.screenPoint(for: .init(xMeters: prepared.center.x, yMeters: prepared.center.y))
        if let label = region.label, let size = Self.labelFontSize(prepared, plan: plan, geometry: geometry) {
            StableFieldLabelText(text: region.hasOwnValue ? "• " + label : label,
                                 size: size, hasOwnValue: region.hasOwnValue,
                                 availableWidth: max(12, region.bounds.width / geometry.viewport.metersPerPoint - 4))
                .equatable().opacity(prepared.opacity).position(point)
        }
    }

    private func drawAxes(
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: geometry.canvasBaselineY))
        baseline.addLine(to: CGPoint(x: size.width, y: geometry.canvasBaselineY))
        context.stroke(baseline, with: .color(Color.primary.opacity(0.45)), lineWidth: 1)

        let origin = geometry.screenPoint(for: MetricScanPoint(xMeters: 0, yMeters: 0))
        let marker = CGRect(x: origin.x - 4, y: origin.y - 4, width: 8, height: 8)
        if marker.intersects(geometry.canvasRect) {
            context.fill(Path(ellipseIn: marker), with: .color(StageTheme.amber))
        }
    }


}

private struct SpatialInstrumentBackgroundLayer: View, Equatable {
    @Environment(\.presentationVisible) private var presentationVisible
    let grid: MetricSquareGrid
    let geometry: MetricCanvasGeometry
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.grid == rhs.grid && lhs.geometry == rhs.geometry
    }
    var body: some View {
        Canvas { context, size in
            guard presentationVisible else { return }
            CanvasTimingProbe.measure("field.gridDraw") { drawPolarBackground(in: &context, size: size) }
        }.allowsHitTesting(false)
    }
    private func drawPolarBackground(in context: inout GraphicsContext, size: CGSize) {
        let corners = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
        let radius = corners.compactMap { geometry.metricPoint(forScreenPoint: $0) }
            .map { hypot($0.xMeters, $0.yMeters) }.max() ?? 0
        guard radius > 0 else { return }
        let step = grid.cellSizeMeters * max(1, ceil(radius / grid.cellSizeMeters / 160))
        let path = SpatialGridPaths.path(step: step, rings: Int(ceil(radius / step / 16)) * 16)
        let origin = geometry.screenPoint(for: .init(xMeters: 0, yMeters: 0))
        let scale = 1 / geometry.viewport.metersPerPoint
        var transform = CGAffineTransform(a: geometry.isHorizontallyMirrored ? -scale : scale, b: 0, c: 0, d: -scale, tx: origin.x, ty: origin.y)
        if let transformed = path.copy(using: &transform) {
            context.stroke(Path(transformed), with: .color(StageTheme.grid), lineWidth: 1.1)
        }
    }

}

/// MainActor-only, bounded cache of immutable metric grid paths. Pan/zoom
/// changes one native affine transform, never thousands of grid vertices.
@MainActor private enum SpatialGridPaths {
    private struct Key: Hashable { let step: Double; let rings: Int }
    private static var paths: [Key: CGPath] = [:]
    static func path(step: Double, rings: Int) -> CGPath {
        let key = Key(step: step, rings: rings)
        if let path = paths[key] { return path }
        let path = CGMutablePath()
        for ring in 1...max(1, rings) {
            let outer = Double(ring) * step, inner = outer - step
            path.move(to: CGPoint(x: -outer, y: 0))
            path.addArc(center: .zero, radius: outer, startAngle: .pi, endAngle: 0, clockwise: true)
            let angularStep = PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: outer,
                radialHeightMeters: step, baseAngularStepDegrees: 90, maximumWidthToRadialHeightRatio: 1.5)
            for bearing in stride(from: -90.0, through: 90.0, by: angularStep) {
                let angle = bearing * .pi / 180
                path.move(to: CGPoint(x: sin(angle) * inner, y: cos(angle) * inner))
                path.addLine(to: CGPoint(x: sin(angle) * outer, y: cos(angle) * outer))
            }
        }
        if paths.count >= 8 { paths.removeAll(keepingCapacity: true) }
        paths[key] = path
        return path
    }
}

/// Selection affects label placement/opacity, never the text layout inputs.
/// Keep the text subtree stable even when the surrounding field is redrawn.
private struct StableFieldLabelText: View, Equatable {
    let text: String
    let size: CGFloat
    let hasOwnValue: Bool
    let availableWidth: CGFloat
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("field.labelText")
        Text(text)
            .font(.system(size: size, weight: hasOwnValue ? .bold : .medium))
            .foregroundColor(hasOwnValue ? .yellow : .primary)
            .lineLimit(1).minimumScaleFactor(10 / size)
            .frame(width: availableWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func polarSegmentPath(
    for segment: PolarMetricCellSegment,
    geometry: MetricCanvasGeometry
) -> Path {
    let span = segment.endBearingDegrees - segment.startBearingDegrees
    let steps = max(2, Int(ceil(abs(span) / 3)))
    var path = Path()

    for step in 0...steps {
        let fraction = Double(step) / Double(steps)
        let bearing = segment.startBearingDegrees + span * fraction
        let point = geometry.screenPoint(for: segment.point(
            radiusMeters: segment.outerRadiusMeters,
            bearingDegrees: bearing
        ))
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    for step in (0...steps).reversed() {
        let fraction = Double(step) / Double(steps)
        let bearing = segment.startBearingDegrees + span * fraction
        path.addLine(to: geometry.screenPoint(for: segment.point(
            radiusMeters: segment.innerRadiusMeters,
            bearingDegrees: bearing
        )))
    }
    path.closeSubpath()
    return path
}
