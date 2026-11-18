import Foundation
import PlanariumDomain
import PLSDeviceValues

// How a surface shows the course of a CC or a scale over its area: a gradient for a continuous value,
// steps for the notes a scale really allows, an arrow and a legend that name the direction in words.
// Every value is asked of `SurfaceValueField`, which asks the production value plan: there is no
// second CC or scale formula here, and colours are only a coding, never a value.

public enum SurfaceScaleName {
    public static func text(_ scale: SpatialScale) -> String {
        switch scale {
        case .chromatic: return "Chromatic"
        case .major: return "Major"
        case .naturalMinor: return "Natural minor"
        case .majorPentatonic: return "Major pentatonic"
        case .minorPentatonic: return "Minor pentatonic"
        }
    }
}

/// The control arrow of one assignment in world centimetres: from the end that carries the low
/// value (or the low note) to the end that carries the high one. Its length is the surface's extent
/// along the axis, which is exactly where the runtime's value plan spreads the course.
public struct SurfaceAxisPresentation: Equatable, Sendable {
    public let routingID: UUID
    public let start: SurfacePoint
    public let tip: SurfacePoint
    /// World angle the arrow points to (program convention: 0 = right, counter-clockwise).
    public let arrowDegrees: Double
    /// The same direction as a bearing (0° = front, clockwise), the scanner's own way to say it.
    public var arrowBearingDegrees: Double { SurfaceAxis.bearing(fromProgramDegrees: arrowDegrees) }

    public init?(surface: SpatialSurface, routingID: UUID) {
        guard let field = try? SurfaceValueField(surface: surface, routingID: routingID),
              let arrow = field.arrowDegrees, let range = field.projectionCentimeters,
              let routing = surface.materializedRoutings().first(where: { $0.id == routingID }),
              let direction = SurfaceAxis.directionDegrees(of: routing.program) else { return nil }
        let bounds = surface.worldBounds
        let centre = SurfacePoint(x: (bounds.minX + bounds.maxX) / 2, y: (bounds.minY + bounds.maxY) / 2)
        let radians = direction * .pi / 180, ux = cos(radians), uy = sin(radians)
        let along = centre.x * ux + centre.y * uy
        func point(_ projection: Double) -> SurfacePoint {
            SurfacePoint(x: centre.x + ux * (projection - along), y: centre.y + uy * (projection - along))
        }
        let low = point(range.lowerBound), high = point(range.upperBound)
        self.routingID = routingID
        // Program direction runs from `low` to `high`; the arrow runs toward the higher value.
        if SurfaceAxis.risesAgainstDirection(routing.program) { start = high; tip = low } else { start = low; tip = high }
        arrowDegrees = arrow
    }
}

/// Colour coding of a value course. Colours the author chose, or a ramp of the surface colour.
public enum SurfaceColorRamp {
    /// The colour at `t` (0 = low value, 1 = high value).
    public static func color(at t: Double, presentation: SpatialSurface.Presentation) -> SpatialLayerColor {
        let t = min(max(t.isFinite ? t : 0, 0), 1)
        let stops = stops(presentation)
        let scaled = t * Double(stops.count - 1)
        let index = min(Int(scaled), stops.count - 2)
        let f = scaled - Double(index)
        let a = stops[index], b = stops[index + 1]
        return SpatialLayerColor(red: a.red + (b.red - a.red) * f, green: a.green + (b.green - a.green) * f,
                                 blue: a.blue + (b.blue - a.blue) * f, alpha: 1)
    }
    /// The author's colours (two or more), otherwise dark to bright of the surface colour.
    public static func stops(_ presentation: SpatialSurface.Presentation) -> [SpatialLayerColor] {
        if presentation.valueColors.count >= 2 { return presentation.valueColors }
        let base = presentation.color
        let low = SpatialLayerColor(red: base.red * 0.28, green: base.green * 0.28, blue: base.blue * 0.28)
        let high = SpatialLayerColor(red: base.red + (1 - base.red) * 0.55, green: base.green + (1 - base.green) * 0.55,
                                     blue: base.blue + (1 - base.blue) * 0.55)
        return [low, high]
    }
}

/// What the surface shows for one assignment: arrow, legend, gradient stops or note steps.
public struct SurfaceValueCoding: Equatable, Sendable {
    public struct Stop: Equatable, Sendable {
        /// Position along the arrow, 0 at its start and 1 at its tip.
        public let position: Double
        /// Value on the colour ramp, 0 = lowest value of the range, 1 = highest.
        public let level: Double
        public let color: SpatialLayerColor
    }
    public struct Step: Equatable, Sendable {
        public let note: Int
        public let name: String
        public let isRoot: Bool
        /// Part of the arrow this note owns: [from, to).
        public let from: Double
        public let to: Double
        public let color: SpatialLayerColor
    }
    public enum Kind: Equatable, Sendable { case none, continuous, scale }

    public let routingID: UUID
    public let kind: Kind
    public let arrow: SurfaceAxisPresentation?
    /// "CC74 · 0 → 127", "A3 → A4 · Minor pentatonic" – the direction in words, so colour is never the only cue.
    public let legend: String
    public let startText: String
    public let tipText: String
    public let stops: [Stop]
    public let steps: [Step]
    /// Which way the scale rises along the arrow is always "toward the tip"; this says it in words for scales.
    public let direction: String

    /// - Parameter stopCount: gradient resolution (stops are sampled from the real cells).
    public init?(surface: SpatialSurface, routingID: UUID, stopCount: Int = 17) {
        guard let field = try? SurfaceValueField(surface: surface, routingID: routingID),
              let routing = surface.materializedRoutings().first(where: { $0.id == routingID }) else { return nil }
        self.routingID = routingID
        arrow = SurfaceAxisPresentation(surface: surface, routingID: routingID)
        let presentation = surface.presentation
        switch field.legend {
        case .none:
            kind = .none; legend = ""; startText = ""; tipText = ""; stops = []; steps = []; direction = ""
        case let .continuous(controller, startValue, endValue, curve):
            kind = .continuous
            func text(_ value: Double) -> String { SpatialCellLabel.text(for: .scalar(value), target: routing.target) ?? "" }
            startText = text(startValue); tipText = text(endValue)
            let name = controller.map { "CC\($0)" } ?? "Value"
            legend = name + " · " + startText + " → " + tipText + (curve == .linear ? "" : " · " + Self.curveName(curve))
            steps = []
            direction = "toward the arrow tip the value rises"
            // Sample the real cells: for each stop the cell nearest to that place along the arrow.
            let lo = min(startValue, endValue), hi = max(startValue, endValue)
            let cells = surface.cells
            let stride = max(1, cells.count / 4000)
            var samples: [(position: Double, level: Double)] = []
            samples.reserveCapacity(cells.count / stride + 1)
            for index in Swift.stride(from: 0, to: cells.count, by: stride) {
                let cell = cells[index]
                guard case .scalar(let value) = field.sample(cell).value else { continue }
                samples.append((field.arrowFraction(cell), hi > lo ? (value - lo) / (hi - lo) : 0))
            }
            var result: [Stop] = []
            let count = max(2, stopCount)
            for k in 0..<count {
                let position = Double(k) / Double(count - 1)
                let best = samples.min { abs($0.position - position) < abs($1.position - position) }
                let level = best?.level ?? position
                result.append(Stop(position: position, level: level, color: SurfaceColorRamp.color(at: level, presentation: presentation)))
            }
            stops = result
        case let .scale(notes):
            kind = .scale
            stops = []
            guard case let .scale(root, _, _, scale, _, ascending, _) = routing.program else {
                steps = []; legend = ""; startText = ""; tipText = ""; direction = ""; return
            }
            // Along the arrow the notes rise; with a descending scale the arrow already points to the high end.
            let count = notes.count
            steps = notes.enumerated().map { index, note in
                Step(note: note, name: MIDINoteName.displayName(for: note), isRoot: ((note - root) % 12 + 12) % 12 == 0,
                     from: Double(index) / Double(max(count, 1)), to: Double(index + 1) / Double(max(count, 1)),
                     color: SurfaceColorRamp.color(at: count > 1 ? Double(index) / Double(count - 1) : 1, presentation: presentation))
            }
            startText = notes.first.map(MIDINoteName.displayName(for:)) ?? ""
            tipText = notes.last.map(MIDINoteName.displayName(for:)) ?? ""
            legend = startText + " → " + tipText + " · " + MIDINoteName.pitchClassName(for: root) + " " + SurfaceScaleName.text(scale)
            direction = ascending ? "pitch rises along the programmed direction" : "pitch falls along the programmed direction; the arrow points to the high notes"
        }
    }

    private static func curveName(_ curve: SpatialValueCurve) -> String {
        switch curve {
        case .linear: return "linear"
        case .easeIn: return "slow start"
        case .easeOut: return "slow finish"
        }
    }
}
