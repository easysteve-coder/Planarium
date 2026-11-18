import AppKit
import SwiftUI
import PlanariumDomain
import SickPLSMonitorKit
import SickPLSCommissioning

@MainActor final class DeviceFieldControlModel: ObservableObject {
    @Published var selected: DeviceFieldDraft.Kind = .protective
    let canvas = CanvasSession(state: .init(selectionMaximumRadiusMeters: 50))
    @Published private(set) var drafts: DeviceFieldDrafts
    @Published private(set) var notice: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; drafts = DeviceFieldDraftStore.load(from: defaults)
    }
    var draft: DeviceFieldDraft { drafts[selected] }
    var visibleDrafts: [DeviceFieldDraft] { [drafts.protective, drafts.warning] }
    func update(_ change: (inout DeviceFieldDrafts) -> Void) {
        var value = drafts; change(&value); drafts = value
        DeviceFieldDraftStore.save(value, to: defaults)
    }
    func replace(_ value: DeviceFieldDraft) {
        var next = value
        if next.lastExportedRadii == nil {
            next.lastExportedRadii = drafts[value.kind].lastExportedRadii
            next.lastExportedSegments = drafts[value.kind].lastExportedSegments
        }
        update { $0[value.kind] = next }
    }
    func fillSelection() {
        var value = draft
        value.area += canvas.selectedPolarCells.map { .init(cell: $0, grid: canvas.workspace.grid) }
        replace(value)
    }
    func eraseSelection() {
        var value = draft
        for cell in canvas.selectedPolarCells {
            let cut = PolarMetricCellSegment(cell: cell, grid: canvas.workspace.grid)
            value.area = value.area.flatMap { area -> [PolarMetricCellSegment] in
                let lo = max(area.innerRadiusMeters, cut.innerRadiusMeters), hi = min(area.outerRadiusMeters, cut.outerRadiusMeters)
                let left = max(area.startBearingDegrees, cut.startBearingDegrees), right = min(area.endBearingDegrees, cut.endBearingDegrees)
                guard lo < hi, left < right else { return [area] }
                var pieces: [PolarMetricCellSegment] = []
                func add(_ inner: Double, _ outer: Double, _ start: Double, _ end: Double) {
                    if inner < outer, start < end { pieces.append(.init(innerRadiusMeters: inner, outerRadiusMeters: outer, startBearingDegrees: start, endBearingDegrees: end)) }
                }
                add(area.innerRadiusMeters, area.outerRadiusMeters, area.startBearingDegrees, left)
                add(area.innerRadiusMeters, area.outerRadiusMeters, right, area.endBearingDegrees)
                add(area.innerRadiusMeters, lo, left, right); add(hi, area.outerRadiusMeters, left, right)
                return pieces
            }
        }
        replace(value)
    }
    @discardableResult func export(to url: URL) -> Bool {
        guard case .valid(let contour) = draft.validation else { notice = draft.status; return false }
        do {
            let bytes = try ScannerFieldContourCodec.encode(contour)
            try Data(bytes).write(to: url, options: .atomic)
            var value = draft; value.recordExport(contour); replace(value)
            notice = "Diagnostic contour exported to file."
            return true
        } catch ScannerFieldContourCodec.CodecError.unsupportedWireSegmentCount {
            notice = "180 segments: wire format unverified; export unavailable."
        } catch { notice = "The diagnostic contour file could not be written." }
        return false
    }
}

/// Same meter-to-screen transform as the instrument. Invalid drafts remain
/// visible as their authored areas, so an island is not silently filled.
struct DeviceFieldOverlay: View, Equatable {
    let drafts: [DeviceFieldDraft]
    let viewport: MetricCanvasViewport
    var mirrored = false
    var body: some View {
        GeometryReader { proxy in
            let geometry = MetricCanvasGeometry(size: proxy.size, viewport: viewport, isHorizontallyMirrored: mirrored)
            Canvas { context, _ in
                for draft in drafts {
                    let color: Color = draft.kind == .protective ? .orange : .cyan
                    let path: Path
                    switch draft.validation {
                    case .valid(let contour):
                        path = polygon(contour.polygonMeters, geometry: geometry)
                    case .invalid:
                        var combined = Path()
                        for cell in draft.area { combined.addPath(polygon(points(cell), geometry: geometry)) }
                        path = combined
                    }
                    context.fill(path, with: .color(color.opacity(0.16)))
                    // Invalid drafts are authored areas, not a contour. Their
                    // per-sector strokes form a misleading comb of radial
                    // edges. Fill those areas; only valid exteriors get a line.
                    if case .valid = draft.validation {
                        context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 2)
                    }
                }
            }
        }.allowsHitTesting(false)
    }
    private func polygon(_ points: [MetricScanPoint], geometry: MetricCanvasGeometry) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: geometry.screenPoint(for: first))
        for point in points.dropFirst() { path.addLine(to: geometry.screenPoint(for: point)) }
        path.closeSubpath(); return path
    }
    private func points(_ area: PolarMetricCellSegment) -> [MetricScanPoint] {
        let n = max(1, Int(ceil((area.endBearingDegrees - area.startBearingDegrees) / 2)))
        return (0...n).map { area.point(radiusMeters: area.outerRadiusMeters, bearingDegrees: area.startBearingDegrees + Double($0) / Double(n) * (area.endBearingDegrees - area.startBearingDegrees)) }
            + (0...n).reversed().map { area.point(radiusMeters: area.innerRadiusMeters, bearingDegrees: area.startBearingDegrees + Double($0) / Double(n) * (area.endBearingDegrees - area.startBearingDegrees)) }
    }
}

struct DeviceFieldEditorView: View {
    @ObservedObject var model: DeviceFieldControlModel
    @ObservedObject private var canvas: CanvasSession
    @State private var radius = "1"
    @State private var width = "2"
    @State private var depth = "2"
    @State private var canvasSize = CGSize.zero
    init(model: DeviceFieldControlModel, radius: String = "1", width: String = "2", depth: String = "2") {
        self.model = model; self.canvas = model.canvas; _radius = State(initialValue: radius)
        _width = State(initialValue: width); _depth = State(initialValue: depth)
    }
    func createSemicircle() {
        if let r = Double(radius), r > 0, r <= 50 { model.replace(.semicircle(kind: model.selected, radius: r)) }
    }
    func createRectangle() {
        if let w = Double(width), let d = Double(depth), w > 0, d > 0, w <= 50, d <= 50 {
            model.replace(.rectangle(kind: model.selected, width: w, depth: d))
        }
    }
    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                Text("Device fields · offline reference").font(.headline)
                Picker("Field", selection: $model.selected) {
                    ForEach(DeviceFieldDraft.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), alignment: .leading)], alignment: .leading, spacing: 6) {
                    CanvasToolButtons(selection: Binding(get: { canvas.tool }, set: { canvas.select(tool: $0) }), tools: [.select, .pan])
                    Picker("Segments", selection: Binding(get: { model.draft.segments }, set: { count in var value = model.draft; value.segments = count; model.replace(value) })) {
                        ForEach(ScannerFieldContour.SegmentCount.allCases, id: \.self) { Text("\($0.rawValue)").tag($0) }
                    }.help("180 is a value format only; its wire format is unverified.")
                    IconActionButton("Fill selection", symbol: "paintbrush.pointed") { model.fillSelection() }.disabled(canvas.selectedPolarCells.isEmpty)
                    IconActionButton("Erase selection", symbol: "delete.left") { model.eraseSelection() }.disabled(canvas.selectedPolarCells.isEmpty)
                    HStack { TextField("Radius m", text: $radius).frame(width: 55).help("Semicircle radius in meters."); IconActionButton("Semicircle", symbol: "circle.lefthalf.fill", action: createSemicircle) }
                    HStack { TextField("Width m", text: $width).frame(width: 35).help("Rectangle width in meters."); TextField("Depth m", text: $depth).frame(width: 35).help("Rectangle depth in meters."); IconActionButton("Rectangle", symbol: "rectangle", action: createRectangle) }
                    IconActionButton("Clear field", symbol: "trash") { model.replace(.init(kind: model.selected)) }
                    IconActionButton("Export contour", symbol: "square.and.arrow.up") { export() }.disabled(!canExport)
                    HStack {
                        IconActionButton("Zoom out", symbol: "minus.magnifyingglass") { _ = canvas.zoom(byFactor: 0.5, atScreenPoint: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2), canvasSize: canvasSize) }
                        IconActionButton("Zoom in", symbol: "plus.magnifyingglass") { _ = canvas.zoom(byFactor: 2, atScreenPoint: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2), canvasSize: canvasSize) }
                        IconActionButton("Reset view", symbol: "scope") { _ = canvas.resetViewport(canvasSize: canvasSize) }
                    }.help("Zoom or reset the meter viewport without changing field geometry.")
                }.font(.caption)
                Text("\(model.draft.kind.title) → \(model.draft.kind.output) · information only; no safety function claim.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Text(model.draft.status).font(.caption).foregroundColor(canExport ? .secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.visibleDrafts.filter { $0.kind != model.selected }, id: \.kind) { draft in
                    Text("\(draft.kind.title): \(draft.status)")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(model.draft.exportDifference).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let notice = model.notice { Text(notice).font(.caption) }
                GeometryReader { field in
                    ZStack {
                        Color.black
                        SpatialInstrumentStaticLayer(plan: SpatialFieldPlan(workspace: canvas.workspace), labels: [], selectedLayerID: canvas.workspace.selectedLayerID, mergeZones: true,
                            geometry: canvas.displayGeometry(canvasSize: field.size))
                        DeviceFieldOverlay(drafts: model.drafts.showInEdit ? model.visibleDrafts : [], viewport: canvas.viewport, mirrored: canvas.isHorizontallyMirrored)
                        Canvas { context, _ in
                            let g = canvas.displayGeometry(canvasSize: field.size)
                            for cell in canvas.selectedPolarCells {
                                let area = PolarMetricCellSegment(cell: cell, grid: canvas.workspace.grid)
                                let p = g.screenPoint(for: area.point(radiusMeters: area.midpoint.radiusMeters, bearingDegrees: area.midpoint.bearingDegrees))
                                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white))
                            }
                            if let rect = canvas.selectionRectangle {
                                context.stroke(Path(rect), with: .color(.white), lineWidth: 1)
                            }
                        }.allowsHitTesting(false)
                        ScanFieldPointerEvents(
                            onScroll: { event, point in
                                guard let factor = ScanFieldZoomInput.zoomFactor(for: event) else { return }
                                _ = canvas.zoom(byFactor: factor, atScreenPoint: point, canvasSize: field.size)
                            },
                            onPressedTwoFingerDrag: { _ in },
                            onMagnify: { magnification, point in
                                guard let factor = ScanFieldZoomInput.zoomFactor(forMagnification: magnification) else { return }
                                _ = canvas.zoom(byFactor: factor, atScreenPoint: point, canvasSize: field.size)
                            },
                            onKeyCommand: { event in
                                if event.keyCode == 53 { canvas.cancelGesture(); return true }
                                if event.keyCode == 49 { canvas.holdHand(true); return true }
                                switch event.charactersIgnoringModifiers?.lowercased() {
                                case "v": canvas.select(tool: .select); return true
                                case "h": canvas.select(tool: .pan); return true
                                default: return false
                                }
                            },
                            onKeyRelease: { if $0.keyCode == 49 { canvas.holdHand(false) } },
                            onFocusLost: { canvas.cancelGesture(); canvas.holdHand(false) },
                            onPrimaryDrag: { phase, point, flags in
                                switch phase {
                                case .leftMouseDown: canvas.send(.arm(point, modifiers: [], brush: flags.contains(.option)), canvasSize: field.size)
                                case .leftMouseDragged: canvas.send(.drag(point), canvasSize: field.size)
                                case .leftMouseUp: canvas.send(.release(point), canvasSize: field.size)
                                default: break
                                }
                            },
                            onSecondaryDrag: { phase, point in
                                switch phase {
                                case .rightMouseDown: canvas.send(.armPan(point), canvasSize: field.size)
                                case .rightMouseDragged: canvas.send(.drag(point), canvasSize: field.size)
                                case .rightMouseUp: canvas.send(.release(point), canvasSize: field.size)
                                default: break
                                }
                            },
                            toolName: canvas.effectiveTool.rawValue,
                            cursor: canvas.effectiveTool == .pan ? .openHand : .crosshair
                        )
                    }.contentShape(Rectangle())
                    .onAppear { canvasSize = field.size; _ = canvas.followCanvasSize(field.size) }
                    .onChange(of: field.size) { canvasSize = $0; _ = canvas.followCanvasSize($0) }
                }.frame(minHeight: 240)
            }.frame(width: proxy.size.width, alignment: .leading)
        }
    }
    private var canExport: Bool { if case .valid = model.draft.validation { return model.draft.segments != .oneEighty }; return false }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(model.selected.rawValue)-contour.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url)
    }
}
