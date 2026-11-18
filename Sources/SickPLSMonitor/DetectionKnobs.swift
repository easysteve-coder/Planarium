import SwiftUI
import SickPLSMonitorKit
import PlanariumDomain

/// Rastender Drehknopf der Detektion. Senkrecht ziehen ändert in Schritten
/// (`DetectionKnobLaw`), Doppelklick setzt die Vorgabe. Ein Zug ist ein
/// zusammenhängender Bearbeitungsschritt (`onEditing`).
struct DetectionKnob: View {
    let title: String
    /// Raststellungen in aufsteigender Reihenfolge.
    let values: [Int]
    /// Gespeicherter Wert außerhalb des Zugs; im Zug gilt der lokale Wert.
    let value: Int
    let defaultValue: Int
    let format: (Int) -> String
    let help: String
    let select: (Int) -> Void
    var onEditing: (Bool) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    var isEnabled = true
    var showsMagnet = false
    var accessibilityID: String? = nil
    var onPreview: (Int?) -> Void = { _ in }
    @StateObject var drag = ControlDragSession()

    static func draggedValue(startValue: Int, values: [Int], translationY: Double) -> Int {
        guard !values.isEmpty else { return startValue }
        guard translationY.isFinite, abs(translationY) >= DetectionKnobLaw.pointsPerStep else { return startValue }
        let nearest = DetectionKnobLaw.nearestIndex(of: startValue, in: values)
        // An off-grid value chooses its first neighbour in the drag direction.
        // Softness 45 % therefore moves to 40 down, or 50 up, never 30 down.
        let adjustment = startValue > values[nearest] && translationY > 0 ? 1 :
            (startValue < values[nearest] && translationY < 0 ? -1 : 0)
        let next = DetectionKnobLaw.index(start: nearest + adjustment, translationY: translationY, count: values.count)
        return values[next]
    }

    /// Pointer feedback stays local; only the Canvas receives the draft.
    /// Document publication and compilation happen once through the release tail.
    func changeDrag(translationY: Double, fine: Bool) {
        drag.begin(Double(value), write: { select(Int($0)) }, editing: { editing in
            onEditing(editing)
            if !editing { onPreview(nil) }
        })
        let translation = drag.translated(translationY, fine: fine)
        let next = Self.draggedValue(startValue: Int(drag.initial ?? Double(value)), values: values, translationY: translation)
        guard drag.isActive else { return }
        drag.change(Double(next), live: false)
        onPreview(next)
    }

    var body: some View {
        let shownValue = drag.displayed.map { Int($0) } ?? value
        let index = DetectionKnobLaw.nearestIndex(of: shownValue, in: values)
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                if showsMagnet {
                    // Code-drawn horseshoe avoids an SF Symbol newer than macOS 12.
                    Path { path in
                        path.move(to: CGPoint(x: 1, y: 1))
                        path.addLine(to: CGPoint(x: 1, y: 5))
                        path.addCurve(to: CGPoint(x: 9, y: 5), control1: CGPoint(x: 1, y: 11), control2: CGPoint(x: 9, y: 11))
                        path.addLine(to: CGPoint(x: 9, y: 1))
                    }.stroke(lineWidth: 2).frame(width: 10, height: 10)
                }
                Text(title.uppercased())
            }
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 22, alignment: .center)
            DetectionKnobFace(fraction: values.count > 1 ? Double(index) / Double(values.count - 1) : 0,
                              diameter: 30, isEnabled: isEnabled)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { event in
                        changeDrag(translationY: Double(event.translation.height), fine: NSEvent.modifierFlags.contains(.option))
                    }
                    .onEnded { _ in drag.finish() })
                .simultaneousGesture(TapGesture(count: 2).onEnded { drag.cancel(); drag.finish(); if defaultValue != value { select(defaultValue) } })
                .modifier(ControlScrollAction { delta, _ in
                    let next = min(values.count - 1, max(0, index + (delta > 0 ? 1 : -1)))
                    select(values[next])
                })
                .onDisappear { drag.cancel(); drag.finish() }
            Text(format(shownValue))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: 58)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
        .allowsHitTesting(isEnabled)
        .help(help + " Drag up or down; double-click for the default.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityID ?? "")
        .accessibilityValue(format(shownValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < values.count { select(values[index + 1]) }
            case .decrement: if index > 0 { select(values[index - 1]) }
            @unknown default: break
            }
        }
        .onHover(perform: onHover)
    }
}

/// Drehschalter mit beschrifteten Raststellungen rund um den Knopf; ein
/// Klick auf eine Beschriftung wählt sie direkt, ein Klick auf den Knopf
/// schaltet eine Stellung weiter.
struct DetectionRotarySwitch: View {
    let title: String
    var accessibilityTitle: String? = nil
    var accessibilityID: String? = nil
    let labels: [String]
    let index: Int
    let help: String
    let select: (Int) -> Void
    var onHover: (Bool) -> Void = { _ in }
    var showsEdgePoints = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                if showsEdgePoints {
                    Path { path in
                        path.move(to: CGPoint(x: 1, y: 1)); path.addLine(to: CGPoint(x: 4, y: 7))
                        path.addLine(to: CGPoint(x: 10, y: 7)); path.addLine(to: CGPoint(x: 13, y: 1))
                        path.move(to: CGPoint(x: 0, y: 4)); path.addLine(to: CGPoint(x: 4, y: 0))
                        path.move(to: CGPoint(x: 10, y: 0)); path.addLine(to: CGPoint(x: 14, y: 4))
                    }.stroke(lineWidth: 1).frame(width: 14, height: 9)
                }
                Text(title.uppercased())
            }
                .font(.system(size: showsEdgePoints ? 7 : 8, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1).fixedSize()
            ZStack {
                ForEach(labels.indices, id: \.self) { position in
                    let radians = DetectionKnobLaw.angle(index: position, count: labels.count) * .pi / 180
                    Button { select(position) } label: {
                        Text(labels[position])
                            .font(.system(size: 8, weight: position == index ? .bold : .medium))
                            .foregroundColor(position == index ? .accentColor : .secondary)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .offset(x: (showsEdgePoints ? 24 : 30) * sin(radians), y: -(showsEdgePoints ? 24 : 30) * cos(radians))
                }
                DetectionKnobFace(fraction: Double(index) / Double(max(1, labels.count - 1)), diameter: 30, isEnabled: true)
                    .onTapGesture { select((index + 1) % max(1, labels.count)) }
            }
            .frame(width: showsEdgePoints ? 72 : 96, height: 66)
        }
        .help(help + " Click a position, or click the knob to step.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityIdentifier(accessibilityID ?? "")
        .accessibilityValue(labels.indices.contains(index) ? labels[index] : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < labels.count { select(index + 1) }
            case .decrement: if index > 0 { select(index - 1) }
            @unknown default: break
            }
        }
        .onHover(perform: onHover)
    }
}

/// Gemeinsames Aussehen: dunkler Knopf, Wertbogen in Akzentfarbe, Zeiger.
struct DetectionKnobFace: View {
    let fraction: Double
    let diameter: CGFloat
    let isEnabled: Bool

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        ZStack {
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.125, to: 0.125 + 0.75 * clamped)
                .stroke(isEnabled ? Color.accentColor : Color.secondary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(5)
                .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
            Capsule()
                .fill(Color.white.opacity(0.85))
                .frame(width: 2, height: diameter * 0.22)
                .offset(y: -diameter * 0.2)
                .rotationEffect(.degrees(-135 + 270 * clamped))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
    }
}


/// Only LiveMeasurementCanvas observes this draft; no authoring publication.
@MainActor final class DetectionCanvasPreview: ObservableObject {
    @Published private(set) var configuration: DetectionConfiguration?
    /// Offline test observation only; unset in production.
    var didRender: ((DetectionConfiguration, DetectionOverlayPresentation) -> Void)?
    private var marginLayer: SpatialInstrumentLayer?
    private var marginGrid: MetricSquareGrid?
    private var marginSegments: [PolarMetricCellSegment] = []
    func holdMargins(layer: SpatialInstrumentLayer, grid: MetricSquareGrid, centimeters: UInt16) -> DetectionOverlayPresentation {
        if marginLayer != layer || marginGrid != grid {
            marginSegments = layer.polarCells.sorted { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }
                .map { PolarMetricCellSegment(cell: $0, grid: grid) }
            marginLayer = layer; marginGrid = grid
        }
        return .cellMargins(segments: marginSegments, centimeters: centimeters, outside: true)
    }
    private let snapRegions = SnapRegionOverlayCache()
    var snapCompilationCount: Int { snapRegions.compilationCount }
    func snapMargins(document: InstrumentDocument, layerID: UUID, centimeters: UInt16) -> DetectionOverlayPresentation {
        snapRegions.presentation(document: document, layerID: layerID, centimeters: centimeters)
    }
    func update(_ configuration: DetectionConfiguration?) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
    }
    func action(_ id: DetectionControlDescriptor.ID, base: DetectionConfiguration,
                matchingContour: Bool, performing: Bool) -> (Int?) -> Void {
        { [weak self] value in
            self?.update(value.map { DetectionControlDescriptor.descriptor(id).applying($0, to: base,
                hasMatchingContour: matchingContour, performing: performing) })
        }
    }
}
