import XCTest
@testable import SickPLSMonitorKit

final class WorkspaceSetupRuleTests: XCTestCase {
    func testConnectionAndProfileCollapseInBothOrdersOnlyAfterBothFacts() {
        let initial = WorkspaceSetupState()
        let connected = initial.applying(.connection(session: "A", connected: true))
        let profiled = initial.applying(.profile(session: "A"))
        XCTAssertTrue(connected.visible); XCTAssertTrue(profiled.visible)
        let a = connected.applying(.profile(session: "A"))
        let b = profiled.applying(.connection(session: "A", connected: true))
        XCTAssertEqual(a, b); XCTAssertFalse(a.visible)
        XCTAssertEqual(a.applying(.profile(session: "A")), a)
        XCTAssertEqual(a.applying(.connection(session: "A", connected: true)), a)
    }
    func testManualOpenSurvivesEveryTickUntilConnectionChangesInBothOrders() {
        for events in [
            [WorkspaceSetupState.Event.connection(session: "A", connected: true), .profile(session: "A")],
            [.profile(session: "A"), .connection(session: "A", connected: true)]
        ] {
            var state = events.reduce(WorkspaceSetupState()) { $0.applying($1) }
            XCTAssertFalse(state.visible)
            state = state.applying(.manual(visible: true))
            for _ in 0..<20 {
                state = events.reduce(state) { $0.applying($1) }
                XCTAssertTrue(state.visible)
            }
            XCTAssertTrue(state.applying(.disconnected).visible)
            let next = state.applying(.connection(session: "B", connected: true))
            XCTAssertTrue(next.visible); XCTAssertNil(next.manualVisibility)
            XCTAssertFalse(next.applying(.profile(session: "B")).visible)
        }
    }
    func testManualChoiceBeforeFirstProfileAndManualCloseAreRespected() {
        for connectedFirst in [false, true] {
            let event: WorkspaceSetupState.Event = connectedFirst ? .connection(session: "A", connected: true) : .profile(session: "A")
            let other: WorkspaceSetupState.Event = connectedFirst ? .profile(session: "A") : .connection(session: "A", connected: true)
            for visible in [false, true] {
                let state = WorkspaceSetupState().applying(event).applying(.manual(visible: visible)).applying(other)
                XCTAssertEqual(state.visible, visible)
            }
        }
    }
    func testLossDisconnectAndReplacementResetEveryReachableState() {
        let events: [WorkspaceSetupState.Event] = [.connection(session: "A", connected: true),
            .connection(session: "A", connected: false), .profile(session: "A"),
            .manual(visible: true), .manual(visible: false), .disconnected]
        var states = [WorkspaceSetupState(), WorkspaceSetupState(visible: false)]
        var cursor = 0
        while cursor < states.count {
            let current = states[cursor]; cursor += 1
            for event in events {
                let next = current.applying(event)
                if !states.contains(next) { states.append(next) }
            }
        }
        XCTAssertGreaterThan(states.count, 10)
        for state in states {
            for loss in [WorkspaceSetupState.Event.disconnected, .connection(session: "A", connected: false)] {
                let next = state.applying(loss)
                XCTAssertTrue(next.visible); XCTAssertFalse(next.connected)
                XCTAssertFalse(next.hasProfile); XCTAssertNil(next.manualVisibility)
            }
            for first in [WorkspaceSetupState.Event.connection(session: "B", connected: true), .profile(session: "B")] {
                let next = state.applying(first)
                XCTAssertTrue(next.visible); XCTAssertNil(next.manualVisibility)
                XCTAssertEqual(next.session, "B")
            }
        }
        print("LAYOUT-1 setup reachableStates=\(states.count) eventEdges=\(states.count * events.count)")
    }
}
