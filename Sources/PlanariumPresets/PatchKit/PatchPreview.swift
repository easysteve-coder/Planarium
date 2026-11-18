import Foundation
import PlanariumDomain

/// Static, self-contained SVG of the cells a recipe really produces. Built as plain
/// strings from the checked build: no scripts, no external references, no images,
/// no sound or state bytes. Cells are drawn as polar boxes (a ring range × a tick
/// range per path segment), so a band is one box and a 1 m table layout stays small.
public enum PatchPreview {
    /// Boxes beyond this would make a heavy file; the preview then refuses instead of dropping cells.
    static let maximumBoxes = 100_000

    public static func svg(for build: PatchBuild) throws -> String {
        let drawing = build.drawing
        var boxesPerRegion: [[Box]] = []
        var total = 0
        for region in drawing.regions {
            let boxes = Box.merge(region.cells)
            total += boxes.count
            boxesPerRegion.append(boxes)
        }
        guard total <= maximumBoxes else {
            throw PatchKitError("the preview would need \(total) shapes (more than \(maximumBoxes)) — the cell pattern is too fine to draw without leaving cells out")
        }

        // Plot bounds in centimetres: play area, scanner, every drawn cell, plus a margin.
        var bounds = drawing.playArea.bounds.union(PatchBounds(minX: 0, maxX: 0, minY: 0, maxY: 0))
        for boxes in boxesPerRegion { for box in boxes { bounds = bounds.union(box.bounds) } }
        let margin = max(5, 0.06 * max(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY))
        bounds = PatchBounds(minX: bounds.minX - margin, maxX: bounds.maxX + margin, minY: min(bounds.minY - margin, -margin), maxY: bounds.maxY + margin)
        let spanX = bounds.maxX - bounds.minX, spanY = bounds.maxY - bounds.minY
        let scale = (880 / spanX).clamped(to: 0.4...8.0)
        let plotWidth = spanX * scale, plotHeight = spanY * scale
        let left = 64.0, top = 78.0
        let width = max(plotWidth + left + 40, 760)
        let legendTop = top + plotHeight + 96
        let overlapLines = drawing.overlaps.count
        let height = legendTop + 28 + Double(drawing.regions.count) * 22 + Double(overlapLines) * 20 + 40

        func px(_ x: Double) -> Double { left + (x - bounds.minX) * scale }
        func py(_ y: Double) -> Double { top + (bounds.maxY - y) * scale }
        func num(_ value: Double) -> String { PatchNumber.text(value) }
        func pair(_ x: Double, _ y: Double) -> String { "\(num(px(x))) \(num(py(y)))" }

        var out: [String] = []
        out.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        out.append(#"<svg xmlns="http://www.w3.org/2000/svg" width="\#(num(width))" height="\#(num(height))" viewBox="0 0 \#(num(width)) \#(num(height))" role="img" aria-labelledby="t d" font-family="Helvetica, Arial, sans-serif">"#)
        out.append("<title id=\"t\">\(escape(drawing.name)) — cell preview</title>")
        out.append("<desc id=\"d\">Cells of the recipe as they will exist in the preset. Scanner at (0, 0), +x right, +y forward, centimetres. Structure only — nothing was loaded or listened to.</desc>")
        out.append("<rect width=\"100%\" height=\"100%\" fill=\"#ffffff\"/>")
        out.append("<text x=\"\(num(left))\" y=\"30\" font-size=\"20\" font-weight=\"bold\" fill=\"#222222\">\(escape(drawing.name))</text>")
        out.append("<text x=\"\(num(left))\" y=\"52\" font-size=\"12\" fill=\"#555555\">Recipe version \(drawing.version) · play area \(escape(drawing.playArea.summary)) · scanner at (0, 0), +x right, +y forward, centimetres · structure only, no sound</text>")
        out.append("<rect x=\"\(num(left))\" y=\"\(num(top))\" width=\"\(num(plotWidth))\" height=\"\(num(plotHeight))\" fill=\"#fafafa\" stroke=\"#cccccc\"/>")

        // Grid with a cm label on both axes.
        let step = [1.0, 2, 5, 10, 20, 50, 100, 200, 500, 1000].first { $0 * scale >= 36 } ?? 1000
        var gridX = (bounds.minX / step).rounded(.up) * step
        while gridX <= bounds.maxX {
            out.append("<line x1=\"\(num(px(gridX)))\" y1=\"\(num(top))\" x2=\"\(num(px(gridX)))\" y2=\"\(num(top + plotHeight))\" stroke=\"\(gridX == 0 ? "#bbbbbb" : "#e4e4e4")\"/>")
            out.append("<text x=\"\(num(px(gridX)))\" y=\"\(num(top + plotHeight + 14))\" font-size=\"10\" fill=\"#777777\" text-anchor=\"middle\">\(num(gridX))</text>")
            gridX += step
        }
        var gridY = (bounds.minY / step).rounded(.up) * step
        while gridY <= bounds.maxY {
            out.append("<line x1=\"\(num(left))\" y1=\"\(num(py(gridY)))\" x2=\"\(num(left + plotWidth))\" y2=\"\(num(py(gridY)))\" stroke=\"\(gridY == 0 ? "#bbbbbb" : "#e4e4e4")\"/>")
            out.append("<text x=\"\(num(left - 6))\" y=\"\(num(py(gridY) + 3))\" font-size=\"10\" fill=\"#777777\" text-anchor=\"end\">\(num(gridY))</text>")
            gridY += step
        }
        out.append("<text x=\"\(num(left + plotWidth / 2))\" y=\"\(num(top + plotHeight + 30))\" font-size=\"11\" fill=\"#555555\" text-anchor=\"middle\">x (cm, right →)</text>")
        out.append("<text x=\"14\" y=\"\(num(top + plotHeight / 2))\" font-size=\"11\" fill=\"#555555\" text-anchor=\"middle\" transform=\"rotate(-90 14 \(num(top + plotHeight / 2)))\">y (cm, forward →)</text>")

        // Cells.
        for (region, boxes) in zip(drawing.regions, boxesPerRegion) {
            out.append("<g id=\"region-\(escape(region.id))\" fill=\"\(escape(region.color))\" fill-opacity=\"0.6\" stroke=\"\(escape(region.color))\" stroke-opacity=\"0.9\" stroke-width=\"0.5\">")
            out.append("<path d=\"" + boxes.map { $0.path(px: px, py: py, num: num) }.joined(separator: " ") + "\"/>")
            out.append("</g>")
        }
        // Region names at the centre of their cells.
        for region in drawing.regions where !region.cells.isEmpty {
            var sumX = 0.0, sumY = 0.0
            for cell in region.cells { let p = PatchGrid.point(ring: cell.ring, tick: cell.sector); sumX += p.x; sumY += p.y }
            let n = Double(region.cells.count)
            out.append("<text x=\"\(num(px(sumX / n)))\" y=\"\(num(py(sumY / n) + 4))\" font-size=\"12\" font-weight=\"bold\" fill=\"#111111\" stroke=\"#ffffff\" stroke-width=\"3\" paint-order=\"stroke\" text-anchor=\"middle\">\(escape(region.id))</text>")
        }

        // Play area edge.
        out.append("<path d=\"\(playAreaPath(drawing.playArea, px: px, py: py, num: num))\" fill=\"none\" stroke=\"#222222\" stroke-width=\"1.5\" stroke-dasharray=\"6 4\"/>")

        // Scanner and axes.
        let axisLength = [5.0, 10, 20, 50, 100, 200].first { $0 * scale >= 40 } ?? 200
        out.append("<g stroke=\"#222222\" stroke-width=\"1.5\" fill=\"#222222\">")
        out.append("<line x1=\"\(num(px(0)))\" y1=\"\(num(py(0)))\" x2=\"\(num(px(axisLength)))\" y2=\"\(num(py(0)))\"/>")
        out.append("<polygon stroke=\"none\" points=\"\(num(px(axisLength) + 7)),\(num(py(0))) \(num(px(axisLength))),\(num(py(0) - 4)) \(num(px(axisLength))),\(num(py(0) + 4))\"/>")
        out.append("<line x1=\"\(num(px(0)))\" y1=\"\(num(py(0)))\" x2=\"\(num(px(0)))\" y2=\"\(num(py(axisLength)))\"/>")
        out.append("<polygon stroke=\"none\" points=\"\(num(px(0))),\(num(py(axisLength) - 7)) \(num(px(0) - 4)),\(num(py(axisLength))) \(num(px(0) + 4)),\(num(py(axisLength)))\"/>")
        out.append("<circle cx=\"\(num(px(0)))\" cy=\"\(num(py(0)))\" r=\"5\" stroke=\"#ffffff\"/>")
        out.append("</g>")
        out.append("<text x=\"\(num(px(axisLength) + 10))\" y=\"\(num(py(0) + 4))\" font-size=\"11\" fill=\"#222222\">+x</text>")
        out.append("<text x=\"\(num(px(0) + 8))\" y=\"\(num(py(axisLength) - 8))\" font-size=\"11\" fill=\"#222222\">+y</text>")
        out.append("<text x=\"\(num(px(0) + 9))\" y=\"\(num(py(0) + 15))\" font-size=\"11\" fill=\"#222222\">Scanner (0, 0)</text>")

        // Scale bar.
        let barLength = [1.0, 2, 5, 10, 20, 50, 100, 200, 500, 1000].last { $0 * scale <= plotWidth * 0.3 } ?? 1
        let barY = top + plotHeight + 50
        out.append("<g stroke=\"#222222\" stroke-width=\"2\"><line x1=\"\(num(left))\" y1=\"\(num(barY))\" x2=\"\(num(left + barLength * scale))\" y2=\"\(num(barY))\"/>")
        out.append("<line x1=\"\(num(left))\" y1=\"\(num(barY - 4))\" x2=\"\(num(left))\" y2=\"\(num(barY + 4))\"/><line x1=\"\(num(left + barLength * scale))\" y1=\"\(num(barY - 4))\" x2=\"\(num(left + barLength * scale))\" y2=\"\(num(barY + 4))\"/></g>")
        out.append("<text x=\"\(num(left + barLength * scale + 10))\" y=\"\(num(barY + 4))\" font-size=\"11\" fill=\"#222222\">\(num(barLength)) cm (1 cm / 0.5° grid cells; bearing -90° left … +90° right)</text>")

        // Legend: region, note(s), channel.
        out.append("<text x=\"\(num(left))\" y=\"\(num(legendTop))\" font-size=\"13\" font-weight=\"bold\" fill=\"#222222\">Legend — region · notes · channel · cells</text>")
        var rowY = legendTop + 22
        for region in drawing.regions {
            let notes = region.notes.map { PatchNoteName.name(for: $0) + "=" + String($0) }.joined(separator: ", ")
            out.append("<rect x=\"\(num(left))\" y=\"\(num(rowY - 11))\" width=\"14\" height=\"14\" fill=\"\(escape(region.color))\" fill-opacity=\"0.6\" stroke=\"\(escape(region.color))\"/>")
            let label = region.label == region.id ? escape(region.id) : "\(escape(region.id)) (\(escape(region.label)))"
            out.append("<text x=\"\(num(left + 22))\" y=\"\(num(rowY))\" font-size=\"12\" fill=\"#222222\">\(label) · notes \(escape(notes)) · channel \(escape(region.channel)) · \(region.cells.count) cells</text>")
            rowY += 22
        }
        for overlap in drawing.overlaps {
            let kind = overlap.sameChannel ? "same channel" : "layered, different channels"
            out.append("<text x=\"\(num(left))\" y=\"\(num(rowY))\" font-size=\"12\" fill=\"#8a4b00\">overlap: \(escape(overlap.left)) × \(escape(overlap.right)) · \(overlap.cells) shared cells (\(kind))</text>")
            rowY += 20
        }
        out.append("</svg>")
        return out.joined(separator: "\n") + "\n"
    }

    private static func playAreaPath(_ area: PatchPlayArea, px: (Double) -> Double, py: (Double) -> Double, num: (Double) -> String) -> String {
        func pair(_ x: Double, _ y: Double) -> String { "\(num(px(x))) \(num(py(y)))" }
        switch area {
        case .rectangle(let xMin, let xMax, let yMin, let yMax):
            return "M \(pair(xMin, yMin)) L \(pair(xMax, yMin)) L \(pair(xMax, yMax)) L \(pair(xMin, yMax)) Z"
        case .sector(let from, let to, let fromDegrees, let toDegrees):
            return polarBox(innerCm: from, outerCm: to, fromDegrees: fromDegrees, toDegrees: toDegrees, px: px, py: py, num: num)
        }
    }

    /// Annular sector path between two radii and two bearings (spans up to 180°).
    fileprivate static func polarBox(innerCm: Double, outerCm: Double, fromDegrees: Double, toDegrees: Double,
                                     px: (Double) -> Double, py: (Double) -> Double, num: (Double) -> String) -> String {
        let a = PatchTrig.sinCos(degrees: fromDegrees), b = PatchTrig.sinCos(degrees: toDegrees)
        func pair(_ radius: Double, _ t: (sin: Double, cos: Double)) -> String { "\(num(px(radius * t.sin))) \(num(py(radius * t.cos)))" }
        let scale = abs(px(1) - px(0))
        let outerPixels = num(outerCm * scale), innerPixels = num(innerCm * scale)
        var path = "M \(pair(outerCm, a)) A \(outerPixels) \(outerPixels) 0 0 1 \(pair(outerCm, b)) L \(pair(innerCm, b))"
        if innerCm > 0 { path += " A \(innerPixels) \(innerPixels) 0 0 0 \(pair(innerCm, a))" } else { path += " L \(num(px(0))) \(num(py(0)))" }
        return path + " Z"
    }

    /// A group of grid cells: rings `r0…r1` crossed with ticks `t0…t1`.
    struct Box {
        let r0: Int, r1: Int, t0: Int, t1: Int
        var innerCm: Double { Double(r0) - 0.5 }
        var outerCm: Double { Double(r1) + 0.5 }
        /// Cells are points on the grid; the drawn box spans ±0.5 cm and ±0.25° (cut at the ±90° edge).
        var fromDegrees: Double { max(-90, PatchGrid.bearing(tick: t0) - 0.25) }
        var toDegrees: Double { min(90, PatchGrid.bearing(tick: t1) + 0.25) }
        var bounds: PatchBounds {
            var points: [PatchPoint] = []
            for radius in [innerCm, outerCm] {
                for degrees in [fromDegrees, toDegrees] {
                    let t = PatchTrig.sinCos(degrees: degrees)
                    points.append(PatchPoint(x: radius * t.sin, y: radius * t.cos))
                }
            }
            if fromDegrees < 0 && toDegrees > 0 { points.append(PatchPoint(x: 0, y: outerCm)) }
            return PatchBounds(minX: points.map(\.x).min()!, maxX: points.map(\.x).max()!, minY: points.map(\.y).min()!, maxY: points.map(\.y).max()!)
        }
        func path(px: (Double) -> Double, py: (Double) -> Double, num: (Double) -> String) -> String {
            PatchPreview.polarBox(innerCm: innerCm, outerCm: outerCm, fromDegrees: fromDegrees, toDegrees: toDegrees, px: px, py: py, num: num)
        }

        /// Cells (ordered by ring, then tick) → boxes; equal tick runs on neighbouring rings join into one box.
        static func merge(_ cells: [PolarDeviceLattice]) -> [Box] {
            var boxes: [Box] = []
            var open: [[Int]: Int] = [:]           // [t0, t1] → first ring of the open box
            var previousRing: Int?
            var index = 0
            func close(_ lastRing: Int, keeping keep: Set<[Int]>) {
                for (run, first) in open where !keep.contains(run) {
                    boxes.append(Box(r0: first, r1: lastRing, t0: run[0], t1: run[1]))
                    open[run] = nil
                }
            }
            while index < cells.count {
                let ring = cells[index].ring
                var runs: [[Int]] = []
                var start = cells[index].sector, last = start
                index += 1
                while index < cells.count, cells[index].ring == ring {
                    let tick = cells[index].sector
                    if tick == last + 1 { last = tick } else { runs.append([start, last]); start = tick; last = tick }
                    index += 1
                }
                runs.append([start, last])
                if let previousRing { close(previousRing, keeping: previousRing + 1 == ring ? Set(runs) : []) }
                for run in runs where open[run] == nil { open[run] = ring }
                previousRing = ring
            }
            if let previousRing { close(previousRing, keeping: []) }
            return boxes.sorted { ($0.r0, $0.t0, $0.r1, $0.t1) < ($1.r0, $1.t0, $1.r1, $1.t1) }
        }
    }

    /// XML-safe text: markup characters escaped, control characters dropped.
    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || (0xD800...0xDFFF).contains(scalar.value) { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
