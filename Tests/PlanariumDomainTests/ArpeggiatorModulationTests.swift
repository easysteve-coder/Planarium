import XCTest
@testable import PlanariumDomain

final class ArpeggiatorModulationTests: XCTestCase {
    func testInvertedHandRangeSurvivesAssignmentAndChangesMeasuredDirection() {
        let target = SpatialRoutingTarget.midiEffectParameter(stripID: UUID(), slotID: UUID(), parameter: .rate)
        let draft = SpatialAssignmentDraft(target: target, kind: .continuous, minimumValue: 1, maximumValue: 0)
        XCTAssertEqual(SpatialAssignmentDraft.program(from: draft), .continuous(minimum: 1, maximum: 0, directionDegrees: draft.directionDegrees, curve: draft.curve))
        let cells = [100, 200].map { PolarDeviceLattice(ring: $0, sector: 180)! }
        let plan = CompiledValuePlan(program: .continuous(minimum: 1, maximum: 0, directionDegrees: 90, curve: .linear), cells: cells)
        XCTAssertEqual(plan.value(activeCell: cells[0], candidateDistanceCentimeters: 100), .scalar(1))
        XCTAssertEqual(plan.value(activeCell: cells[1], candidateDistanceCentimeters: 200), .scalar(0))
    }
    func testEveryParameterTransitionsAndDiscreteHysteresis() {
        for parameter in ArpeggiatorModulationTarget.allCases {
            var effect = ArpeggiatorEffect()
            let low = parameter.apply(0, to: &effect)
            let high = parameter.apply(1, to: &effect, previous: low)
            XCTAssertGreaterThan(high, low)
            XCTAssertTrue(effect.isValid)
        }
        var effect = ArpeggiatorEffect()
        let initial = ArpeggiatorModulationTarget.rate.apply(0.08, to: &effect)
        XCTAssertEqual(initial, 0)
        for scalar in [0.099, 0.101, 0.09, 0.11] {
            XCTAssertEqual(ArpeggiatorModulationTarget.rate.apply(scalar, to: &effect, previous: initial), 0)
        }
        XCTAssertEqual(ArpeggiatorModulationTarget.rate.apply(0.21, to: &effect, previous: initial), 1)
    }
    func testLastEntryWinsInBothOrdersAndInactiveFallsBackToEditor() {
        for reversed in [false, true] {
            var state = ArpeggiatorModulationState()
            let strip = UUID(), slot = UUID(), a = UUID(), b = UUID()
            let target = SpatialRoutingTarget.midiEffectParameter(stripID: strip, slotID: slot, parameter: .gate)
            let first = SpatialRoutingEvaluation(routingID: a, target: target, value: .scalar(0))
            let second = SpatialRoutingEvaluation(routingID: b, target: target, value: .scalar(1))
            let pair = reversed ? [second, first] : [first, second]
            state.update([pair[0]])
            state.update(pair)
            XCTAssertEqual(state.applying(to: .init(), stripID: strip, slotID: slot).gate, reversed ? 10 : 100)
            // Evaluation order must not become entry order on later frames.
            state.update(pair.reversed())
            XCTAssertEqual(state.applying(to: .init(), stripID: strip, slotID: slot).gate, reversed ? 10 : 100)
            state.update([pair[0], .init(routingID: pair[1].routingID, target: target, value: .inactive)])
            XCTAssertEqual(state.applying(to: .init(), stripID: strip, slotID: slot).gate, reversed ? 100 : 10)
            state.update([])
            XCTAssertEqual(state.applying(to: .init(), stripID: strip, slotID: slot), ArpeggiatorEffect())
        }
    }
    func testCompilerRejectsMissingAndBypassedSlotAsInactiveThenRecovers() throws {
        var strip = InstrumentChannel()
        let slot = InstrumentMIDIEffect(arpeggiator: .init())
        strip.midiEffects = [slot]
        let target = SpatialRoutingTarget.midiEffectParameter(stripID: strip.id, slotID: slot.id, parameter: .gate)
        let id = UUID(), routing = SpatialRouting(target: target, program: .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear))
        let cell = PolarDeviceLattice(ring: 100, sector: 180)!
        let layer = SpatialDocumentLayer(id: id, name: "Hand", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [cell], routings: [routing], cellOverrides: [:])
        var document = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id), revision: .newSession())
        for mode in ["active", "deleted", "bypass", "restored"] {
            document.channels = [strip]
            if mode == "deleted" { document.channels[0].midiEffects = [] }
            if mode == "bypass" { document.channels[0].midiEffects[0].bypassed = true }
            let compiled = try InstrumentCompiler.compile(document)
            let handle = try XCTUnwrap(compiled.hits(tick: 180, raw: 100).first)
            let value = try XCTUnwrap(compiled.evaluate(active: [id: handle]).first)
            if mode == "deleted" || mode == "bypass" {
                XCTAssertTrue(compiled.unavailableRoutingIDs.contains(routing.id))
                XCTAssertFalse(compiled.hasArpeggiatorModulation)
                XCTAssertEqual(value.value, .inactive)
            } else {
                XCTAssertFalse(compiled.unavailableRoutingIDs.contains(routing.id))
                XCTAssertTrue(compiled.hasArpeggiatorModulation)
                guard case .scalar = value.value else { return XCTFail("Restored slot must evaluate") }
            }
        }
    }
    func testTargetRoundtripAndDeletedWrongKindAndBypassAreUnavailable() throws {
        var strip = InstrumentChannel()
        let slot = InstrumentMIDIEffect(arpeggiator: .init())
        strip.midiEffects = [slot]
        for parameter in ArpeggiatorModulationTarget.allCases {
            let target = SpatialRoutingTarget.midiEffectParameter(stripID: strip.id, slotID: slot.id, parameter: parameter)
            XCTAssertEqual(try JSONDecoder().decode(SpatialRoutingTarget.self, from: JSONEncoder().encode(target)), target)
            XCTAssertTrue(target.isAvailable(in: [strip]))
            var bypass = strip; bypass.midiEffects[0].bypassed = true
            XCTAssertFalse(target.isAvailable(in: [bypass]))
            var wrong = strip; wrong.midiEffects[0].kind = .chord
            XCTAssertFalse(target.isAvailable(in: [wrong]))
            XCTAssertFalse(target.isAvailable(in: []))
            var removed = strip; removed.midiEffects = []
            XCTAssertFalse(target.isAvailable(in: [removed]))
        }
    }
}
