import AppKit
import SwiftUI
import SickPLSMonitorKit

private struct InspectorNumberSessionKey: EnvironmentKey {
    static let defaultValue: CanvasSession? = nil
}
extension EnvironmentValues {
    var inspectorNumberSession: CanvasSession? {
        get { self[InspectorNumberSessionKey.self] }
        set { self[InspectorNumberSessionKey.self] = newValue }
    }
}

enum MIDIControllerNames {
    static let common: [(number: UInt8, name: String)] = [
        (1, "Modulation"), (2, "Breath"), (4, "Foot"), (7, "Volume"), (10, "Pan"),
        (11, "Expression"), (64, "Sustain"), (71, "Resonance"), (72, "Release"),
        (73, "Attack"), (74, "Brightness"), (91, "Reverb"), (93, "Chorus")
    ]
    static func name(_ number: UInt8) -> String { common.first { $0.number == number }?.name ?? "Controller" }
}

/// Native end-editing is the authority for focus loss, including clicks in a
/// different hosting root. The session flushes the same draft before selection
/// and save; the callback retains neither session nor responder.
struct InspectorNumberField: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let context: String
    let title: String
    let identifier: String
    let enabled: Bool
    var placeholder: String? = nil
    let session: CanvasSession?
    @Binding var rejected: Bool

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var input: InspectorNumberField
        weak var field: NSTextField?
        weak var owner: CanvasSession?
        let id = UUID()
        var baseline: Int?
        var dirty = false
        var synchronizing = false
        var renderedValue: Int
        init(_ input: InspectorNumberField) { self.input = input; renderedValue = input.value }
        func discard() {
            let previous = synchronizing; synchronizing = true
            defer { synchronizing = previous }
            dirty = false; baseline = nil
            let displayed = String(input.value)
            if field?.stringValue != displayed { field?.stringValue = displayed }
            if let editor = field?.currentEditor(), editor.string != displayed { editor.string = displayed }
        }
        func commit() {
            guard dirty else { return }
            guard input.enabled, baseline == input.value else { discard(); return }
            let text = (field?.currentEditor()?.string ?? field?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(text), input.range.contains(number) else {
                discard(); input.rejected = true; return
            }
            dirty = false; baseline = nil; input.rejected = false
            if number != input.value { input.value = number }
            field?.stringValue = String(number)
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard !synchronizing else { return }; baseline = input.value
        }
        func controlTextDidChange(_ notification: Notification) {
            guard !synchronizing else { return }
            if baseline == nil { baseline = input.value }
            dirty = true; input.rejected = false
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !synchronizing else { return }; commit()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                discard(); input.rejected = false; field?.window?.makeFirstResponder(nil); return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                commit(); field?.window?.makeFirstResponder(nil); return true
            }
            return false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: String(value))
        field.placeholderString = placeholder ?? "\(range.lowerBound)…\(range.upperBound)"
        field.alignment = .right; field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 11)
        field.identifier = .init("inspector.programChange.\(identifier).number")
        field.setAccessibilityIdentifier(field.identifier!.rawValue)
        field.setAccessibilityLabel(title)
        field.delegate = context.coordinator
        context.coordinator.field = field
        ViewEvaluationProbe.current?.record("inspector.programFieldMount")
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.synchronizing = true
        defer { coordinator.synchronizing = false }
        let changed = coordinator.input.context != self.context || coordinator.renderedValue != value ||
            coordinator.input.range != range || coordinator.input.enabled != enabled
        coordinator.input = self
        coordinator.renderedValue = value
        if changed { coordinator.discard() }
        if coordinator.owner !== session {
            coordinator.owner?.unregisterNumberEdit(coordinator.id)
            coordinator.owner = session
            session?.registerNumberEdit(coordinator.id) { [weak coordinator] in
                // End the field editor before selection invalidates a retained
                // root. This also lets a sibling formatted number finish outside
                // SwiftUI's layout pass, rather than when it becomes disabled.
                if let window = coordinator?.field?.window, window.firstResponder is NSTextView {
                    window.makeFirstResponder(nil)
                }
                coordinator?.commit()
            }
        }
        if field.isEnabled != enabled { field.isEnabled = enabled }
        let hint = placeholder ?? "\(range.lowerBound)…\(range.upperBound)"
        if field.placeholderString != hint { field.placeholderString = hint }
        if !coordinator.dirty && field.stringValue != String(value) { field.stringValue = String(value) }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        // SwiftUI is already invalidating its graph here. Selection/save and
        // native end-editing commit earlier; teardown must not write bindings.
        coordinator.owner?.unregisterNumberEdit(coordinator.id)
        field.delegate = nil
    }
}

/// Offline geometry observation; absent from the production view tree.
@MainActor enum InspectorLayoutProbe { static var enabled = false }
private struct InspectorLayoutVisibleKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var inspectorLayoutVisible: Bool {
        get { self[InspectorLayoutVisibleKey.self] }
        set { self[InspectorLayoutVisibleKey.self] = newValue }
    }
}
extension View {
    @ViewBuilder func inspectorLayoutProbe(_ name: String) -> some View {
        if InspectorLayoutProbe.enabled {
            self.background(InspectorLayoutMarker(name: name).allowsHitTesting(false).accessibilityHidden(true))
        } else { self }
    }
}
private struct InspectorLayoutMarker: NSViewRepresentable {
    let name: String
    @Environment(\.inspectorLayoutVisible) private var visible
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); view.identifier = .init("inspector.frame." + name); return view
    }
    func updateNSView(_ view: NSView, context: Context) { view.isHidden = !visible }
}
