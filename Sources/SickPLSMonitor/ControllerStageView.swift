import Combine
import SwiftUI
import PlanariumApplication
import PlanariumControllerCore
import PlanariumDomain
import PlanariumRuntime

/// Which playing sources the stage shows in its centre.
enum StageSourceChoice: String, CaseIterable {
    case scanner, controller, both
    var title: String {
        switch self {
        case .scanner: return "Stage: scanner"
        case .controller: return "Stage: game controller"
        case .both: return "Stage: scanner and game controller"
        }
    }
    /// Short caption when toolbar labels are shown.
    var caption: String {
        switch self {
        case .scanner: return "Scan"
        case .controller: return "Pad"
        case .both: return "Both"
        }
    }
    var symbol: String {
        switch self {
        case .scanner: return "scope"
        case .controller: return "gamecontroller"
        case .both: return "rectangle.split.2x1"
        }
    }
}

/// Where each element sits on the drawn controller, in a 420 × 260 design space.
struct ControllerStageGeometry {
    static let size = CGSize(width: 420, height: 260)

    static func frame(_ element: ControllerElement) -> CGRect {
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { .init(x: x - w / 2, y: y - h / 2, width: w, height: h) }
        switch element {
        case .l2: return rect(92, 18, 76, 20)
        case .r2: return rect(328, 18, 76, 20)
        case .l1: return rect(92, 44, 76, 14)
        case .r1: return rect(328, 44, 76, 14)
        case .dpadUp: return rect(100, 90, 22, 24)
        case .dpadDown: return rect(100, 134, 22, 24)
        case .dpadLeft: return rect(78, 112, 24, 22)
        case .dpadRight: return rect(122, 112, 24, 22)
        case .triangle: return rect(320, 88, 28, 28)
        case .cross: return rect(320, 136, 28, 28)
        case .square: return rect(296, 112, 28, 28)
        case .circle: return rect(344, 112, 28, 28)
        case .create: return rect(140, 66, 12, 22)
        case .options: return rect(280, 66, 12, 22)
        case .touchpad: return rect(210, 88, 124, 64)
        case .touchpadButton: return rect(210, 128, 44, 10)
        case .home: return rect(210, 176, 18, 18)
        case .leftStick, .l3: return rect(158, 168, 62, 62)
        case .rightStick, .r3: return rect(262, 168, 62, 62)
        }
    }

    /// The elements drawn as their own control (L3/R3 are clicks on the sticks).
    static let drawn: [ControllerElement] = ControllerElement.allCases.filter { $0 != .l3 && $0 != .r3 }

    static func isRound(_ element: ControllerElement) -> Bool {
        [.triangle, .cross, .square, .circle, .home].contains(element)
    }
}

/// What one drawn element shows: its assignment color, whether it is held
/// and whether an assignment on it is sounding.
struct ControllerElementLook: Equatable {
    var color: SpatialLayerColor?
    var held: Bool
    var playing: Bool
    var value: Double
    var position: ControllerPoint?
    var sectors: [(index: Int, count: Int, color: SpatialLayerColor, playing: Bool)]

    static func == (a: Self, b: Self) -> Bool {
        a.color == b.color && a.held == b.held && a.playing == b.playing && a.value == b.value && a.position == b.position &&
            a.sectors.map { "\($0.index)/\($0.count)/\($0.playing)" } == b.sectors.map { "\($0.index)/\($0.count)/\($0.playing)" }
    }

    static func make(_ element: ControllerElement, layout: ControllerLayout, display: ControllerDisplay, simulated: ControllerState) -> Self {
        let state = display.state.merging(simulated)
        let own = layout.assignments.filter { $0.isActive && ($0.element == element || (element.isPositional && $0.element == Self.click(of: element))) }
        let whole = own.first { $0.element == element && $0.zone == .whole } ?? own.first
        let sectors: [(Int, Int, SpatialLayerColor, Bool)] = own.compactMap { assignment in
            guard case let .sector(index, count) = assignment.zone else { return nil }
            return (index, count, assignment.color, display.playingAssignmentIDs.contains(assignment.id))
        }
        let clicked = Self.click(of: element).map { state.pressed.contains($0) } ?? false
        return .init(color: whole?.color, held: state.pressed.contains(element) || clicked || (state.values[element] ?? 0) > 0.05 || state.positions[element] != nil,
                     playing: own.contains { display.playingAssignmentIDs.contains($0.id) },
                     value: state.values[element] ?? 0, position: state.positions[element], sectors: sectors)
    }
    static func click(of element: ControllerElement) -> ControllerElement? {
        switch element {
        case .leftStick: return .l3
        case .rightStick: return .r3
        default: return nil
        }
    }
}

/// The animated controller in the centre of the stage. With the hand tool the
/// mouse plays it like the real device (the scanner's audition counterpart);
/// otherwise a click selects an element for its assignments.
/// Design space → view: the controller scaled to fit and centred.
struct ControllerStageFit: Equatable {
    let scale: CGFloat
    let origin: CGPoint
    init(_ size: CGSize) {
        let design = ControllerStageGeometry.size
        scale = max(0.01, min(size.width / design.width, size.height / design.height))
        origin = CGPoint(x: (size.width - design.width * scale) / 2, y: (size.height - design.height * scale) / 2)
    }
    var transform: CGAffineTransform { CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale) }
    func rect(_ element: ControllerElement) -> CGRect { ControllerStageGeometry.frame(element).applying(transform) }
}

/// The animated controller in the centre of the stage. The picture is drawn on
/// a native live layer: a device report or a mouse move marks only that layer
/// for display, no SwiftUI view is rebuilt. Static, transparent hit areas on top
/// play it with the mouse like the real device (the scanner's audition
/// counterpart); without the hand tool a click selects an element.
struct ControllerStageView: View {
    let display: PerformanceDisplayModel
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    /// Not observed: its simulated state changes with every mouse move and is
    /// drawn by the live layer; only the conflict count is read here.
    let stage: ControllerStageModel
    let editable: Bool
    @State private var deviceName: String?
    @State private var conflictCount = 0
    @State private var playsWithMouse: Bool
    @State private var selected: ControllerElement?

    init(display: PerformanceDisplayModel, instrument: SpatialInstrumentRuntimeModel, stage: ControllerStageModel, editable: Bool,
         playsWithMouse: Bool = true, selected: ControllerElement? = nil) {
        self.display = display; self.instrument = instrument; self.stage = stage; self.editable = editable
        _playsWithMouse = State(initialValue: playsWithMouse); _selected = State(initialValue: selected)
        _deviceName = State(initialValue: display.frame?.controller.deviceName)
        _conflictCount = State(initialValue: stage.conflicts.count)
    }

    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("controller.stageBody")
        VStack(spacing: 8) {
            header
            GeometryReader { proxy in
                let fit = ControllerStageFit(proxy.size)
                ZStack(alignment: .topLeading) {
                    ControllerLiveLayer(display: display, stage: stage, layout: instrument.document.controller,
                                        selected: playsWithMouse ? nil : selected)
                    ForEach(ControllerStageGeometry.drawn, id: \.self) { element in
                        ControllerHitArea(element: element, rect: fit.rect(element), playsWithMouse: playsWithMouse,
                                          stage: stage, select: { selected = $0 })
                    }
                }
            }
            .frame(minHeight: 120)
            if editable && !playsWithMouse, let selected {
                ControllerAssignmentInspector(instrument: instrument, stage: stage, element: selected)
            }
        }
        .padding(8)
        .background(StageTheme.canvas)
        .onReceive(display.$frame.map { $0?.controller.deviceName }.removeDuplicates()) { name in
            if name != deviceName { deviceName = name }
        }
        .onReceive(stage.$conflicts.map(\.count).removeDuplicates()) { count in
            if count != conflictCount { conflictCount = count }
        }
        .onDisappear { stage.releaseSimulation() }
        .accessibilityIdentifier("controller.stage")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: deviceName == nil ? "gamecontroller" : "gamecontroller.fill")
                .foregroundColor(deviceName == nil ? .secondary : StageTheme.amberBright)
                .help(deviceName.map { "\($0) connected" } ?? "No game controller connected · the mouse plays the drawn one")
            Text(deviceName ?? "Simulation").font(.caption).foregroundColor(.secondary)
            Spacer()
            if conflictCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    .help("\(conflictCount) assignment(s) silent: the scanner already plays that output")
            }
            if editable {
                Menu {
                    ForEach(ControllerAssistant.allCases, id: \.self) { assistant in
                        Button(assistant.title) { apply(assistant) }
                    }
                } label: { Image(systemName: "wand.and.stars") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Assistant: set up drums, a melody or chords in one step")
                IconToggle("Play with the mouse", symbol: "hand.point.up.left", isOn: $playsWithMouse)
            }
        }
    }

    /// Assistants play on the first instrument strip, or MIDI channel 10 (drums) / 1 without one.
    private func apply(_ assistant: ControllerAssistant) {
        let strip = instrument.document.channels.first { $0.instrument != nil }
        let output: ControllerAssistantOutput = strip.map { .audioUnit(stripID: $0.id, channel: 0) }
            ?? .midi(channel: assistant == .drums ? 9 : 0)
        instrument.setControllerLayout(assistant.applied(to: instrument.document.controller, output: output),
                                       name: "Controller assistant: \(assistant.title)")
    }
}

/// The controller picture on a native live layer. The layout and selection
/// re-install the painter (document edits); device and mouse state only mark
/// the layer for display.
private struct ControllerLiveLayer: NSViewRepresentable {
    let display: PerformanceDisplayModel
    let stage: ControllerStageModel
    let layout: ControllerLayout
    let selected: ControllerElement?

    @MainActor final class Coordinator {
        private(set) var shown: ControllerDisplay = .idle
        private(set) var simulated: ControllerState = .neutral
        private var sources: [ObjectIdentifier] = []
        private var subscriptions: [AnyCancellable] = []
        /// Delivered values are stored: `@Published` emits before it assigns.
        func observe(_ display: PerformanceDisplayModel, _ stage: ControllerStageModel, view: LiveLayerView) {
            let identities = [ObjectIdentifier(display), ObjectIdentifier(stage)]
            guard identities != sources else { return }
            sources = identities
            shown = display.frame?.controller ?? .idle
            simulated = stage.simulated
            subscriptions = [
                display.$frame.map { $0?.controller ?? .idle }.removeDuplicates().sink { [weak self, weak view] next in
                    MainActor.assumeIsolated { guard let self, self.shown != next else { return }; self.shown = next; view?.needsDisplay = true }
                },
                stage.$simulated.removeDuplicates().sink { [weak self, weak view] next in
                    MainActor.assumeIsolated { guard let self, self.simulated != next else { return }; self.simulated = next; view?.needsDisplay = true }
                },
            ]
        }
        func cancel() { subscriptions.removeAll(); sources.removeAll() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> LiveLayerView { LiveLayerView() }
    func updateNSView(_ view: LiveLayerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.observe(display, stage, view: view)
        view.isPresenting = context.environment.presentationVisible
        let layout = layout, selected = selected
        view.paint = { [weak coordinator] canvas in
            guard let coordinator else { return }
            ViewEvaluationProbe.current?.record("controller.liveDraw")
            ControllerPainter.paint(&canvas, layout: layout, display: coordinator.shown, simulated: coordinator.simulated, selected: selected)
        }
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: LiveLayerView, coordinator: Coordinator) { coordinator.cancel() }
}

/// Draws the controller as vector shapes in design space, fitted to the canvas.
@MainActor enum ControllerPainter {
    static func paint(_ canvas: inout LiveCanvas, layout: ControllerLayout, display: ControllerDisplay,
                      simulated: ControllerState, selected: ControllerElement?) {
        let fit = ControllerStageFit(canvas.size)
        let t = fit.transform
        canvas.fill(body.applying(t), with: .color(Color.white.opacity(0.06)))
        canvas.stroke(body.applying(t), with: .color(StageTheme.border), lineWidth: 1.5)
        for element in ControllerStageGeometry.drawn {
            let look = ControllerElementLook.make(element, layout: layout, display: display, simulated: simulated)
            draw(element, look: look, in: &canvas, fit: fit)
        }
        if let selected {
            let rect = fit.rect(selected).insetBy(dx: -3, dy: -3)
            canvas.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(StageTheme.amberBright), lineWidth: 2)
        }
    }

    private static func color(_ value: SpatialLayerColor?) -> Color {
        guard let value else { return Color.white.opacity(0.35) }
        return Color(red: value.red, green: value.green, blue: value.blue)
    }

    private static func draw(_ element: ControllerElement, look: ControllerElementLook, in canvas: inout LiveCanvas, fit: ControllerStageFit) {
        let rect = fit.rect(element)
        let tint = color(look.color)
        let restOpacity = look.color == nil ? 0.12 : 0.3
        let line: CGFloat = look.playing ? 2 : 1
        switch element.kind {
        case .button:
            let shrink = look.held ? rect.width * 0.05 : 0
            let r = rect.insetBy(dx: shrink, dy: shrink)
            let shape = ControllerStageGeometry.isRound(element) ? Path(ellipseIn: r) : Path(roundedRect: r, cornerRadius: 4 * fit.scale)
            canvas.fill(shape, with: .color(tint.opacity(look.playing ? 1 : (look.held ? 0.7 : restOpacity))))
            canvas.stroke(shape, with: .color(tint.opacity(0.9)), lineWidth: line)
            if let symbol = symbol(element, in: r) {
                let ink = look.playing ? StageTheme.readableInk(on: tint) : tint
                canvas.stroke(symbol, with: .color(ink), style: StrokeStyle(lineWidth: max(1, 1.8 * fit.scale), lineCap: .round, lineJoin: .round))
            }
            if [.l1, .r1].contains(element) {
                canvas.draw(text: element.displayName, font: .system(size: max(7, 8 * fit.scale), weight: .semibold),
                            color: Color.white.opacity(0.75), at: CGPoint(x: r.midX, y: r.midY))
            }
        case .trigger:
            let shape = Path(roundedRect: rect, cornerRadius: 5 * fit.scale)
            canvas.fill(shape, with: .color(tint.opacity(look.color == nil ? 0.12 : 0.25)))
            if look.value > 0 {
                let height = rect.height * CGFloat(look.value)
                canvas.withClip(shape) { inner in
                    inner.fill(Path(CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)),
                               with: .color(tint.opacity(look.playing ? 1 : 0.7)))
                }
            }
            canvas.stroke(shape, with: .color(tint.opacity(0.9)), lineWidth: line)
            canvas.draw(text: element.displayName, font: .system(size: max(7, 9 * fit.scale), weight: .semibold),
                        color: Color.white.opacity(0.8), at: CGPoint(x: rect.midX, y: rect.midY))
        case .stick, .surface:
            let shape = element.kind == .stick ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 10 * fit.scale)
            canvas.fill(shape, with: .color(tint.opacity(look.color == nil ? 0.10 : 0.2)))
            canvas.withClip(shape) { inner in
                for sector in look.sectors {
                    inner.fill(wedge(index: sector.index, count: sector.count, in: rect),
                               with: .color(color(sector.color).opacity(sector.playing ? 0.95 : 0.3)))
                }
            }
            canvas.stroke(shape, with: .color(tint.opacity(0.9)), lineWidth: line)
            if element.kind == .stick {
                let point = look.position ?? .init(x: 0, y: 0)
                let knob = rect.width * 0.45
                let center = CGPoint(x: rect.midX + CGFloat(point.x) * rect.width * 0.28, y: rect.midY - CGFloat(point.y) * rect.height * 0.28)
                canvas.fill(Path(ellipseIn: CGRect(x: center.x - knob / 2, y: center.y - knob / 2, width: knob, height: knob)),
                            with: .color(tint.opacity(look.playing ? 1 : 0.6)))
            } else if let point = look.position {
                let dot = 12 * fit.scale
                let center = CGPoint(x: rect.midX + CGFloat(point.x) * rect.width / 2, y: rect.midY - CGFloat(point.y) * rect.height / 2)
                canvas.fill(Path(ellipseIn: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)), with: .color(tint))
            }
        }
    }

    /// Sector `index` of `count`, clockwise from up, sector 0 centred on up.
    static func wedge(index: Int, count: Int, in rect: CGRect) -> Path {
        let width = 360 / Double(max(count, 1))
        let start = Double(index) * width - width / 2 - 90
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: hypot(rect.width, rect.height), startAngle: .degrees(start), endAngle: .degrees(start + width), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// The face symbols and arrows, drawn as strokes.
    private static func symbol(_ element: ControllerElement, in rect: CGRect) -> Path? {
        let c = CGPoint(x: rect.midX, y: rect.midY), s = min(rect.width, rect.height) * 0.22
        var path = Path()
        switch element {
        case .cross:
            path.move(to: CGPoint(x: c.x - s, y: c.y - s)); path.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
            path.move(to: CGPoint(x: c.x + s, y: c.y - s)); path.addLine(to: CGPoint(x: c.x - s, y: c.y + s))
        case .circle: path.addEllipse(in: CGRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s))
        case .square: path.addRect(CGRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s))
        case .triangle:
            path.move(to: CGPoint(x: c.x, y: c.y - s * 1.1)); path.addLine(to: CGPoint(x: c.x + s * 1.1, y: c.y + s * 0.8))
            path.addLine(to: CGPoint(x: c.x - s * 1.1, y: c.y + s * 0.8)); path.closeSubpath()
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight:
            let a: CGFloat = s * 1.2
            let tips: [CGPoint]
            switch element {
            case .dpadUp: tips = [CGPoint(x: c.x, y: c.y - a), CGPoint(x: c.x + a, y: c.y + a * 0.6), CGPoint(x: c.x - a, y: c.y + a * 0.6)]
            case .dpadDown: tips = [CGPoint(x: c.x, y: c.y + a), CGPoint(x: c.x + a, y: c.y - a * 0.6), CGPoint(x: c.x - a, y: c.y - a * 0.6)]
            case .dpadLeft: tips = [CGPoint(x: c.x - a, y: c.y), CGPoint(x: c.x + a * 0.6, y: c.y - a), CGPoint(x: c.x + a * 0.6, y: c.y + a)]
            default: tips = [CGPoint(x: c.x + a, y: c.y), CGPoint(x: c.x - a * 0.6, y: c.y - a), CGPoint(x: c.x - a * 0.6, y: c.y + a)]
            }
            path.addLines(tips); path.closeSubpath()
        case .home: path.addEllipse(in: CGRect(x: c.x - s * 0.8, y: c.y - s * 0.8, width: 1.6 * s, height: 1.6 * s))
        default: return nil
        }
        return path
    }

    /// One outline: a wide top, two grips and the bridge between them.
    static let body: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 120, y: 30))
        path.addLine(to: CGPoint(x: 300, y: 30))
        path.addCurve(to: CGPoint(x: 400, y: 120), control1: CGPoint(x: 370, y: 30), control2: CGPoint(x: 395, y: 70))
        path.addCurve(to: CGPoint(x: 360, y: 248), control1: CGPoint(x: 408, y: 180), control2: CGPoint(x: 400, y: 245))
        path.addCurve(to: CGPoint(x: 296, y: 210), control1: CGPoint(x: 330, y: 252), control2: CGPoint(x: 312, y: 228))
        path.addCurve(to: CGPoint(x: 124, y: 210), control1: CGPoint(x: 260, y: 196), control2: CGPoint(x: 160, y: 196))
        path.addCurve(to: CGPoint(x: 60, y: 248), control1: CGPoint(x: 108, y: 228), control2: CGPoint(x: 90, y: 252))
        path.addCurve(to: CGPoint(x: 20, y: 120), control1: CGPoint(x: 20, y: 245), control2: CGPoint(x: 12, y: 180))
        path.addCurve(to: CGPoint(x: 120, y: 30), control1: CGPoint(x: 25, y: 70), control2: CGPoint(x: 50, y: 30))
        path.closeSubpath()
        return path
    }()
}

/// A transparent mouse area over one drawn element. It never reads live state,
/// so device reports do not rebuild it.
private struct ControllerHitArea: View {
    let element: ControllerElement
    let rect: CGRect
    let playsWithMouse: Bool
    let stage: ControllerStageModel
    let select: (ControllerElement) -> Void
    @State private var dragging = false

    var body: some View {
        Color.clear
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .position(x: rect.midX, y: rect.midY)
            .gesture(gesture)
            .help(element.displayName)
            .accessibilityElement()
            .accessibilityLabel(element.displayName)
            .accessibilityAddTraits(.isButton)
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard playsWithMouse else { return }
                switch element.kind {
                case .button:
                    if !dragging { dragging = true; stage.press(element, true) }
                case .trigger:
                    dragging = true
                    // Dragging down pulls the trigger; the start counts as a light touch.
                    stage.setValue(element, Double(max(0.15, min(1, value.translation.height / (2 * rect.height) + 0.15))))
                case .stick, .surface:
                    dragging = true
                    let x = Double((value.location.x - rect.width / 2) / (rect.width / 2))
                    let y = Double(-(value.location.y - rect.height / 2) / (rect.height / 2))
                    stage.setPosition(element, .init(x: x, y: y))
                }
            }
            .onEnded { value in
                guard playsWithMouse else { select(element); return }
                dragging = false
                switch element.kind {
                case .button: stage.press(element, false)
                case .trigger: stage.setValue(element, nil)
                case .stick, .surface:
                    stage.setPosition(element, nil)
                    // A click without movement is the stick click (L3/R3).
                    if hypot(value.translation.width, value.translation.height) < 2, let click = ControllerElementLook.click(of: element) {
                        stage.press(click, true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { stage.press(click, false) }
                    }
                }
            }
    }
}
