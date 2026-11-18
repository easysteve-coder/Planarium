import Combine
import Foundation
import PlanariumControllerCore
import PlanariumDomain
import PlanariumRuntime

/// The game controller part of the stage: the compiled assignments of the
/// instrument (with the ones the scanner already owns kept out) and the
/// on-screen controller. The runtime plays both through one path.
@MainActor public final class ControllerStageModel: ObservableObject {
    /// Assignments refused because another source owns their target class.
    @Published public private(set) var conflicts: [UUID: OutputConflict] = [:]
    /// What the on-screen controller holds right now (mouse simulation).
    @Published public private(set) var simulated: ControllerState = .neutral
    @Published public private(set) var installedLayout: ControllerLayout = .empty
    private let runtime: PerformanceRuntime

    init(runtime: PerformanceRuntime) { self.runtime = runtime }

    /// Compiles the layout against the scanner instrument's targets and installs
    /// it. Throws only for an invalid layout; conflicts are reported, not thrown.
    func install(_ layout: ControllerLayout, scanner: CompiledInstrument) throws {
        runtime.installController(try prepare(layout, scanner: scanner))
    }

    /// Compiles and records the plan without installing it; the caller hands it
    /// to the runtime together with the scanner plan it was compiled against.
    func prepare(_ layout: ControllerLayout, scanner: CompiledInstrument) throws -> CompiledControllerLayout? {
        let compiled = try Self.compile(layout, scanner: scanner)
        installedLayout = layout
        if conflicts != compiled.conflicts { conflicts = compiled.conflicts }
        return layout.assignments.isEmpty ? nil : compiled
    }

    static func compile(_ layout: ControllerLayout, scanner: CompiledInstrument) throws -> CompiledControllerLayout {
        try CompiledControllerLayout(layout, source: .controller(0), sumEndpoint: scanner.sumMIDIEndpoint,
                                     established: scanner.outputClaims())
    }

    /// Presses, moves or releases elements of the on-screen controller.
    public func simulate(_ state: ControllerState) {
        guard state != simulated else { return }
        simulated = state
        runtime.simulateController(state)
    }
    public func press(_ element: ControllerElement, _ down: Bool) {
        var next = simulated
        if down { next.pressed.insert(element) } else { next.pressed.remove(element) }
        simulate(next)
    }
    public func setValue(_ element: ControllerElement, _ value: Double?) {
        var next = simulated
        next.values[element] = value.map { min(max($0, 0), 1) }
        simulate(next)
    }
    public func setPosition(_ element: ControllerElement, _ point: ControllerPoint?) {
        var next = simulated
        next.positions[element] = point
        simulate(next)
    }
    /// Lets go of everything on the on-screen controller.
    public func releaseSimulation() { simulate(.neutral) }
}

extension SpatialInstrumentRuntimeModel {
    /// Replaces the controller assignments as one undoable edit.
    @discardableResult public func setControllerLayout(_ layout: ControllerLayout, name: String = "Controller assignment") -> Bool {
        do {
            _ = try ControllerStageModel.compile(layout, scanner: compiledInstrument)
            try edit(name: name) { $0.controller = layout }
            return true
        } catch {
            setControllerNotice("Controller assignment rejected")
            return false
        }
    }
    public func updateControllerAssignment(_ assignment: ControllerAssignment) {
        var layout = document.controller
        if let index = layout.assignments.firstIndex(where: { $0.id == assignment.id }) { layout.assignments[index] = assignment }
        else { layout.assignments.append(assignment) }
        setControllerLayout(layout)
    }
    public func removeControllerAssignment(_ id: UUID) {
        var layout = document.controller
        layout.assignments.removeAll { $0.id == id }
        setControllerLayout(layout, name: "Remove controller assignment")
    }
}
