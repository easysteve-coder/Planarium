import SwiftUI
import AppKit
import PlanariumApplication
import PlanariumDomain
import SickPLSMonitorKit

// The field as the surface editor shows it: every surface from its real form (not from a coarse cell
// projection), the control course as a colour gradient with an arrow, the notes of a scale as steps with
// their names, the selection with its handles, and the sketch of the gesture in progress. Colours are a
// coding of values that `SurfaceValueCoding` took from the production value plan; nothing here computes a value.

/// Outline of a placed shape in world centimetres.
enum SurfaceOutline {
    static func points(of shape: SurfaceShape, transform: SurfaceTransform) -> [[SurfacePoint]] {
        func world(_ x: Double, _ y: Double) -> SurfacePoint { SurfaceFrame.world(.init(x: x, y: y), transform) }
        switch shape {
        case .rectangle(let w, let h):
            return [[world(-w / 2, -h / 2), world(w / 2, -h / 2), world(w / 2, h / 2), world(-w / 2, h / 2)]]
        case .circle(let r):
            let steps = 72
            return [(0..<steps).map { k in
                let a = Double(k) / Double(steps) * 2 * .pi
                return world(r * cos(a), r * sin(a))
            }]
        case .polygon(let points):
            return [points.map { world($0.x, $0.y) }]
        case .ringSector(let from, let to, let fromDegrees, let toDegrees):
            let span = max(toDegrees - fromDegrees, 0.5)
            let steps = max(2, Int((span / 2).rounded(.up)))
            func arc(_ radius: Double, reversed: Bool) -> [SurfacePoint] {
                (0...steps).map { k in
                    let f = Double(reversed ? steps - k : k) / Double(steps)
                    let b = (fromDegrees + span * f) * .pi / 180
                    return SurfacePoint(x: radius * sin(b), y: radius * cos(b))
                }
            }
            return [arc(to, reversed: false) + (from > 0 ? arc(from, reversed: true) : [SurfacePoint(x: 0, y: 0)])]
        }
    }
    static func path(shape: SurfaceShape, transform: SurfaceTransform) -> CGPath {
        let path = CGMutablePath()
        for ring in points(of: shape, transform: transform) {
            guard let first = ring.first else { continue }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in ring.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            path.closeSubpath()
        }
        return path
    }
}

/// One surface prepared for drawing: paths in world centimetres.
final class SurfacePreparedShape {
    struct Band { let path: CGPath; let color: SpatialLayerColor; let label: (name: String, at: CGPoint, isRoot: Bool)? }
    let surface: SpatialSurface
    let layerID: UUID
    let outline: CGPath
    let fill: CGPath
    let coding: SurfaceValueCoding?
    let bands: [Band]
    /// The assignment whose course is shown: the one the inspector has chosen, else the first with an arrow.
    let routingID: UUID?
    init(surface: SpatialSurface, layerID: UUID, routingID chosen: UUID?) {
        self.surface = surface; self.layerID = layerID
        switch surface.form {
        case .shape(let shape, let transform): outline = SurfaceOutline.path(shape: shape, transform: transform)
        case .legacyMask: outline = Self.regionPath(surface.cells)
        }
        fill = Self.regionPath(surface.cells)
        let routingID = chosen.flatMap { id in surface.routings.contains { $0.id == id } ? id : nil } ?? SurfaceEditorModel.defaultRoutingID(of: surface)
        self.routingID = routingID
        coding = routingID.flatMap { SurfaceValueCoding(surface: surface, routingID: $0) }
        if let coding, coding.kind == .scale, let id = routingID, let field = try? SurfaceValueField(surface: surface, routingID: id) {
            var cellsByNote: [Int: [PolarDeviceLattice]] = [:]
            for cell in surface.cells {
                if case .notes(let notes, _) = field.sample(cell).value, let note = notes.first { cellsByNote[Int(note.number), default: []].append(cell) }
            }
            bands = coding.steps.compactMap { step in
                guard let cells = cellsByNote[step.note], !cells.isEmpty else { return nil }
                let sum = cells.reduce((x: 0.0, y: 0.0)) { acc, c in
                    let p = SurfaceGrid.point(ring: c.ring, tick: c.sector); return (acc.x + p.x, acc.y + p.y)
                }
                return Band(path: Self.regionPath(cells), color: step.color,
                            label: (step.name, CGPoint(x: sum.x / Double(cells.count), y: sum.y / Double(cells.count)), step.isRoot))
            }
        } else { bands = [] }
    }

    /// Per ring the runs of neighbouring ticks, as one annular piece each (world centimetres).
    static func regionPath(_ cells: [PolarDeviceLattice]) -> CGPath {
        var rows: [Int: [Int]] = [:]
        for cell in cells { rows[cell.ring, default: []].append(cell.sector) }
        let path = CGMutablePath()
        for ring in rows.keys.sorted() {
            let ticks = rows[ring]!.sorted()
            var start = ticks[0], previous = ticks[0]
            func close(_ a: Int, _ b: Int) {
                let inner = max(0, Double(ring) - 0.5), outer = Double(ring) + 0.5
                let from = SurfaceGrid.bearing(tick: a) - 0.25, to = SurfaceGrid.bearing(tick: b) + 0.25
                let steps = max(1, Int(((to - from) / 2).rounded(.up)))
                func at(_ radius: Double, _ k: Int) -> CGPoint {
                    let bearing = (from + (to - from) * Double(k) / Double(steps)) * .pi / 180
                    return CGPoint(x: radius * sin(bearing), y: radius * cos(bearing))
                }
                path.move(to: at(outer, 0))
                for k in 1...steps { path.addLine(to: at(outer, k)) }
                for k in stride(from: steps, through: 0, by: -1) { path.addLine(to: at(inner, k)) }
                path.closeSubpath()
            }
            for tick in ticks.dropFirst() {
                if tick != previous + 1 { close(start, previous); start = tick }
                previous = tick
            }
            close(start, previous)
        }
        return path
    }
}

/// Keeps the prepared shapes between redraws; rebuilt only for a surface whose derived content changed.
final class SurfacePreparedCache {
    private var shapes: [UUID: SurfacePreparedShape] = [:]
    /// - Parameter chosen: the surface whose chosen assignment (`routingID`) decides which course is drawn; every
    ///   other surface shows its default one.
    func prepare(_ document: InstrumentDocument, chosen: (surfaceID: UUID, routingID: UUID)?) -> [SurfacePreparedShape] {
        var next: [UUID: SurfacePreparedShape] = [:]
        var order: [SurfacePreparedShape] = []
        for layer in document.spatial.layers where layer.isSurfaceBacked {
            for surface in layer.surfaces {
                let shape: SurfacePreparedShape
                let wanted = chosen?.surfaceID == surface.id ? chosen?.routingID : nil
                let routingID = wanted.flatMap { id in surface.routings.contains { $0.id == id } ? id : nil } ?? SurfaceEditorModel.defaultRoutingID(of: surface)
                if let old = shapes[surface.id], old.surface == surface, old.layerID == layer.id, old.routingID == routingID { shape = old }
                else { shape = SurfacePreparedShape(surface: surface, layerID: layer.id, routingID: routingID) }
                next[surface.id] = shape; order.append(shape)
            }
        }
        shapes = next
        return order
    }
}

struct SurfaceFieldLayers: View {
    @ObservedObject var model: SurfaceEditorModel
    let document: InstrumentDocument
    let selection: Set<UUID>
    let geometry: MetricCanvasGeometry
    let showsInactive: Bool
    let performing: Bool
    @State private var cache = SurfacePreparedCache()

    private func swiftColor(_ c: SpatialLayerColor, _ opacity: Double = 1) -> Color {
        Color(red: c.red, green: c.green, blue: c.blue, opacity: opacity)
    }
    /// World centimetres to screen points.
    private var toScreen: CGAffineTransform {
        let origin = geometry.screenPoint(for: MetricScanPoint(xMeters: 0, yMeters: 0))
        let x = geometry.screenPoint(for: MetricScanPoint(xMeters: 0.01, yMeters: 0))
        let y = geometry.screenPoint(for: MetricScanPoint(xMeters: 0, yMeters: 0.01))
        return CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
    }

    var body: some View {
        let chosenRouting = model.axisRoutingID
        let shapes = cache.prepare(document, chosen: selection.count == 1 ? selection.first.flatMap { id in chosenRouting.map { (id, $0) } } : nil)
        let audible = SpatialLayerAudibility.audibleIDs(document.spatial.layers.map { ($0.id, $0.isActive, $0.isSoloed) })
        let layout = performing ? SurfaceHandleLayout.empty : model.handleLayout(geometry: geometry)
        Canvas { context, size in
            let t = toScreen
            let space = SurfaceCanvasSpace(geometry)
            if model.showsGrid { drawGrid(in: &context, space: space) }
            drawScale(in: &context, space: space)
            drawPlayArea(in: &context, space: space)
            let layersByID = Dictionary(uniqueKeysWithValues: document.spatial.layers.map { ($0.id, $0) })
            for prepared in shapes {
                guard let layer = layersByID[prepared.layerID], layer.isVisible,
                      showsInactive || audible.contains(layer.id) else { continue }
                let dim = audible.contains(layer.id) ? 1.0 : 0.3
                draw(prepared, layer: layer, dim: dim, in: &context, transform: t, space: space)
            }
            if !performing {
                drawSelection(shapes, layout: layout, in: &context, transform: t, space: space)
                drawSketch(shapes, in: &context, transform: t, space: space)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Scale and play area

    private func drawScale(in context: inout GraphicsContext, space: SurfaceCanvasSpace) {
        let origin = space.screen(.init(x: 0, y: 0))
        if geometry.canvasRect.insetBy(dx: -20, dy: -20).contains(origin) {
            var cross = Path()
            cross.move(to: CGPoint(x: origin.x - 7, y: origin.y)); cross.addLine(to: CGPoint(x: origin.x + 7, y: origin.y))
            cross.move(to: CGPoint(x: origin.x, y: origin.y - 7)); cross.addLine(to: CGPoint(x: origin.x, y: origin.y + 7))
            context.stroke(cross, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
            context.draw(Text("Scanner").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.7)),
                         at: CGPoint(x: origin.x + 10, y: origin.y - 9), anchor: .leading)
        }
        // A scale bar of a round length that is 60…160 points wide.
        let perCm = space.pointsPerCentimeter
        guard perCm > 0 else { return }
        let lengths: [Double] = [1, 2, 5, 10, 20, 25, 50, 100, 200]
        let length = lengths.first { $0 * perCm >= 60 } ?? 200
        let width = length * perCm
        let rect = geometry.canvasRect
        let y = rect.maxY - 14, x = rect.minX + 14
        var bar = Path()
        bar.move(to: CGPoint(x: x, y: y)); bar.addLine(to: CGPoint(x: x + width, y: y))
        bar.move(to: CGPoint(x: x, y: y - 4)); bar.addLine(to: CGPoint(x: x, y: y + 4))
        bar.move(to: CGPoint(x: x + width, y: y - 4)); bar.addLine(to: CGPoint(x: x + width, y: y + 4))
        context.stroke(bar, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
        context.draw(Text(length >= 100 ? "\(Int(length / 100)) m" : "\(Int(length)) cm").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.8)),
                     at: CGPoint(x: x + width + 6, y: y), anchor: .leading)
    }

    /// An alignment aid only: rings every 10 cm and bearings every 10°.
    private func drawGrid(in context: inout GraphicsContext, space: SurfaceCanvasSpace) {
        var path = Path()
        for radius in stride(from: 10.0, through: 200.0, by: 10.0) {
            let points = stride(from: -90.0, through: 90.0, by: 3.0).map { b -> CGPoint in
                space.screen(.init(x: radius * sin(b * .pi / 180), y: radius * cos(b * .pi / 180)))
            }
            path.move(to: points[0]); for p in points.dropFirst() { path.addLine(to: p) }
        }
        for bearing in stride(from: -90.0, through: 90.0, by: 10.0) {
            path.move(to: space.screen(.init(x: 0, y: 0)))
            path.addLine(to: space.screen(.init(x: 200 * sin(bearing * .pi / 180), y: 200 * cos(bearing * .pi / 180))))
        }
        context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
    }

    private func drawPlayArea(in context: inout GraphicsContext, space: SurfaceCanvasSpace) {
        let path = CGMutablePath()
        switch document.spatial.surfaceSettings.playArea {
        case .rectangle(let xMin, let xMax, let yMin, let yMax):
            path.addRect(CGRect(x: xMin, y: yMin, width: xMax - xMin, height: yMax - yMin))
        case .sector(let from, let to, let fromDegrees, let toDegrees):
            path.addPath(SurfaceOutline.path(shape: .ringSector(fromCm: from, toCm: to, fromDegrees: fromDegrees, toDegrees: toDegrees), transform: .identity))
        }
        var screen = Path(path.copy(using: [toScreen]) ?? path)
        screen = screen.strokedPath(StrokeStyle(lineWidth: 1, dash: [5, 4]))
        context.fill(screen, with: .color(.white.opacity(0.35)))
    }

    // MARK: Surfaces

    private func draw(_ prepared: SurfacePreparedShape, layer: SpatialDocumentLayer, dim: Double,
                      in context: inout GraphicsContext, transform t: CGAffineTransform, space: SurfaceCanvasSpace) {
        let surface = prepared.surface
        let chosen = selection.contains(surface.id)
        let base = chosen ? 0.82 : 0.62
        func screen(_ path: CGPath) -> Path { Path(path.copy(using: [t]) ?? path) }
        let fillPath = screen(prepared.fill)
        if let coding = prepared.coding, coding.kind == .continuous, let arrow = coding.arrow {
            let colors = coding.stops.map { swiftColor($0.color, base * dim) }
            if colors.count >= 2 {
                context.fill(fillPath, with: .linearGradient(Gradient(colors: colors), startPoint: space.screen(arrow.start), endPoint: space.screen(arrow.tip)))
            } else { context.fill(fillPath, with: .color(swiftColor(surface.presentation.color, base * dim))) }
        } else if !prepared.bands.isEmpty {
            for band in prepared.bands { context.fill(screen(band.path), with: .color(swiftColor(band.color, base * dim))) }
        } else {
            context.fill(fillPath, with: .color(swiftColor(surface.presentation.color, base * dim)))
        }
        let outline = screen(prepared.outline)
        context.stroke(outline, with: .color(swiftColor(surface.presentation.color, dim)), lineWidth: chosen ? 2.5 : 1.5)
        // The name sits below the surface, outside its handles.
        let bounds = surface.worldBounds
        let bottom = space.screen(.init(x: (bounds.minX + bounds.maxX) / 2, y: bounds.minY))
        if geometry.canvasRect.contains(bottom) {
            context.draw(Text(surface.presentation.name).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.85 * dim)),
                         at: CGPoint(x: bottom.x, y: bottom.y + 22), anchor: .center)
        }
        // The arrow of the course: strong for the chosen surface, quiet for the others.
        if let arrow = prepared.coding?.arrow {
            drawArrow(arrow, coding: prepared.coding, emphasised: chosen, in: &context, space: space, legendOrigin: space.screen(.init(x: (surface.worldBounds.minX + surface.worldBounds.maxX) / 2, y: surface.worldBounds.minY)).applying(CGAffineTransform(translationX: 0, y: 38)), ink: swiftColor(.init(red: 1, green: 1, blue: 1), (chosen ? 1 : 0.55) * dim))
        }
    }

    private func drawArrow(_ arrow: SurfaceAxisPresentation, coding: SurfaceValueCoding?, emphasised: Bool, in context: inout GraphicsContext,
                           space: SurfaceCanvasSpace, legendOrigin: CGPoint? = nil, ink: Color) {
        let (a, b) = SurfaceArrowScreen.ends(arrow, space: space)
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 8 else { return }
        var line = Path(); line.move(to: a); line.addLine(to: b)
        context.stroke(line, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: emphasised ? 4.5 : 3.5, lineCap: .round))
        context.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: emphasised ? 2.5 : 1.5, lineCap: .round))
        let angle = atan2(b.y - a.y, b.x - a.x), head: CGFloat = emphasised ? 12 : 8
        var tip = Path()
        tip.move(to: b)
        tip.addLine(to: CGPoint(x: b.x - head * cos(angle - 0.45), y: b.y - head * sin(angle - 0.45)))
        tip.addLine(to: CGPoint(x: b.x - head * cos(angle + 0.45), y: b.y - head * sin(angle + 0.45)))
        tip.closeSubpath()
        context.fill(tip, with: .color(ink))
        context.fill(Path(ellipseIn: CGRect(x: a.x - 4, y: a.y - 4, width: 8, height: 8)), with: .color(ink))
        guard emphasised, let coding else { return }
        // Start and end markers sit beside the arrow ends; the legend beside its middle, on the side with room.
        let side: CGFloat = (-sin(angle)) >= 0 ? 1 : -1
        let normal = CGPoint(x: -sin(angle) * 12 * side, y: cos(angle) * 12 * side)
        let anchor: UnitPoint = side > 0 ? .leading : .trailing
        context.draw(Text(coding.startText).font(.system(size: 11, weight: .bold)).foregroundColor(.white),
                     at: CGPoint(x: a.x + normal.x, y: a.y + normal.y), anchor: anchor)
        context.draw(Text(coding.tipText).font(.system(size: 11, weight: .bold)).foregroundColor(.white),
                     at: CGPoint(x: b.x + normal.x, y: b.y + normal.y), anchor: anchor)
        if let origin = legendOrigin {
            context.draw(Text(coding.legend).font(.system(size: 11, weight: .semibold)).foregroundColor(.white), at: origin, anchor: .center)
        }
        // The notes of a scale, at their place along the arrow on the other side from the end values.
        if coding.kind == .scale {
            let full = (a: space.screen(arrow.start), b: space.screen(arrow.tip))
            for step in coding.steps {
                let t = CGFloat((step.from + step.to) / 2)
                let p = CGPoint(x: full.a.x + (full.b.x - full.a.x) * t - normal.x * 1.6, y: full.a.y + (full.b.y - full.a.y) * t - normal.y * 1.6)
                context.draw(Text(step.name).font(.system(size: 11, weight: step.isRoot ? .heavy : .semibold)).foregroundColor(.white),
                             at: p, anchor: side > 0 ? .trailing : .leading)
            }
        }
    }

    // MARK: Selection

    private func drawSelection(_ shapes: [SurfacePreparedShape], layout: SurfaceHandleLayout, in context: inout GraphicsContext,
                               transform t: CGAffineTransform, space: SurfaceCanvasSpace) {
        guard !layout.handles.isEmpty || !layout.frame.isEmpty else { return }
        if layout.frame.count >= 2 {
            var frame = Path(); frame.move(to: layout.frame[0])
            for p in layout.frame.dropFirst() { frame.addLine(to: p) }
            frame.closeSubpath()
            context.stroke(frame, with: .color(StageTheme.amber), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
        }
        let half = layout.size / 2
        for handle in layout.handles {
            let rect = CGRect(x: handle.center.x - half, y: handle.center.y - half, width: layout.size, height: layout.size)
            let path = handle.kind.isAxis ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 3)
            context.fill(path, with: .color(handle.isEnabled ? .white : Color.gray.opacity(0.45)))
            context.stroke(path, with: .color(handle.isEnabled ? StageTheme.amber : Color.gray), lineWidth: 1.5)
        }
    }

    // MARK: Sketch

    private func drawSketch(_ shapes: [SurfacePreparedShape], in context: inout GraphicsContext, transform t: CGAffineTransform, space: SurfaceCanvasSpace) {
        let ink = Color.white
        if let preview = model.preview {
            for (_, placement) in preview.placements {
                let path = Path(SurfaceOutline.path(shape: placement.shape, transform: placement.transform).copy(using: [t]) ?? CGMutablePath())
                context.fill(path, with: .color(StageTheme.amber.opacity(preview.isValid ? 0.22 : 0.1)))
                context.stroke(path, with: .color(preview.isValid ? StageTheme.amber : Color.red),
                               style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                dimensions(of: placement.shape, transform: placement.transform, in: &context, space: space)
            }
            if let drawn = preview.drawn {
                let path = Path(SurfaceOutline.path(shape: drawn.shape, transform: drawn.transform).copy(using: [t]) ?? CGMutablePath())
                context.fill(path, with: .color(StageTheme.amber.opacity(0.25)))
                context.stroke(path, with: .color(preview.isValid ? StageTheme.amber : Color.red), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                dimensions(of: drawn.shape, transform: drawn.transform, in: &context, space: space)
            }
            // The control arrow being turned: a dashed sketch of the new direction through the middle of the current arrow;
            // the document keeps the old one until the pointer is let go.
            if let sketch = preview.arrow,
               let arrow = shapes.first(where: { $0.surface.id == sketch.surfaceID && $0.routingID == sketch.routingID })?.coding?.arrow {
                let centre = SurfacePoint(x: (arrow.start.x + arrow.tip.x) / 2, y: (arrow.start.y + arrow.tip.y) / 2)
                let half = max(hypot(arrow.tip.x - arrow.start.x, arrow.tip.y - arrow.start.y) / 2, 5)
                let radians = sketch.degrees * .pi / 180
                let tip = SurfacePoint(x: centre.x + half * cos(radians), y: centre.y + half * sin(radians))
                let start = SurfacePoint(x: centre.x - half * cos(radians), y: centre.y - half * sin(radians))
                let a = space.screen(start), b = space.screen(tip)
                var line = Path(); line.move(to: a); line.addLine(to: b)
                context.stroke(line, with: .color(StageTheme.amber), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 4]))
                let angle = atan2(b.y - a.y, b.x - a.x), head: CGFloat = 12
                var point = Path()
                point.move(to: b)
                point.addLine(to: CGPoint(x: b.x - head * cos(angle - 0.45), y: b.y - head * sin(angle - 0.45)))
                point.addLine(to: CGPoint(x: b.x - head * cos(angle + 0.45), y: b.y - head * sin(angle + 0.45)))
                point.closeSubpath()
                context.fill(point, with: .color(StageTheme.amber))
                context.draw(Text(String(format: "Bearing %.0f°", SurfaceAxis.bearing(fromProgramDegrees: sketch.degrees))).font(.system(size: 11, weight: .bold)).foregroundColor(.white),
                             at: CGPoint(x: b.x + 14, y: b.y - 16), anchor: .leading)
            }
            if let marquee = preview.marquee {
                context.fill(Path(marquee), with: .color(ink.opacity(0.08)))
                context.stroke(Path(marquee), with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let message = preview.problem {
                context.draw(Text(message).font(.system(size: 11, weight: .semibold)).foregroundColor(.red),
                             at: CGPoint(x: geometry.canvasRect.midX, y: geometry.canvasRect.minY + 16), anchor: .center)
            }
        }
        if let draft = model.polygon {
            var path = Path()
            let screenPoints = draft.points.map { space.screen($0) }
            if let first = screenPoints.first {
                path.move(to: first)
                for p in screenPoints.dropFirst() { path.addLine(to: p) }
                if let hover = draft.hover { path.addLine(to: space.screen(hover)) }
            }
            context.stroke(path, with: .color(draft.problems.isEmpty ? StageTheme.amber : Color.red), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            for (index, p) in screenPoints.enumerated() {
                let rect = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: rect), with: .color(index == 0 && draft.canClose ? StageTheme.amber : .white))
                context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.6)), lineWidth: 1)
            }
            if let message = draft.message {
                context.draw(Text(message).font(.system(size: 11, weight: .semibold)).foregroundColor(draft.problems.isEmpty ? .white : .red),
                             at: CGPoint(x: geometry.canvasRect.midX, y: geometry.canvasRect.minY + 16), anchor: .center)
            }
        } else if let hint = model.hint {
            context.draw(Text(hint).font(.system(size: 11, weight: .semibold)).foregroundColor(.orange),
                         at: CGPoint(x: geometry.canvasRect.midX, y: geometry.canvasRect.minY + 16), anchor: .center)
        }
    }

    private func dimensions(of shape: SurfaceShape, transform: SurfaceTransform, in context: inout GraphicsContext, space: SurfaceCanvasSpace) {
        let text: String
        switch shape {
        case .rectangle(let w, let h): text = String(format: "%.1f × %.1f cm", w, h)
        case .circle(let r): text = String(format: "r %.1f cm", r)
        case .ringSector(let from, let to, let fromDegrees, let toDegrees): text = String(format: "%.0f–%.0f cm · %.1f…%.1f°", from, to, fromDegrees, toDegrees)
        case .polygon: return
        }
        let anchor = space.screen(.init(x: transform.xCm, y: transform.yCm))
        context.draw(Text(text).font(.system(size: 11, weight: .bold)).foregroundColor(.white),
                     at: CGPoint(x: anchor.x, y: anchor.y), anchor: .center)
    }
}
