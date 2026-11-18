import XCTest
import PlanariumMusicCore
@testable import PlanariumControllerCore

final class ControllerAssistantTests: XCTestCase {
    private let strip = UUID(uuidString: "C0000000-0000-0000-0000-0000000000F1")!

    func testEveryAssistantCompilesAndPlaysThroughTheEngine() throws {
        for assistant in ControllerAssistant.allCases {
            let layout = assistant.applied(to: .empty, output: .audioUnit(stripID: strip, channel: 0))
            let compiled = try CompiledControllerLayout(layout, source: .controller(0), sumEndpoint: nil)
            XCTAssertEqual(compiled.playable.count, layout.assignments.count, assistant.title)
            XCTAssertTrue(compiled.conflicts.isEmpty, assistant.title)
            var engine = ControllerEngine()
            _ = engine.install(compiled, at: 0)
            let element = layout.assignments[0].element
            let state: ControllerState = element.isPositional
                ? .init(positions: [element: .init(x: 0, y: 1)]) : .init(pressed: [element])
            XCTAssertTrue(engine.simulate(state, at: 0).contains { if case .noteOn = $0 { return true }; return false }, assistant.title)
        }
    }

    func testAssistantReplacesOnlyTheElementsItUses() {
        let own = ControllerAssignment(name: "Mine", color: .blue, element: .dpadUp,
                                       routing: .init(target: .midiNote(channel: 1), program: .singleNote(note: 70, velocity: 90, transition: .retrigger)))
        let old = ControllerAssignment(name: "Old cross", color: .blue, element: .cross,
                                       routing: .init(target: .midiNote(channel: 1), program: .singleNote(note: 71, velocity: 90, transition: .retrigger)))
        let next = ControllerAssistant.drums.applied(to: .init(assignments: [own, old]), output: .midi(channel: 9))
        XCTAssertTrue(next.assignments.contains(own))
        XCTAssertFalse(next.assignments.contains(old))
        XCTAssertEqual(next.assignments.filter { $0.element == .cross }.map(\.name), ["Kick"])
        XCTAssertTrue(next.assignments.allSatisfy { $0.element == .dpadUp || $0.routing.target == .midiNote(channel: 9) })
    }
}
