import SwiftUI
import SickPLSSimulationLink
import SickPLSMonitorKit

/// Feste, kontrastarme Bühnenpalette. Sie ist absichtlich nicht von der
/// momentanen macOS-Systemdarstellung abhängig: Ein hell eingestellter Mac
/// darf das Messfeld im dunklen Saal nicht weiß aufblitzen lassen.
enum StageTheme {
    private static func color(_ value: PlanariumRGBAColor) -> Color {
        Color(red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
    }
    @MainActor static func sameColor(_ lhs: Color, _ rhs: Color) -> Bool {
        guard let a = NSColor(lhs).usingColorSpace(.deviceRGB),
              let b = NSColor(rhs).usingColorSpace(.deviceRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.000001 &&
            abs(a.greenComponent - b.greenComponent) < 0.000001 &&
            abs(a.blueComponent - b.blueComponent) < 0.000001 &&
            abs(a.alphaComponent - b.alphaComponent) < 0.000001
    }
    static func readableInk(on color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return .white }
        let values = [rgb.redComponent,rgb.greenComponent,rgb.blueComponent].map { value -> Double in
            let v = Double(value); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = zip(values,[0.2126,0.7152,0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        return luminance > 0.179 ? .black : .white
    }
    static let workspace = color(PlanariumPalette.workspace)
    static let canvas = color(PlanariumPalette.canvas)
    static let border = color(PlanariumPalette.border)
    static let amber = color(PlanariumPalette.amber)
    static let amberBright = color(PlanariumPalette.amberBright)
    static let grid = color(PlanariumPalette.grid)
}

private struct FieldToolbarLabelsKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var fieldToolbarLabels: Bool {
        get { self[FieldToolbarLabelsKey.self] }
        set { self[FieldToolbarLabelsKey.self] = newValue }
    }
}

struct FieldToolbarLabelMenu: View {
    @Binding var labels: Bool
    var body: some View {
        SelectionMenuItem("Show labels", selected: labels) { labels = true }
        SelectionMenuItem("Icons only", selected: !labels) { labels = false }
    }
}

/// Shared short captions; button boundaries use the same spoken vocabulary.
struct FieldToolbarIconLabel: View {
    let title: String
    let symbol: String
    @Environment(\.fieldToolbarLabels) private var showsLabels
    static func caption(for title: String) -> String {
        switch title {
        case "Select (V)": return "Select"
        case "Rectangle (R)": return "Rect"
        case "Circle (C)": return "Circle"
        case "Polygon (G)": return "Polygon"
        case "Ring sector (S)": return "Sector"
        case "Cell editor (advanced)": return "Cells"
        case "Surface editor": return "Surfaces"
        case "Measuring grid": return "Grid"
        case "Output Monitor": return "Monitor"
        case "Paint (B)": return "Paint"
        case "Erase (E)": return "Erase"
        case "Hand (H)": return "Hand"
        case "Audition (P)": return "Audition"
        case "Show inactive scene layers": return "Inactive"
        case "Reset view": return "Reset"
        case "Zoom to measurement": return "Fit"
        case "Zoom out": return "Out"
        case "Zoom in": return "In"
        case "Turn off horizontal mirror", "Mirror horizontally": return "Mirror"
        case "Merge zones": return "Merge"
        case "Show raw scan": return "Raw"
        case "Scanner flag bits": return "Flags"
        case "Device fields": return "Edit"
        case "Show device fields": return "Fields"
        case "Hide layer", "Show layer": return "Visible"
        case "Lock layer", "Unlock layer": return "Lock"
        case "Select all layers, so a setting such as the transition applies to every layer": return "All"
        case "Add layer", "Add channel": return "Add"
        case "Capture room", "Cancel capture": return "Room"
        case "Fit to room": return "Fit"
        case "Grouping": return "Groups"
        case "Import layers from preset": return "Import"
        case "Duplicate selected layer": return "Dupl."
        case "Duplicate layer": return "Copy"
        case "Delete layer": return "Delete"
        case "Move layer up": return "Up"
        case "Move layer down": return "Down"
        case "Apply assignment": return "Apply"
        case "Connect automatically": return "Auto"
        case "Refresh ports": return "Refresh"
        case "Add scene": return "Add"
        case "Save preset (⌘S)": return "Save"
        case "Save preset as (⌘⇧S)": return "Save as"
        case "Refresh preset list", "Refresh MIDI devices": return "Refresh"
        case "Edit description": return "Describe"
        case "Import presets (⌘⇧I)": return "Import"
        case "Export preset (⌘⇧E)": return "Export"
        case "Delete preset": return "Delete"
        case "Tap Tempo (T)": return "Tap"
        case "Play transport": return "Play"
        case "Stop transport": return "Stop"
        case "Perform (⌘⇧P)": return "Perform"
        case "Edit (⌘⇧P)": return "Edit"
        default: return title
        }
    }
    private var caption: String { Self.caption(for: title) }
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 14)).frame(minWidth: 18, minHeight: 18)
            if showsLabels { Text(caption).font(.system(size: 10)).lineLimit(1).fixedSize(horizontal: true, vertical: true).accessibilityHidden(true) }
        }
        .frame(minWidth: showsLabels ? 32 : 20,minHeight: 20)
        .fixedSize(horizontal: true, vertical: true)
        .captionLayoutMarker(title: title, caption: caption, labels: showsLabels)
        .contentShape(Rectangle())
    }
}

/// Icon actions keep their spoken name and hover help at the button boundary.
struct IconActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    let emergencyFirstMouse: Bool
    var emergencyColors = StudioPanicCap.stopColors
    @State private var emergencyPressed = false
    init(_ title: String, symbol: String, emergencyFirstMouse: Bool = false, emergencyColors: (normal: Color, pressed: Color) = StudioPanicCap.stopColors, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.action = action
        self.emergencyFirstMouse = emergencyFirstMouse
        self.emergencyColors = emergencyColors
    }
    var body: some View {
        Group {
            if emergencyFirstMouse {
                Button(action: action) { FieldToolbarIconLabel(title: title, symbol: symbol) }
                    .buttonStyle(PanicButtonStyle(pressed: emergencyPressed, colors: emergencyColors))
            } else {
                Button(action: action) { FieldToolbarIconLabel(title: title, symbol: symbol) }
                    .buttonStyle(CaptionActionStyle())
            }
        }.fixedSize()
            .overlay {
                if emergencyFirstMouse {
                    EmergencyFirstMouseAction(action: action, pressed: { emergencyPressed = $0 })
                }
            }
            .help(title).iconAccessibility(title)
    }
}

struct IconToggle: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    init(_ title: String, symbol: String, isOn: Binding<Bool>) {
        self.title = title; self.symbol = symbol; _isOn = isOn
    }
    var body: some View {
        Toggle(isOn: $isOn) { FieldToolbarIconLabel(title: title, symbol: symbol) }
            .toggleStyle(CaptionToggleStyle()).help(title).iconAccessibility(title)
            .accessibilityValue(isOn ? "on" : "off")
    }
}

extension MetricCanvasTool {
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .paint: return "paintbrush.pointed"
        // eraser was introduced in macOS 13; the delete key is the 12.0 fallback.
        case .erase: return "delete.left"
        case .pan: return "hand.raised"
        case .audition: return "hand.point.up.left"
        }
    }
}

struct CanvasToolButtons: View {
    @Binding var selection: MetricCanvasTool
    var tools = MetricCanvasTool.allCases
    var selectionEnabled = true
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tools, id: \.self) { tool in
                Button { selection = tool } label: { FieldToolbarIconLabel(title: tool.label, symbol: tool.symbol) }
                    .buttonStyle(.plain).help(tool.label).iconAccessibility(tool.label)
                    .padding(6)
                    .foregroundColor(selectionEnabled && selection == tool ? .black : .white)
                    .background(selectionEnabled && selection == tool ? StageTheme.amber : HelmutChrome.control)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(selectionEnabled && selection == tool ? StageTheme.amber : .clear))
                    .cornerRadius(4)
                    .accessibilityValue(selectionEnabled && selection == tool ? "selected" : "not selected")
                    .accessibilityIdentifier("field.tool.\(tool.rawValue)")
                    .auditedButtonSurface(tool.label, font: 10, foreground: selectionEnabled && selection == tool ? .black : .white, background: selectionEnabled && selection == tool ? StageTheme.amber : HelmutChrome.control)
            }
        }.fixedSize()
    }
}

/// Applied at the Settings root AND standalone tab boundary: native macOS 12
/// controls inherit dark Aqua even when the system uses the light appearance.
extension View {
    func stageSettings() -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(StageTheme.workspace.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark).tint(StageTheme.amber)
            .pickerStyle(.menu).toggleStyle(ReadableCheckboxStyle())
    }
}

/// The pointer value is owned here, before any document publication. Live
/// effects publish at most once per 40 ms; release always flushes the tail.
@MainActor final class ControlDragSession: ObservableObject {
    @Published private(set) var displayed: Double?
    private(set) var initial: Double?
    private var cancelledUntilRelease = false
    private var lastTranslation = 0.0
    private var translation = 0.0
    private var pending: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var write: ((Double) -> Void)?
    private var editing: ((Bool) -> Void)?
    private var lastWritten: Double?
    var isActive: Bool { initial != nil }
    func begin(_ value: Double, write: @escaping (Double) -> Void, editing: @escaping (Bool) -> Void = { _ in }) {
        guard !isActive, !cancelledUntilRelease else { return }
        initial = value; displayed = value; lastWritten = value
        lastTranslation = 0; translation = 0
        self.write = write; self.editing = editing; editing(true)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.isActive == true else { return event }
            self?.cancel(); return nil
        }
    }
    func translated(_ total: Double, fine: Bool) -> Double {
        translation += (total - lastTranslation) * (fine ? 0.1 : 1)
        lastTranslation = total
        return translation
    }
    func change(_ value: Double, live: Bool) {
        guard isActive else { return }
        displayed = value
        guard live, pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil; self.flush()
        }
    }
    private func flush() {
        guard let displayed, displayed != lastWritten else { return }
        write?(displayed); lastWritten = displayed
    }
    func finish() {
        cancelledUntilRelease = false
        guard isActive else { return }
        pending?.cancel(); pending = nil; flush(); clear()
    }
    func cancel() {
        guard let initial else { return }
        pending?.cancel(); pending = nil
        if lastWritten != initial { write?(initial) }
        clear(); cancelledUntilRelease = true
    }
    private func clear() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil; editing?(false); editing = nil; write = nil
        initial = nil; displayed = nil; lastWritten = nil
    }
}

/// A native slider keeps its drag draft out of its parent inspector.
struct DeferredControlSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var defaultValue: Double
    var title: String? = nil
    @StateObject var drag = ControlDragSession()
    var body: some View {
        HStack(spacing: 6) {
        if let title {
            Text("\(title) \(Int(drag.displayed ?? value))").font(.caption.monospacedDigit()).lineLimit(1).fixedSize()
        }
        GeometryReader { geometry in
        Slider(value: Binding(get: { drag.displayed ?? value }, set: { next in
            drag.begin(value, write: { value = $0 })
            drag.change(next, live: false)
        }), in: range, step: step, onEditingChanged: { editing in
            if editing { drag.begin(value, write: { value = $0 }) } else { drag.finish() }
        })

        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { event in
            drag.begin(value, write: { value = $0 })
            let fraction = min(1, max(0, (event.location.x - 8) / max(1, geometry.size.width - 16)))
            let number = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
            drag.change((number / step).rounded() * step, live: false)
        }.onEnded { _ in drag.finish() })
        .inspectorLayoutProbe("audit.hit.slider." + (title ?? "value"))
        }.frame(height: 24)
        .simultaneousGesture(TapGesture(count: 2).onEnded { drag.cancel(); drag.finish(); value = defaultValue })
        .modifier(ControlScrollAction { delta, fine in
            value = min(range.upperBound, max(range.lowerBound, value + (delta > 0 ? step : -step) * (fine ? 0.1 : 1)))
        })
        .onDisappear { drag.cancel(); drag.finish() }
        }
    }
}

/// A monitor exists only while this control is hovered. Other scroll events
/// continue to their normal responder; no timer or monitor runs at rest.
struct ControlScrollAction: ViewModifier {
    let action: (Double, Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    @MainActor final class Handler { var action: ((Double, Bool) -> Void)? }
    @State private var handler = Handler()
    @State private var monitor: Any?
    func body(content: Content) -> some View {
        let _ = { handler.action = action }()
        return content.onHover { [handler] inside in
            remove()
            if inside && enabled {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak handler] event in
                    guard event.scrollingDeltaY != 0 else { return event }
                    handler?.action?(event.scrollingDeltaY, event.modifierFlags.contains(.option)); return nil
                }
            }
        }.onDisappear { remove() }.onChange(of: enabled) { if !$0 { remove() } }
    }
    private func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

/// SwiftUI maps a menu Toggle to NSMenuItem.state on macOS 12. A selection
/// choosing an already selected row still reaches its authorization boundary.
struct SelectionMenuItem: View {
    let title: String
    let selected: Bool
    let choose: () -> Void
    init(_ title: String, selected: Bool, choose: @escaping () -> Void) {
        self.title = title; self.selected = selected; self.choose = choose
    }
    var body: some View {
        Toggle(title, isOn: Binding(get: { selected }, set: { _ in choose() }))
    }
}


enum HoldTransitionHelp {
    static let text = "Held until the next note on this channel · use another channel for independent melody · Release layer / All notes off end it on purpose."
}

/// Captions may shorten visible text; the spoken action stays stable across
/// caption visibility and retains keyboard shortcuts and action context.
struct IconCaptionAccessibility: ViewModifier {
    let title: String
    var caption: String? = nil
    func body(content: Content) -> some View {
        content.accessibilityLabel(title)
            .accessibilityHint(title)
    }
}
extension View {
    func iconAccessibility(_ title: String, caption: String? = nil) -> some View {
        modifier(IconCaptionAccessibility(title: title, caption: caption))
    }
}

/// Native menus/segmented pickers need one semantic Label, rather than a
/// VStack whose children macOS 12 can interpret as separate choices.
struct FieldToolbarMenuLabel: View {
    let title: String
    let symbol: String
    @Environment(\.fieldToolbarLabels) private var labels
    var body: some View {
        Group {
        if labels { Label(FieldToolbarIconLabel.caption(for: title), systemImage: symbol).labelStyle(.titleAndIcon) }
        else { Image(systemName: symbol) }
        }.font(.system(size: 10))
    }
}


/// Native small rounded bezels on macOS 12 force a single-line height even
/// when the label requests two lines. Draw a resizable surface around the label.
struct CaptionActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let ink = enabled ? Color.white : Color(white: 0.68)
        return configuration.label.foregroundColor(ink).padding(.horizontal, 4).padding(.vertical, 4)
            .frame(minWidth: 20,minHeight: 20)
            .background(HelmutChrome.control)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(configuration.isPressed ? 0.4 : 0.1)))
            .cornerRadius(4).contentShape(Rectangle())
            .auditedButtonSurface("caption action",font: 10,foreground: ink,background: HelmutChrome.control)
    }
}
private struct CaptionToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label.foregroundColor(configuration.isOn ? .black : .white)
                .padding(.horizontal, 4).padding(.vertical, 4)
                .background(configuration.isOn ? StageTheme.amber : HelmutChrome.control).cornerRadius(4)
                .auditedButtonSurface("caption toggle",font: 10,foreground: configuration.isOn ? .black : .white,background: configuration.isOn ? StageTheme.amber : HelmutChrome.control)
        }.buttonStyle(.plain)
    }
}

/// Test-only native marker survives NSHostingView boundaries; no production work.
@MainActor enum CaptionLayoutProbe { static var enabled = false }
private struct CaptionLayoutMarker: NSViewRepresentable {
    let title: String
    let caption: String
    let labels: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        view.identifier = .init("caption.frame." + title)
        view.toolTip = labels ? caption : nil
    }
}
extension View {
    @ViewBuilder func captionLayoutMarker(title: String, caption: String, labels: Bool) -> some View {
        if CaptionLayoutProbe.enabled {
            self.background(CaptionLayoutMarker(title: title, caption: caption, labels: labels).allowsHitTesting(false).accessibilityHidden(true))
        } else { self }
    }
}


/// One readable surface for Apply/Discard in layer, cell and field editors.
struct AssignmentActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            FieldToolbarIconLabel(title: title, symbol: symbol)
                .foregroundColor(.white).padding(5)
                .frame(minWidth: 30, minHeight: 25)
                .background(HelmutChrome.control)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint, lineWidth: 1))
                .cornerRadius(4)
        }.buttonStyle(.plain).help(title).iconAccessibility(title)
            .auditedButtonSurface(title, font: 10, foreground: .white, background: HelmutChrome.control)
    }
}

extension View {
    /// The render properties and audit data come from the same role values.
    func auditedButtonSurface(_ name: String, font: Double, foreground: Color, background: Color, group: String = "") -> some View {
        self.font(.system(size: font)).foregroundColor(foreground).background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .buttonLayoutRole(name,font: font,foreground: foreground,background: background,group: group)
    }
    @ViewBuilder func buttonLayoutRole(_ name: String, font: Double, foreground: Color, background: Color, group: String = "") -> some View {
        if InspectorLayoutProbe.enabled {
            self.background(ButtonLayoutRoleMarker(name: name, font: font, foreground: foreground, background: background, group: group)
                .allowsHitTesting(false).accessibilityHidden(true))
        } else { self }
    }
}
private struct ButtonLayoutRoleMarker: NSViewRepresentable {
    let name: String
    let font: Double
    let foreground: Color
    let background: Color
    let group: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        view.identifier = .init("button.audit." + name)
        func rgb(_ color: Color) -> [Double] {
            guard let value = NSColor(color).usingColorSpace(.sRGB) else { return [] }
            return [value.redComponent,value.greenComponent,value.blueComponent,value.alphaComponent].map(Double.init)
        }
        let data = try? JSONSerialization.data(withJSONObject: ["font": font, "foreground": rgb(foreground), "background": rgb(background), "group": group])
        view.toolTip = data.flatMap { String(data: $0, encoding: .utf8) }
    }
}


struct FullRowDisclosure<Label: View, Content: View>: View {
    @Binding var expanded: Bool
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 20, height: 20)
                    label()
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded { content() }
        }
    }
}


struct ReadableCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square").font(.system(size: 14)).accessibilityHidden(true)
                configuration.label.font(.system(size: 11))
            }.padding(.horizontal,4).frame(minHeight: 24).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .auditedButtonSurface("checkbox",font: 11,foreground: configuration.isOn ? .black : .white,
                background: configuration.isOn ? StageTheme.amber : HelmutChrome.control)
            .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}
